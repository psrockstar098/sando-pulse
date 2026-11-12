//! Webhook receiver (Roadmap 3.2, design doc section 4).
//!
//! Flow: a subscribed Page publishes -> Meta POSTs a change
//! notification to Pulse -> this module validates the signature,
//! parses the notification, and records it. The notification
//! carries NO post content; the ingestion worker fetches the
//! permitted content through the Graph API afterwards. Periodic
//! reconciliation (scheduler.zig) covers missed notifications.
//!
//! Two pure functions the server route calls:
//!   verifySignature — HMAC-SHA256 over the raw body, compared
//!     against the X-Hub-Signature-256 header in constant time.
//!   handleVerification — the subscription handshake: Meta GETs
//!     ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...;
//!     Pulse echoes hub.challenge only when the token matches.
//!
//! When no app secret is configured the receiver refuses to verify
//! anything (it cannot trust a signature it cannot check) and the
//! server answers 503 for webhook POSTs.

const std = @import("std");
const fb_types = @import("types.zig");

/// Constant-time comparison: signature checks must not leak, through
/// timing, how many leading bytes matched.
fn timingSafeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Verify the X-Hub-Signature-256 header: "sha256=<hex hmac>".
/// Returns false for a missing/malformed header, a missing secret,
/// or a mismatch. The secret is never logged.
pub fn verifySignature(app_secret: ?[]const u8, body: []const u8, header: ?[]const u8) bool {
    const secret = app_secret orelse return false;
    const h = header orelse return false;
    if (!std.mem.startsWith(u8, h, "sha256=")) return false;
    const hex = h["sha256=".len..];
    if (hex.len != 64) return false;
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, secret);
    const expected = std.fmt.bytesToHex(mac, .lower);
    return timingSafeEql(&expected, hex);
}

/// Subscription handshake. `query` is the raw query string
/// (everything after '?'). Returns the hub.challenge value when
/// hub.mode=subscribe and hub.verify_token matches the configured
/// token; null otherwise (the server answers 403).
pub fn handleVerification(query: ?[]const u8, verify_token: ?[]const u8) ?[]const u8 {
    const token = verify_token orelse return null;
    const q = query orelse return null;
    var mode_ok = false;
    var token_ok = false;
    var challenge: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, "hub.mode") and std.mem.eql(u8, v, "subscribe")) mode_ok = true;
        if (std.mem.eql(u8, k, "hub.verify_token") and std.mem.eql(u8, v, token)) token_ok = true;
        if (std.mem.eql(u8, k, "hub.challenge")) challenge = v;
    }
    if (mode_ok and token_ok) return challenge;
    return null;
}

/// Parse a webhook notification body into one record per entry.
/// Body shape: {"object":"page","entry":[{"id":"<page_id>",
/// "time":...,"changes":[{"field":"feed","value":{...}}]}]}.
/// Entries without a field change are skipped; unknown fields are
/// ignored. The returned records borrow from `body` via the arena
/// allocator — the caller keeps them alive as long as needed.
pub fn parseNotification(alloc: std.mem.Allocator, body: []const u8, received_at: i64) ![]fb_types.WebhookNotification {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadNotification,
    };
    const object = switch (root.get("object") orelse .null) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, object, "page")) return error.BadNotification;
    const entries = root.get("entry") orelse return &.{};
    const arr = switch (entries) {
        .array => |a| a,
        else => return error.BadNotification,
    };
    var out: std.ArrayList(fb_types.WebhookNotification) = .empty;
    for (arr.items) |entry| {
        const eo = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const page_id = switch (eo.get("id") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        const source_time = switch (eo.get("time") orelse .null) {
            .integer => |t| t,
            else => 0,
        };
        const changes = eo.get("changes") orelse continue;
        const carr = switch (changes) {
            .array => |a| a,
            else => continue,
        };
        for (carr.items) |change| {
            const co = switch (change) {
                .object => |o| o,
                else => continue,
            };
            const field = switch (co.get("field") orelse .null) {
                .string => |s| s,
                else => "",
            };
            const object_id = switch (co.get("value") orelse .null) {
                .object => |vo| switch (vo.get("post_id") orelse .null) {
                    .string => |s| s,
                    else => "",
                },
                else => "",
            };
            try out.append(alloc, .{
                .page_id = try alloc.dupe(u8, page_id),
                .kind = try alloc.dupe(u8, field),
                .object_id = try alloc.dupe(u8, object_id),
                .source_time = source_time,
                .received_at = received_at,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

test "webhook signature: valid passes, wrong secret / header / body fail" {
    // RFC 4231 test case 1 locks the HMAC argument order:
    // key = 0x0b * 20, data = "Hi There",
    // HMAC-SHA256 = b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7.
    {
        var key: [20]u8 = undefined;
        @memset(&key, 0x0b);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, "Hi There", &key);
        try std.testing.expectEqualStrings("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", &std.fmt.bytesToHex(mac, .lower));
    }
    const body = "hello";
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, "test-secret");
    const hex = std.fmt.bytesToHex(mac, .lower);
    var header_buf: [71]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "sha256={s}", .{hex});
    try std.testing.expect(verifySignature("test-secret", body, header));
    try std.testing.expect(!verifySignature("wrong-secret", body, header));
    try std.testing.expect(!verifySignature("test-secret", "other body", header));
    try std.testing.expect(!verifySignature("test-secret", body, "sha256=00"));
    try std.testing.expect(!verifySignature("test-secret", body, null));
    try std.testing.expect(!verifySignature(null, body, header));
    try std.testing.expect(!verifySignature("test-secret", body, "md5=abc"));
}

test "webhook handshake echoes the challenge only on a token match" {
    try std.testing.expectEqualStrings("CHALLENGE123", handleVerification("hub.mode=subscribe&hub.verify_token=tok&hub.challenge=CHALLENGE123", "tok").?);
    try std.testing.expect(handleVerification("hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=X", "tok") == null);
    try std.testing.expect(handleVerification("hub.mode=unsubscribe&hub.verify_token=tok&hub.challenge=X", "tok") == null);
    try std.testing.expect(handleVerification(null, "tok") == null);
    try std.testing.expect(handleVerification("hub.mode=subscribe&hub.verify_token=tok&hub.challenge=X", null) == null);
}

test "webhook notification parses entries and changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\{"object":"page","entry":[{"id":"456","time":1794477600,"changes":[{"field":"feed","value":{"post_id":"456_789"}}]},{"id":"789","time":1794477601,"changes":[{"field":"feed","value":{}}]}]}
    ;
    const notes = try parseNotification(alloc, body, 1794477700);
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqualStrings("456", notes[0].page_id);
    try std.testing.expectEqualStrings("feed", notes[0].kind);
    try std.testing.expectEqualStrings("456_789", notes[0].object_id);
    // Meta's entry time is kept: it keys the dedupe id, so a retried
    // delivery (same entry time, new receipt time) inserts once.
    try std.testing.expectEqual(@as(i64, 1794477600), notes[0].source_time);
    try std.testing.expectEqual(@as(i64, 1794477700), notes[0].received_at);
    try std.testing.expectEqual(@as(i64, 1794477601), notes[1].source_time);
    try std.testing.expectEqualStrings("789", notes[1].page_id);
    try std.testing.expectEqualStrings("", notes[1].object_id);
    try std.testing.expectError(error.BadNotification, parseNotification(alloc, "{\"object\":\"user\",\"entry\":[]}", 1));
}

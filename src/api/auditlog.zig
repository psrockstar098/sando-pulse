//! Audit records (Roadmap 5.3): who called what, when, and whether
//! they were allowed.
//!
//! Every authenticated call to /v1/query, /v1/ingest and /v1/usage
//! writes one record: UTC timestamp, consumer name, a fingerprint of
//! the presented API key (first 8 hex chars of its SHA-256 — the key
//! itself never appears anywhere), route, method, HTTP status, and the
//! request id. Denied calls (bad key, unknown consumer, missing scope,
//! rate limit, quota) are recorded too, with their denial status.
//!
//! Sinks (best-effort, never fail a request):
//! - Postgres `audit_log` table (migration 011) when DATABASE_URL is set.
//! - A JSONL file when PULSE_AUDIT_LOG is set (one record per line).
//! - A structured log line, always.
//!
//! Read the records with SQL (`SELECT * FROM audit_log ORDER BY ts DESC
//! LIMIT 100`) or by reading the JSONL file. There is no API to read
//! them back — audit data is append-only by design.

const std = @import("std");
const logging = @import("../common/logging.zig");
const postgres = @import("../storage/postgres.zig");

pub const AuditRecord = struct {
    ts: i64,
    consumer: []const u8,
    /// First 8 hex chars of SHA-256(presented key), or "anonymous".
    key_fingerprint: []const u8,
    route: []const u8,
    method: []const u8,
    status: u16,
    request_id: []const u8,
};

/// Fingerprint of the presented Bearer token: the first 8 hex chars of
/// its SHA-256. "anonymous" in open dev mode (no key presented).
pub fn keyFingerprint(alloc: std.mem.Allocator, presented_key: ?[]const u8) ![]u8 {
    const key = presented_key orelse return alloc.dupe(u8, "anonymous");
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, hex[0..8]);
}

/// One JSONL line for the record. Strings are JSON-escaped by the
/// stringifier; the record carries no user content, only identifiers.
pub fn renderJson(alloc: std.mem.Allocator, rec: AuditRecord) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .ts = rec.ts,
        .consumer = rec.consumer,
        .key_fp = rec.key_fingerprint,
        .route = rec.route,
        .method = rec.method,
        .status = rec.status,
        .request_id = rec.request_id,
    }, .{});
}

pub const AuditSink = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    pg: ?*postgres.PgClient,
    file: ?std.Io.File,
    /// Current end offset of the JSONL file (positional appends).
    file_len: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, pg: ?*postgres.PgClient, file: ?std.Io.File, file_len: u64) AuditSink {
        return .{ .alloc = alloc, .io = io, .pg = pg, .file = file, .file_len = file_len };
    }

    /// Record one audit event. Never errors outward: a failed sink is
    /// logged and the request proceeds. The structured log line is the
    /// sink of last resort and always runs.
    pub fn record(self: *AuditSink, rec: AuditRecord) void {
        if (self.pg) |client| {
            // escapeLiteral returns the value WITH surrounding quotes.
            const esc_consumer = postgres.escapeLiteral(self.alloc, rec.consumer) catch null;
            defer if (esc_consumer) |v| self.alloc.free(v);
            const esc_fp = postgres.escapeLiteral(self.alloc, rec.key_fingerprint) catch null;
            defer if (esc_fp) |v| self.alloc.free(v);
            const esc_route = postgres.escapeLiteral(self.alloc, rec.route) catch null;
            defer if (esc_route) |v| self.alloc.free(v);
            const esc_method = postgres.escapeLiteral(self.alloc, rec.method) catch null;
            defer if (esc_method) |v| self.alloc.free(v);
            const esc_req = postgres.escapeLiteral(self.alloc, rec.request_id) catch null;
            defer if (esc_req) |v| self.alloc.free(v);
            if (esc_consumer != null and esc_fp != null and esc_route != null and esc_method != null and esc_req != null) {
                const sql = std.fmt.allocPrint(self.alloc,
                    \\INSERT INTO audit_log (ts, consumer, key_fp, route, method, status, request_id)
                    \\VALUES (to_timestamp({d}), {s}, {s}, {s}, {s}, {d}, {s})
                , .{
                    rec.ts,
                    esc_consumer.?,
                    esc_fp.?,
                    esc_route.?,
                    esc_method.?,
                    rec.status,
                    esc_req.?,
                }) catch null;
                if (sql) |s| {
                    defer self.alloc.free(s);
                    client.exec(self.alloc, s) catch {
                        logging.warn("audit: postgres insert failed", &.{});
                    };
                } else {
                    logging.warn("audit: failed to render postgres record", &.{});
                }
            } else {
                logging.warn("audit: failed to escape postgres record", &.{});
            }
        }
        if (self.file) |f| {
            const line = renderJson(self.alloc, rec) catch {
                logging.warn("audit: failed to render json record", &.{});
                return self.recordLogOnly(rec);
            };
            defer self.alloc.free(line);
            // Positional append at the tracked end offset (no O_APPEND
            // flag exists in this std; the offset is ours alone — the
            // server is single-threaded).
            const total = line.len + 1;
            const buf = self.alloc.alloc(u8, total) catch {
                logging.warn("audit: failed to allocate json record", &.{});
                return self.recordLogOnly(rec);
            };
            defer self.alloc.free(buf);
            @memcpy(buf[0..line.len], line);
            buf[line.len] = '\n';
            f.writePositionalAll(self.io, buf, self.file_len) catch {
                logging.warn("audit: file write failed", &.{});
                return self.recordLogOnly(rec);
            };
            self.file_len += total;
        }
        self.recordLogOnly(rec);
    }

    fn recordLogOnly(self: *AuditSink, rec: AuditRecord) void {
        const status_s = std.fmt.allocPrint(self.alloc, "{d}", .{rec.status}) catch "?";
        defer if (!std.mem.eql(u8, status_s, "?")) self.alloc.free(status_s);
        logging.info("audit", &.{
            .{ .key = "consumer", .value = rec.consumer },
            .{ .key = "key_fp", .value = rec.key_fingerprint },
            .{ .key = "route", .value = rec.route },
            .{ .key = "method", .value = rec.method },
            .{ .key = "status", .value = status_s },
            .{ .key = "request_id", .value = rec.request_id },
        });
    }
};

test "auditlog: keyFingerprint is stable, short, and never the key" {
    const alloc = std.testing.allocator;
    const fp = try keyFingerprint(alloc, "my-secret-key");
    defer alloc.free(fp);
    try std.testing.expectEqual(@as(usize, 8), fp.len);
    try std.testing.expect(std.mem.indexOf(u8, fp, "my-secret-key") == null);
    const fp2 = try keyFingerprint(alloc, "my-secret-key");
    defer alloc.free(fp2);
    try std.testing.expectEqualStrings(fp, fp2);
    const fp3 = try keyFingerprint(alloc, "another-key");
    defer alloc.free(fp3);
    try std.testing.expect(!std.mem.eql(u8, fp, fp3));
    const anon = try keyFingerprint(alloc, null);
    defer alloc.free(anon);
    try std.testing.expectEqualStrings("anonymous", anon);
}

test "auditlog: renderJson escapes and shapes the record" {
    const alloc = std.testing.allocator;
    const line = try renderJson(alloc, .{
        .ts = 1794540816,
        .consumer = "sando",
        .key_fingerprint = "ab12cd34",
        .route = "/v1/query",
        .method = "POST",
        .status = 200,
        .request_id = "req-abc",
    });
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"consumer\":\"sando\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"key_fp\":\"ab12cd34\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"request_id\":\"req-abc\"") != null);
}

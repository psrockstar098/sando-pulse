//! Graph API client (Roadmap 3.2, design doc section 2).
//!
//! Versioned endpoint, fields id/message/created_time/permalink_url
//! plus the permission-dependent engagement summaries, access token,
//! pagination. Transport is the proven CONNECT+TLS fetcher — the
//! client builds the URL and hands it to `fetchers.fetchFeed`; it
//! never opens a socket itself.
//!
//! The live Graph API path is NEVER exercised without credentials:
//! `fetchGraph` returns error.Unavailable when no token is
//! configured, and the connector's check() gate keeps the pipeline
//! from calling it at all in that state.

const std = @import("std");
const auth = @import("auth.zig");
const fetchers = @import("../../fetchers.zig");
const pagination = @import("pagination.zig");

/// Fields requested for every post. Engagement summaries are
/// permission-dependent: when Meta does not expose them the fields
/// are simply absent from the response and parse as null.
pub const post_fields = "id,message,created_time,permalink_url,reactions.summary(true),comments.summary(true),shares";

/// One raw post as returned by the Graph API, with exact presence
/// flags: a missing engagement field means "not exposed" (null in
/// the normalized record), never zero.
pub const RawPost = struct {
    id: []const u8 = "",
    message: []const u8 = "",
    created_time: []const u8 = "",
    permalink_url: []const u8 = "",
    reactions: ?u64 = null,
    comments: ?u64 = null,
    shares: ?u64 = null,
};

pub const PostsPage = struct {
    posts: []RawPost,
    paging: pagination.Paging,
};

fn getString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn getSummaryCount(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const s = o.get("summary") orelse return null;
    const so = switch (s) {
        .object => |so| so,
        else => return null,
    };
    const n = so.get("total_count") orelse return null;
    return switch (n) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn getSharesCount(obj: std.json.ObjectMap) ?u64 {
    const v = obj.get("shares") orelse return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const n = o.get("count") orelse return null;
    return switch (n) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Parse the `data` array + `paging` of a Graph API posts response.
/// Parsed through std.json.Value so engagement presence is exact:
// a field absent from an item stays null in the normalized record.
pub fn parsePostsPage(alloc: std.mem.Allocator, body: []const u8) !PostsPage {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    const data = root.get("data") orelse return .{ .posts = &.{}, .paging = .{} };
    const arr = switch (data) {
        .array => |a| a,
        else => return error.BadResponse,
    };
    var out: std.ArrayList(RawPost) = .empty;
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        try out.append(alloc, .{
            .id = try alloc.dupe(u8, getString(obj, "id")),
            .message = try alloc.dupe(u8, getString(obj, "message")),
            .created_time = try alloc.dupe(u8, getString(obj, "created_time")),
            .permalink_url = try alloc.dupe(u8, getString(obj, "permalink_url")),
            .reactions = getSummaryCount(obj, "reactions"),
            .comments = getSummaryCount(obj, "comments"),
            .shares = getSharesCount(obj),
        });
    }
    var paging = pagination.Paging{};
    if (root.get("paging")) |pv| {
        if (pv == .object) {
            const po = pv.object;
            if (po.get("next")) |n| {
                if (n == .string and n.string.len > 0) paging.next = try alloc.dupe(u8, n.string);
            }
            if (po.get("cursors")) |cv| {
                if (cv == .object) {
                    if (cv.object.get("after")) |a| {
                        if (a == .string and a.string.len > 0) paging.after = try alloc.dupe(u8, a.string);
                    }
                    if (cv.object.get("before")) |b| {
                        if (b == .string and b.string.len > 0) paging.before = try alloc.dupe(u8, b.string);
                    }
                }
            }
        }
    }
    return .{ .posts = try out.toOwnedSlice(alloc), .paging = paging };
}

/// Percent-encode a query value (token, cursor). Unreserved
/// [A-Za-z0-9-_.~] pass through; everything else becomes %XX.
pub fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (ok) {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build the posts URL for a page:
/// GET https://graph.facebook.com/{version}/{page_id}/posts
///     ?fields=...&limit=N&access_token=...[&after=cursor]
pub fn buildPostsUrl(
    alloc: std.mem.Allocator,
    cfg: auth.AuthConfig,
    page_id: []const u8,
    limit: u32,
    after: ?[]const u8,
) ![]u8 {
    const token = cfg.access_token orelse return error.Unavailable;
    const enc_token = try urlEncode(alloc, token);
    defer alloc.free(enc_token);
    if (after) |cursor| {
        const enc_cursor = try urlEncode(alloc, cursor);
        defer alloc.free(enc_cursor);
        return std.fmt.allocPrint(alloc, "https://graph.facebook.com/{s}/{s}/posts?fields={s}&limit={d}&after={s}&access_token={s}", .{
            cfg.api_version, page_id, post_fields, limit, enc_cursor, enc_token,
        });
    }
    return std.fmt.allocPrint(alloc, "https://graph.facebook.com/{s}/{s}/posts?fields={s}&limit={d}&access_token={s}", .{
        cfg.api_version, page_id, post_fields, limit, enc_token,
    });
}

/// Fetch a Graph API URL (the URL is expected to already carry the
/// access token; when it does not and a token is configured, the
/// token is appended). Returns error.Unavailable with no token.
/// The body is the caller's to free.
pub fn fetchGraph(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cfg: auth.AuthConfig,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const token = cfg.access_token orelse return error.Unavailable;
    if (std.mem.indexOf(u8, url, "access_token=") != null) {
        return fetchers.fetchFeed(alloc, io, url, environ);
    }
    const enc_token = try urlEncode(alloc, token);
    defer alloc.free(enc_token);
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, url, '?') != null) "&" else "?";
    const full = try std.fmt.allocPrint(alloc, "{s}{s}access_token={s}", .{ url, sep, enc_token });
    defer alloc.free(full);
    return fetchers.fetchFeed(alloc, io, full, environ);
}

test "client builds the posts URL with version, fields, token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cfg = auth.AuthConfig{ .access_token = "tok|123", .api_version = "v26.0" };
    const url = try buildPostsUrl(alloc, cfg, "456", 25, null);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://graph.facebook.com/v26.0/456/posts?fields=id,message,created_time,permalink_url"));
    try std.testing.expect(std.mem.indexOf(u8, url, "limit=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "access_token=tok%7C123") != null);
    const paged = try buildPostsUrl(alloc, cfg, "456", 25, "cur sor");
    try std.testing.expect(std.mem.indexOf(u8, paged, "after=cur%20sor") != null);
    try std.testing.expectError(error.Unavailable, buildPostsUrl(alloc, .{}, "456", 25, null));
}

test "client parses a posts page; absent engagement is null, present is a count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body =
        \\{"data":[{"id":"123_456","message":"Fuel prices rise in Monrovia","created_time":"2026-11-12T10:00:00+0000","permalink_url":"https://www.facebook.com/123/posts/456","reactions":{"summary":{"total_count":12}},"comments":{"summary":{"total_count":3}}},{"id":"123_789","message":"Market day in Red Light","created_time":"2026-11-12T11:00:00+0000","permalink_url":"https://www.facebook.com/123/posts/789"}],"paging":{"cursors":{"after":"abc"},"next":"https://graph.facebook.com/v26.0/123/posts?after=abc"}}
    ;
    const page = try parsePostsPage(alloc, body);
    try std.testing.expectEqual(@as(usize, 2), page.posts.len);
    try std.testing.expectEqualStrings("123_456", page.posts[0].id);
    try std.testing.expectEqualStrings("Fuel prices rise in Monrovia", page.posts[0].message);
    try std.testing.expectEqual(@as(?u64, 12), page.posts[0].reactions);
    try std.testing.expectEqual(@as(?u64, 3), page.posts[0].comments);
    try std.testing.expectEqual(@as(?u64, null), page.posts[0].shares);
    try std.testing.expectEqualStrings("123_789", page.posts[1].id);
    try std.testing.expectEqual(@as(?u64, null), page.posts[1].reactions);
    try std.testing.expectEqual(@as(?u64, null), page.posts[1].comments);
    try std.testing.expectEqual(@as(?u64, null), page.posts[1].shares);
    try std.testing.expect(page.paging.hasMore());
    try std.testing.expectEqualStrings("abc", page.paging.after.?);
    try std.testing.expect(page.paging.next != null);
}

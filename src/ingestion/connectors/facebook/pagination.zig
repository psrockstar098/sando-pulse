//! Graph API pagination (Roadmap 3.2, design doc section 2).
//!
//! A page of posts carries `paging: { cursors: { after, before },
//! next }`. The `next` URL is a complete Graph API URL for the
//! following page; when it is absent there are no more pages. The
//! `after` cursor is kept separately so the client can rebuild the
//! request URL (e.g. after a retry) without depending on `next`.

const std = @import("std");

pub const Paging = struct {
    next: ?[]const u8 = null,
    after: ?[]const u8 = null,
    before: ?[]const u8 = null,

    pub fn hasMore(self: Paging) bool {
        return self.next != null or self.after != null;
    }
};

/// Wire shape of the `paging` object. Unknown fields ignored.
const PagingJson = struct {
    cursors: struct {
        after: []const u8 = "",
        before: []const u8 = "",
    } = .{},
    next: []const u8 = "",

    pub fn toPaging(self: PagingJson) Paging {
        return .{
            .next = if (self.next.len > 0) self.next else null,
            .after = if (self.cursors.after.len > 0) self.cursors.after else null,
            .before = if (self.cursors.before.len > 0) self.cursors.before else null,
        };
    }
};

/// Parse a `paging` object out of a Graph API response body. Returns
/// null when the body has no paging object at all.
pub fn parsePaging(alloc: std.mem.Allocator, body: []const u8) !?Paging {
    const Envelope = struct {
        paging: ?PagingJson = null,
    };
    const env = std.json.parseFromSliceLeaky(Envelope, alloc, body, .{ .ignore_unknown_fields = true }) catch return null;
    const p = env.paging orelse return null;
    return p.toPaging();
}

test "pagination: next + cursors parsed; absent paging is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const with_paging =
        \\{"data":[],"paging":{"cursors":{"after":"abc123","before":"zzz"},"next":"https://graph.facebook.com/v26.0/123/posts?after=abc123"}}
    ;
    const p = (try parsePaging(alloc, with_paging)).?;
    try std.testing.expect(p.hasMore());
    try std.testing.expectEqualStrings("abc123", p.after.?);
    try std.testing.expectEqualStrings("zzz", p.before.?);
    try std.testing.expect(p.next != null);
    const no_paging = "{\"data\":[]}";
    try std.testing.expect(try parsePaging(alloc, no_paging) == null);
    const empty = "{\"data\":[],\"paging\":{}}";
    const e = (try parsePaging(alloc, empty)).?;
    try std.testing.expect(!e.hasMore());
}

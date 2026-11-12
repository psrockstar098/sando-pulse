//! Shared data types for Sando Pulse.
//! One model for every store backend: the in-memory store and the PostgreSQL
//! store both read and write these exact shapes, so there is one system, not two.

const std = @import("std");

/// One indexed piece of content, always traceable to its real origin.
/// `text` is the article summary/description exactly as published (cleaned of
/// markup); Pulse never invents text, titles, or quotes.
pub const Document = struct {
    /// content hash (hex SHA-256 of source_id + url + title); primary key.
    id: []const u8,
    source_id: []const u8,
    source_name: []const u8,
    source_url: []const u8,
    title: []const u8,
    url: []const u8,
    text: []const u8,
    published_at: ?i64,
    fetched_at: i64,
    /// 0.0..1.0, from the source registry (news 0.70, government 0.88, ...).
    reliability: f32,
    topics: []const []const u8,
    content_hash: []const u8,
};

/// Internal search request produced by the query planner.
pub const SearchQuery = struct {
    terms: []const []const u8 = &.{},
    counties: []const []const u8 = &.{},
    organizations: []const []const u8 = &.{},
    topics: []const []const u8 = &.{},
    limit: usize = 10,
};

/// The planner's output: what the query means, in Pulse's own terms.
/// Returned to the caller inside every /v1/query response.
pub const QueryPlan = struct {
    intent: []const u8,
    topics: []const []const u8,
    counties: []const []const u8,
    organizations: []const []const u8,
    time_range: ?[]const u8,
    sources: []const []const u8,
};

/// One source's document count, for /v1/sources.
pub const SourceCount = struct {
    source_id: []const u8,
    count: usize,
};

/// Deterministic content id: hex SHA-256 over source_id + "\n" + url + "\n" + title.
/// Two fetches of the same article produce the same id, so ingestion is idempotent.
pub fn contentHash(alloc: std.mem.Allocator, source_id: []const u8, url: []const u8, title: []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(source_id);
    h.update("\n");
    h.update(url);
    h.update("\n");
    h.update(title);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

test "contentHash is deterministic and stable across inputs" {
    const a = try contentHash(std.testing.allocator, "new-dawn", "https://example.com/a", "Title");
    defer std.testing.allocator.free(a);
    const b = try contentHash(std.testing.allocator, "new-dawn", "https://example.com/a", "Title");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(usize, 64), a.len);
    const c = try contentHash(std.testing.allocator, "new-dawn", "https://example.com/b", "Title");
    defer std.testing.allocator.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

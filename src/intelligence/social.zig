//! Social ingestion plumbing (Roadmap 7.7, GATED).
//!
//! A registry fed ONLY by real authorized connector data, plus
//! hashtag tracking over that data and a "social" trend lane for
//! the trends response. No scrapers, no faked posts, no invented
//! engagement, no synthesized counts.
//!
//! Today no social connector is configured — Facebook has no Meta
//! app/token, X and Reddit exist only as stubs — so the registry
//! is empty and every social surface reports that honestly:
//! `GET /v1/social` lists the connectors with their unavailable
//! reasons, and the trends response carries an empty `social`
//! section. When a connector is authorized and its collection job
//! calls `ingest`, posts land here and the hashtag/trend plumbing
//! lights up with real data. Nothing else writes to the registry.

const std = @import("std");
const trending = @import("trending.zig");

/// One real post from an authorized social connector. `platform`
/// is the connector kind name: "facebook", "x", "reddit",
/// "youtube". Only a connector collection job constructs these,
/// from the API response it actually received.
pub const SocialPost = struct {
    id: []const u8,
    platform: []const u8,
    author: []const u8,
    text: []const u8,
    posted_at: i64, // unix seconds
    url: []const u8 = "",
};

pub const HashtagCount = struct {
    tag: []const u8, // without the '#', lowercased
    count: usize, // posts using it (once per post, not per mention)
};

/// Bounded in-memory registry of authorized social posts.
/// Oldest posts are evicted past the cap; the registry never
/// grows without bound and never persists invented data.
pub const SocialRegistry = struct {
    alloc: std.mem.Allocator,
    posts: std.ArrayList(SocialPost) = .empty,

    pub const max_posts: usize = 1000;

    pub fn init(alloc: std.mem.Allocator) SocialRegistry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SocialRegistry) void {
        for (self.posts.items) |p| {
            self.alloc.free(p.id);
            self.alloc.free(p.platform);
            self.alloc.free(p.author);
            self.alloc.free(p.text);
            self.alloc.free(p.url);
        }
        self.posts.deinit(self.alloc);
    }

    pub fn count(self: *const SocialRegistry) usize {
        return self.posts.items.len;
    }

    /// The ONLY entry point for social data. Callers are connector
    /// collection jobs, with posts from an authorized API response.
    /// Nothing in Pulse synthesizes a post.
    pub fn ingest(self: *SocialRegistry, post: SocialPost) !void {
        if (self.posts.items.len >= max_posts) {
            const old = self.posts.orderedRemove(0);
            self.alloc.free(old.id);
            self.alloc.free(old.platform);
            self.alloc.free(old.author);
            self.alloc.free(old.text);
            self.alloc.free(old.url);
        }
        try self.posts.append(self.alloc, .{
            .id = try self.alloc.dupe(u8, post.id),
            .platform = try self.alloc.dupe(u8, post.platform),
            .author = try self.alloc.dupe(u8, post.author),
            .text = try self.alloc.dupe(u8, post.text),
            .posted_at = post.posted_at,
            .url = try self.alloc.dupe(u8, post.url),
        });
    }

    pub fn countByPlatform(self: *const SocialRegistry, platform: []const u8) usize {
        var n: usize = 0;
        for (self.posts.items) |p| {
            if (std.mem.eql(u8, p.platform, platform)) n += 1;
        }
        return n;
    }

    /// Hashtag counts over the stored posts, most used first.
    /// A post counts once per tag even when it repeats the tag.
    /// Tags are the `#word` runs in the post text (letters, digits,
    /// underscore), lowercased.
    pub fn topHashtags(self: *const SocialRegistry, alloc: std.mem.Allocator, limit: usize) ![]HashtagCount {
        var counts = std.StringHashMap(usize).init(alloc);
        defer counts.deinit();
        for (self.posts.items) |p| {
            var seen = std.StringHashMap(void).init(alloc);
            defer seen.deinit();
            var i: usize = 0;
            while (i < p.text.len) {
                if (p.text[i] != '#') {
                    i += 1;
                    continue;
                }
                var j = i + 1;
                while (j < p.text.len and isTagChar(p.text[j])) : (j += 1) {}
                if (j > i + 1) {
                    const tag = try std.ascii.allocLowerString(alloc, p.text[i + 1 .. j]);
                    if (!seen.contains(tag)) {
                        try seen.put(tag, {});
                        const e = try counts.getOrPut(tag);
                        if (!e.found_existing) e.value_ptr.* = 0;
                        e.value_ptr.* += 1;
                    }
                }
                i = j;
            }
        }
        var out: std.ArrayList(HashtagCount) = .empty;
        var it = counts.iterator();
        while (it.next()) |e| {
            try out.append(alloc, .{ .tag = e.key_ptr.*, .count = e.value_ptr.* });
        }
        std.mem.sort(HashtagCount, out.items, {}, struct {
            fn less(_: void, a: HashtagCount, b: HashtagCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.tag, b.tag);
            }
        }.less);
        if (out.items.len > limit) out.items = out.items[0..limit];
        return out.toOwnedSlice(alloc);
    }

    /// Social trend lane for the trends response: one row per
    /// hashtag, category "social", recent/prior windows counted
    /// from real posts. Same velocity/score formula as the
    /// document trends (see trending.trendScore). Empty when the
    /// registry is empty — never synthesized.
    pub fn socialTrends(self: *const SocialRegistry, alloc: std.mem.Allocator, now: i64, window_s: u64) ![]trending.TopicTrend {
        var tags = std.StringHashMap(struct { recent: usize, prior: usize }).init(alloc);
        defer tags.deinit();
        const window: i64 = @intCast(window_s);
        for (self.posts.items) |p| {
            const recent = p.posted_at >= now - window and p.posted_at <= now;
            const prior = p.posted_at >= now - 2 * window and p.posted_at < now - window;
            if (!recent and !prior) continue;
            var seen = std.StringHashMap(void).init(alloc);
            defer seen.deinit();
            var i: usize = 0;
            while (i < p.text.len) {
                if (p.text[i] != '#') {
                    i += 1;
                    continue;
                }
                var j = i + 1;
                while (j < p.text.len and isTagChar(p.text[j])) : (j += 1) {}
                if (j > i + 1) {
                    const tag = try std.ascii.allocLowerString(alloc, p.text[i + 1 .. j]);
                    if (!seen.contains(tag)) {
                        try seen.put(tag, {});
                        const e = try tags.getOrPut(tag);
                        if (!e.found_existing) e.value_ptr.* = .{ .recent = 0, .prior = 0 };
                        if (recent) e.value_ptr.recent += 1;
                        if (prior) e.value_ptr.prior += 1;
                    }
                }
                i = j;
            }
        }
        var out: std.ArrayList(trending.TopicTrend) = .empty;
        var it = tags.iterator();
        while (it.next()) |e| {
            const recent_f: f64 = @floatFromInt(e.value_ptr.recent);
            const prior_f: f64 = @floatFromInt(@max(e.value_ptr.prior, 1));
            const velocity = recent_f / prior_f;
            const score = @log(1.0 + recent_f) * @min(@max(velocity, 0.25), 4.0);
            const topic = try std.mem.concat(alloc, u8, &.{ "#", e.key_ptr.* });
            try out.append(alloc, .{
                .topic = topic,
                .category = "social",
                .recent_count = e.value_ptr.recent,
                .prior_count = e.value_ptr.prior,
                .velocity = velocity,
                .score = score,
            });
        }
        std.mem.sort(trending.TopicTrend, out.items, {}, struct {
            fn less(_: void, a: trending.TopicTrend, b: trending.TopicTrend) bool {
                return a.score > b.score;
            }
        }.less);
        return out.toOwnedSlice(alloc);
    }
};

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "social registry: empty until real data arrives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = SocialRegistry.init(alloc);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expectEqual(@as(usize, 0), (try reg.topHashtags(alloc, 10)).len);
    try std.testing.expectEqual(@as(usize, 0), (try reg.socialTrends(alloc, 1000, 86400)).len);
}

test "social registry: hashtags counted once per post, case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = SocialRegistry.init(alloc);
    defer reg.deinit();
    try reg.ingest(.{ .id = "1", .platform = "facebook", .author = "A", .text = "Big game tonight #Geez #geez #Liberia!", .posted_at = 900, .url = "" });
    try reg.ingest(.{ .id = "2", .platform = "x", .author = "B", .text = "#Geez vibes #liberia", .posted_at = 950, .url = "" });
    try reg.ingest(.{ .id = "3", .platform = "facebook", .author = "C", .text = "No hashtags here", .posted_at = 960, .url = "" });
    try std.testing.expectEqual(@as(usize, 3), reg.count());
    try std.testing.expectEqual(@as(usize, 2), reg.countByPlatform("facebook"));
    try std.testing.expectEqual(@as(usize, 1), reg.countByPlatform("x"));
    try std.testing.expectEqual(@as(usize, 0), reg.countByPlatform("reddit"));
    const top = try reg.topHashtags(alloc, 10);
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqualStrings("geez", top[0].tag);
    try std.testing.expectEqual(@as(usize, 2), top[0].count);
    try std.testing.expectEqualStrings("liberia", top[1].tag);
    try std.testing.expectEqual(@as(usize, 2), top[1].count);
    const trends = try reg.socialTrends(alloc, 1000, 86400);
    try std.testing.expectEqual(@as(usize, 2), trends.len);
    try std.testing.expectEqualStrings("social", trends[0].category);
    try std.testing.expectEqual(@as(usize, 2), trends[0].recent_count);
}

test "social registry: bounded, oldest evicted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = SocialRegistry.init(alloc);
    defer reg.deinit();
    var i: usize = 0;
    while (i < SocialRegistry.max_posts + 5) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "p{d}", .{i});
        try reg.ingest(.{ .id = id, .platform = "x", .author = "A", .text = "hi", .posted_at = 1000, .url = "" });
    }
    try std.testing.expectEqual(SocialRegistry.max_posts, reg.count());
    try std.testing.expectEqualStrings("p5", reg.posts.items[0].id);
}

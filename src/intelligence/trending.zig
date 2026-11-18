//! Geez and trending engine (Roadmap 4.2): trending topic detection,
//! engagement velocity, discussion volume, topic popularity, geographic
//! trending, entertainment / political / sports trends, historical
//! rankings, monthly trend snapshots.
//!
//! Pure functions over scanned documents + monthly aggregates — no I/O.
//! "Geez" is Liberian English for the gist — the culture / entertainment
//! topics are the Geez lane, labelled as such rather than given a
//! separate invented signal. Velocity compares a recent window against
//! the equal-length window before it; a topic with no prior-window docs
//! still needs real recent volume to rank (the log-volume term), so a
//! single fresh article cannot top the chart alone.

const std = @import("std");
const types = @import("../common/types.zig");
const knowledge = @import("../storage/knowledge.zig");
const entities_mod = @import("../engine/entities.zig");

/// Trending window names (day, week, month).
pub fn parseWindow(s: ?[]const u8) ?u64 {
    const w = s orelse return 86400;
    if (std.mem.eql(u8, w, "24h")) return 86400;
    if (std.mem.eql(u8, w, "7d")) return 7 * 86400;
    if (std.mem.eql(u8, w, "30d")) return 30 * 86400;
    return null;
}

/// Trend lane for a topic. Politics and sports get their own lanes;
/// culture (music, festival, entertainment, geez) is the Geez lane;
/// everything else is general news.
pub fn categoryOf(topic: []const u8) []const u8 {
    if (std.mem.eql(u8, topic, "politics")) return "political";
    if (std.mem.eql(u8, topic, "sports")) return "sports";
    if (std.mem.eql(u8, topic, "culture")) return "entertainment";
    return "general";
}

pub const TopicTrend = struct {
    topic: []const u8,
    category: []const u8,
    recent_count: usize,
    prior_count: usize,
    /// recent / max(prior, 1): >1 accelerating, <1 cooling.
    velocity: f64,
    /// ln(1 + recent) * clamp(velocity, 0.25, 4.0).
    score: f64,
};

fn trendScore(recent: usize, prior: usize) struct { velocity: f64, score: f64 } {
    const recent_f = @as(f64, @floatFromInt(recent));
    const prior_f = @as(f64, @floatFromInt(@max(prior, 1)));
    const velocity = recent_f / prior_f;
    const factor = @min(@max(velocity, 0.25), 4.0);
    return .{ .velocity = velocity, .score = @log(1.0 + recent_f) * factor };
}

/// Rank topics by recent-window volume and velocity. `docs` are scanned
/// from the store (any order); only docs whose timestamp falls in the
/// recent or prior window count. A topic is counted once per document.
pub fn computeTrends(alloc: std.mem.Allocator, docs: []const types.Document, now: i64, window_s: u64) ![]TopicTrend {
    const window = @as(i64, @intCast(window_s));
    const recent_start = now - window;
    const prior_start = now - 2 * window;
    var counts = std.StringHashMap(struct { recent: usize, prior: usize }).init(alloc);
    defer counts.deinit();
    for (docs) |doc| {
        const ts = knowledge.docTs(doc);
        const slot: ?enum { recent, prior } = if (ts >= recent_start and ts <= now)
            .recent
        else if (ts >= prior_start and ts < recent_start)
            .prior
        else
            null;
        const which = slot orelse continue;
        for (doc.topics) |topic| {
            var entry = counts.getPtr(topic) orelse blk: {
                try counts.put(topic, .{ .recent = 0, .prior = 0 });
                break :blk counts.getPtr(topic).?;
            };
            switch (which) {
                .recent => entry.recent += 1,
                .prior => entry.prior += 1,
            }
        }
    }
    var out: std.ArrayList(TopicTrend) = .empty;
    errdefer out.deinit(alloc);
    var it = counts.iterator();
    while (it.next()) |kv| {
        const s = trendScore(kv.value_ptr.recent, kv.value_ptr.prior);
        try out.append(alloc, .{
            .topic = kv.key_ptr.*,
            .category = categoryOf(kv.key_ptr.*),
            .recent_count = kv.value_ptr.recent,
            .prior_count = kv.value_ptr.prior,
            .velocity = s.velocity,
            .score = s.score,
        });
    }
    // Highest score first; ties break on recent volume.
    std.mem.sort(TopicTrend, out.items, {}, struct {
        fn less(_: void, a: TopicTrend, b: TopicTrend) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.recent_count > b.recent_count;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

pub const GeoTrend = struct {
    county: []const u8,
    doc_count: usize,
    /// Most frequent topic among this county's window docs.
    top_topic: []const u8,
};

/// Geographic trending: documents in the recent window, bucketed by
/// the counties named in their title + text. A document naming two
/// counties counts for both. Counties come from the entity extractor's
/// fixed county list, so only real Liberian counties can appear.
pub fn computeGeoTrends(alloc: std.mem.Allocator, docs: []const types.Document, now: i64, window_s: u64) ![]GeoTrend {
    const window = @as(i64, @intCast(window_s));
    const recent_start = now - window;
    const Acc = struct {
        count: usize = 0,
        topics: std.StringHashMap(usize),
    };
    var by_county = std.StringHashMap(*Acc).init(alloc);
    defer {
        var it = by_county.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.topics.deinit();
            alloc.destroy(kv.value_ptr.*);
        }
        by_county.deinit();
    }
    for (docs) |doc| {
        const ts = knowledge.docTs(doc);
        if (ts < recent_start or ts > now) continue;
        const combined = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        defer alloc.free(combined);
        const ent = try entities_mod.extract(alloc, combined);
        defer entities_mod.freeEntities(alloc, ent);
        for (ent.counties) |county| {
            const acc = by_county.get(county) orelse blk: {
                const a = try alloc.create(Acc);
                a.* = .{ .topics = std.StringHashMap(usize).init(alloc) };
                try by_county.put(county, a);
                break :blk a;
            };
            acc.count += 1;
            for (doc.topics) |topic| {
                const cur = acc.topics.get(topic) orelse 0;
                try acc.topics.put(topic, cur + 1);
            }
        }
    }
    var out: std.ArrayList(GeoTrend) = .empty;
    errdefer out.deinit(alloc);
    var it = by_county.iterator();
    while (it.next()) |kv| {
        var top_topic: []const u8 = "";
        var top_n: usize = 0;
        var tit = kv.value_ptr.*.topics.iterator();
        while (tit.next()) |tk| {
            if (tk.value_ptr.* > top_n) {
                top_n = tk.value_ptr.*;
                top_topic = tk.key_ptr.*;
            }
        }
        try out.append(alloc, .{
            .county = kv.key_ptr.*,
            .doc_count = kv.value_ptr.*.count,
            .top_topic = top_topic,
        });
    }
    std.mem.sort(GeoTrend, out.items, {}, struct {
        fn less(_: void, a: GeoTrend, b: GeoTrend) bool {
            return a.doc_count > b.doc_count;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

pub const TopicCount = struct {
    topic: []const u8,
    doc_count: usize,
};

pub const MonthSnapshot = struct {
    year_month: []const u8,
    topics: []TopicCount,
};

/// Monthly snapshot for one "YYYY-MM" from the maintenance aggregates
/// (Roadmap 3.5): the month's topics by document volume, most first.
pub fn snapshotFromAggregates(alloc: std.mem.Allocator, aggregates: []const knowledge.MonthlyAggregate, year_month: []const u8) !MonthSnapshot {
    var topics: std.ArrayList(TopicCount) = .empty;
    errdefer topics.deinit(alloc);
    for (aggregates) |row| {
        if (!std.mem.eql(u8, row.year_month, year_month)) continue;
        try topics.append(alloc, .{ .topic = row.topic, .doc_count = row.doc_count });
    }
    std.mem.sort(TopicCount, topics.items, {}, struct {
        fn less(_: void, a: TopicCount, b: TopicCount) bool {
            return a.doc_count > b.doc_count;
        }
    }.less);
    return .{ .year_month = year_month, .topics = try topics.toOwnedSlice(alloc) };
}

pub const MonthCount = struct {
    year_month: []const u8,
    doc_count: usize,
};

/// Historical ranking for one topic: its monthly volume over time,
/// oldest month first. Empty when the topic never appears.
pub fn historicalRankings(alloc: std.mem.Allocator, aggregates: []const knowledge.MonthlyAggregate, topic: []const u8) ![]MonthCount {
    var rows: std.ArrayList(MonthCount) = .empty;
    errdefer rows.deinit(alloc);
    for (aggregates) |row| {
        if (!std.mem.eql(u8, row.topic, topic)) continue;
        try rows.append(alloc, .{ .year_month = row.year_month, .doc_count = row.doc_count });
    }
    std.mem.sort(MonthCount, rows.items, {}, struct {
        fn less(_: void, a: MonthCount, b: MonthCount) bool {
            return std.mem.lessThan(u8, a.year_month, b.year_month);
        }
    }.less);
    return rows.toOwnedSlice(alloc);
}

/// The Geez lane: entertainment-category trends, in rank order, capped
/// at `limit`. Used by the precomputed briefing.
pub fn topGeez(alloc: std.mem.Allocator, trends: []const TopicTrend, limit: usize) ![]TopicTrend {
    var out: std.ArrayList(TopicTrend) = .empty;
    errdefer out.deinit(alloc);
    for (trends) |t| {
        if (out.items.len >= limit) break;
        if (std.mem.eql(u8, t.category, "entertainment")) try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

fn testDoc(title: []const u8, topics: []const []const u8, ts: i64) types.Document {
    return .{
        .id = "d",
        .source_id = "s",
        .source_name = "S",
        .source_url = "https://example.com",
        .title = title,
        .url = "https://example.com/x",
        .text = title,
        .published_at = ts,
        .fetched_at = ts,
        .reliability = 0.7,
        .topics = topics,
        .content_hash = "h",
        .lang = "en",
    };
}

test "parseWindow accepts 24h/7d/30d, rejects the rest" {
    try std.testing.expectEqual(@as(?u64, 86400), parseWindow("24h"));
    try std.testing.expectEqual(@as(?u64, 7 * 86400), parseWindow("7d"));
    try std.testing.expectEqual(@as(?u64, 30 * 86400), parseWindow("30d"));
    try std.testing.expectEqual(@as(?u64, 86400), parseWindow(null));
    try std.testing.expect(parseWindow("1h") == null);
    try std.testing.expect(parseWindow("") == null);
}

test "categoryOf maps the lanes" {
    try std.testing.expectEqualStrings("political", categoryOf("politics"));
    try std.testing.expectEqualStrings("sports", categoryOf("sports"));
    try std.testing.expectEqualStrings("entertainment", categoryOf("culture"));
    try std.testing.expectEqualStrings("general", categoryOf("energy"));
    try std.testing.expectEqualStrings("general", categoryOf("health"));
}

test "computeTrends ranks accelerating topics above cooling ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const w: u64 = 86400;
    const docs = [_]types.Document{
        // politics: 1 prior, 4 recent (accelerating).
        testDoc("p1", &.{ "politics" }, now - 90000),
        testDoc("p2", &.{ "politics" }, now - 3600),
        testDoc("p3", &.{ "politics" }, now - 3500),
        testDoc("p4", &.{ "politics" }, now - 3400),
        testDoc("p5", &.{ "politics" }, now - 3300),
        // energy: 4 prior, 1 recent (cooling).
        testDoc("e1", &.{ "energy" }, now - 170000),
        testDoc("e2", &.{ "energy" }, now - 169000),
        testDoc("e3", &.{ "energy" }, now - 168000),
        testDoc("e4", &.{ "energy" }, now - 167000),
        testDoc("e5", &.{ "energy" }, now - 3600),
        // stale: outside both windows, ignored.
        testDoc("s1", &.{ "sports" }, now - 300000),
    };
    const trends = try computeTrends(alloc, &docs, now, w);
    try std.testing.expectEqual(@as(usize, 2), trends.len);
    try std.testing.expectEqualStrings("politics", trends[0].topic);
    try std.testing.expectEqual(@as(usize, 4), trends[0].recent_count);
    try std.testing.expectEqual(@as(usize, 1), trends[0].prior_count);
    try std.testing.expect(trends[0].velocity > 1.0);
    try std.testing.expectEqualStrings("energy", trends[1].topic);
    try std.testing.expect(trends[1].velocity < 1.0);
    try std.testing.expect(trends[0].score > trends[1].score);
}

test "computeTrends counts a topic once per document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const docs = [_]types.Document{
        testDoc("a", &.{ "politics", "energy" }, now - 100),
        testDoc("b", &.{ "politics" }, now - 200),
    };
    const trends = try computeTrends(alloc, &docs, now, 86400);
    try std.testing.expectEqual(@as(usize, 2), trends.len);
    try std.testing.expectEqualStrings("politics", trends[0].topic);
    try std.testing.expectEqual(@as(usize, 2), trends[0].recent_count);
    try std.testing.expectEqual(@as(usize, 1), trends[1].recent_count);
}

test "computeGeoTrends buckets by named county with a top topic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const docs = [_]types.Document{
        testDoc("Fuel queues in Montserrado", &.{ "energy" }, now - 100),
        testDoc("Fuel queues in Montserrado again", &.{ "energy" }, now - 200),
        testDoc("Market day in Lofa", &.{ "economy" }, now - 300),
        testDoc("Old news in Montserrado", &.{ "politics" }, now - 200000),
    };
    const geo = try computeGeoTrends(alloc, &docs, now, 86400);
    try std.testing.expectEqual(@as(usize, 2), geo.len);
    try std.testing.expectEqualStrings("Montserrado", geo[0].county);
    try std.testing.expectEqual(@as(usize, 2), geo[0].doc_count);
    try std.testing.expectEqualStrings("energy", geo[0].top_topic);
    try std.testing.expectEqualStrings("Lofa", geo[1].county);
    try std.testing.expectEqual(@as(usize, 1), geo[1].doc_count);
}

test "snapshotFromAggregates and historicalRankings read monthly rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = [_]knowledge.MonthlyAggregate{
        .{ .year_month = "2026-10", .topic = "politics", .doc_count = 5 },
        .{ .year_month = "2026-10", .topic = "energy", .doc_count = 9 },
        .{ .year_month = "2026-11", .topic = "politics", .doc_count = 12 },
        .{ .year_month = "2026-11", .topic = "energy", .doc_count = 3 },
    };
    const snap = try snapshotFromAggregates(alloc, &rows, "2026-11");
    try std.testing.expectEqualStrings("2026-11", snap.year_month);
    try std.testing.expectEqual(@as(usize, 2), snap.topics.len);
    try std.testing.expectEqualStrings("politics", snap.topics[0].topic);
    try std.testing.expectEqual(@as(usize, 12), snap.topics[0].doc_count);
    const hist = try historicalRankings(alloc, &rows, "politics");
    try std.testing.expectEqual(@as(usize, 2), hist.len);
    try std.testing.expectEqualStrings("2026-10", hist[0].year_month);
    try std.testing.expectEqual(@as(usize, 5), hist[0].doc_count);
    try std.testing.expectEqualStrings("2026-11", hist[1].year_month);
    const empty = try historicalRankings(alloc, &rows, "sports");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "topGeez keeps only the entertainment lane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const trends = [_]TopicTrend{
        .{ .topic = "politics", .category = "political", .recent_count = 9, .prior_count = 1, .velocity = 9, .score = 5 },
        .{ .topic = "culture", .category = "entertainment", .recent_count = 4, .prior_count = 2, .velocity = 2, .score = 3 },
        .{ .topic = "sports", .category = "sports", .recent_count = 3, .prior_count = 1, .velocity = 3, .score = 2 },
    };
    const geez = try topGeez(alloc, &trends, 5);
    try std.testing.expectEqual(@as(usize, 1), geez.len);
    try std.testing.expectEqualStrings("culture", geez[0].topic);
}

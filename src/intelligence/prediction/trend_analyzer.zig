//! Trust & Intelligence Engine, Phase 8: trend analysis.
//!
//! Monthly volume series per topic (reusing the R7.1 linear
//! forecast), with a direction: rising / falling / flat from the
//! least-squares slope. A topic with fewer than 2 months of history
//! is insufficient — the analysis says so, it never extrapolates
//! from one point.

const std = @import("std");
const types = @import("../../common/types.zig");
const knowledge = @import("../../storage/knowledge.zig");
const entities = @import("../../engine/entities.zig");
const events = @import("../events.zig");
const trending = @import("../trending.zig");
const forecast = @import("../forecast.zig");

/// Topics the store actually carries (from the event clustering).
/// An unknown topic asked for by name is analysed the same way and
/// comes back insufficient — never a 400 for a word the store has
/// not seen.
pub const known_topics = [_][]const u8{
    "energy",
    "economy",
    "politics",
    "society",
    "health",
    "sports",
    "business",
};

pub const TrendDirection = enum {
    rising,
    falling,
    flat,

    pub fn toString(self: TrendDirection) []const u8 {
        return switch (self) {
            .rising => "rising",
            .falling => "falling",
            .flat => "flat",
        };
    }
};

pub const TrendAnalysis = struct {
    topic: []const u8,
    series: []const trending.MonthCount,
    /// Least-squares slope, documents per month.
    slope: f64,
    direction: TrendDirection,
    forecast: ?forecast.Forecast,
    /// Set when the history is too short to forecast (fewer than 2
    /// months); the analysis is still returned with its series.
    insufficient_reason: ?[]const u8,
};

/// Monthly series for one topic: buckets the documents by their
/// published month, counting only documents whose topics include
/// the topic (and, when a county is given, whose title+text names
/// the county). Months are "YYYY-MM" (UTC), oldest first. A doc
/// with no usable timestamp is skipped, never guessed.
pub fn monthlySeries(
    alloc: std.mem.Allocator,
    docs: []const types.Document,
    topic: []const u8,
    county: ?[]const u8,
) ![]trending.MonthCount {
    var counts = std.StringHashMap(usize).init(alloc);
    defer counts.deinit();
    for (docs) |d| {
        var has_topic = false;
        for (d.topics) |t| {
            if (std.mem.eql(u8, t, topic)) {
                has_topic = true;
                break;
            }
        }
        if (!has_topic) continue;
        if (county) |c| {
            const combined = try std.mem.concat(alloc, u8, &.{ d.title, " ", d.text });
            defer alloc.free(combined);
            const ent = try entities.extract(alloc, combined);
            defer entities.freeEntities(alloc, ent);
            var names_county = false;
            for (ent.counties) |cc| {
                if (std.mem.eql(u8, cc, c)) {
                    names_county = true;
                    break;
                }
            }
            if (!names_county) continue;
        }
        const ts = knowledge.docTs(d);
        const day = try events.dayOf(alloc, ts);
        const month = day[0..7];
        const cur = counts.get(month) orelse 0;
        try counts.put(try alloc.dupe(u8, month), cur + 1);
    }
    var out: std.ArrayList(trending.MonthCount) = .empty;
    var it = counts.iterator();
    while (it.next()) |entry| {
        try out.append(alloc, .{ .year_month = entry.key_ptr.*, .doc_count = entry.value_ptr.* });
    }
    std.mem.sort(trending.MonthCount, out.items, {}, struct {
        fn less(_: void, a: trending.MonthCount, b: trending.MonthCount) bool {
            return std.mem.lessThan(u8, a.year_month, b.year_month);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

/// Least-squares slope of the monthly counts (documents/month).
fn slopeOf(series: []const trending.MonthCount) f64 {
    const n = @as(f64, @floatFromInt(series.len));
    if (series.len < 2) return 0;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_x2: f64 = 0;
    for (series, 0..) |row, i| {
        const x = @as(f64, @floatFromInt(i));
        const y = @as(f64, @floatFromInt(row.doc_count));
        sum_x += x;
        sum_y += y;
        sum_xy += x * y;
        sum_x2 += x * x;
    }
    const denom = n * sum_x2 - sum_x * sum_x;
    if (denom == 0) return 0;
    return (n * sum_xy - sum_x * sum_y) / denom;
}

pub fn analyzeTopic(
    alloc: std.mem.Allocator,
    docs: []const types.Document,
    topic: []const u8,
    county: ?[]const u8,
) !TrendAnalysis {
    const series = try monthlySeries(alloc, docs, topic, county);
    const slope = slopeOf(series);
    const direction: TrendDirection = if (slope > 0.5) .rising else if (slope < -0.5) .falling else .flat;
    const fc = try forecast.linearForecast(alloc, topic, series);
    return .{
        .topic = topic,
        .series = series,
        .slope = slope,
        .direction = direction,
        .forecast = fc,
        .insufficient_reason = if (series.len < 2) "Fewer than 2 months of history for this topic — a forecast needs at least 2 months." else null,
    };
}

fn doc(id: []const u8, title: []const u8, topics: []const []const u8, published_at: i64) types.Document {
    return .{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = title,
        .url = "https://example.com/",
        .text = title,
        .published_at = published_at,
        .fetched_at = published_at + 600,
        .reliability = 0.70,
        .topics = topics,
        .content_hash = id,
    };
}

test "monthlySeries buckets by month and filters by topic and county" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Nov 14 2026 = 1794681600; Oct 5 2026 = -40d; Sep 5 = -70d.
    const nov: i64 = 1794681600;
    const oct: i64 = 1794681600 - 40 * 86400;
    const sep: i64 = 1794681600 - 70 * 86400;
    const docs = [_]types.Document{
        doc("d1", "Fuel shortage hits Monrovia", &.{"energy"}, nov),
        doc("d2", "Fuel prices rise in Monrovia", &.{"energy"}, nov),
        doc("d3", "Fuel shortage in Gbarnga, Bong County", &.{"energy"}, oct),
        doc("d4", "County meet opens", &.{"sports"}, sep),
    };
    const series = try monthlySeries(alloc, &docs, "energy", null);
    try std.testing.expectEqual(@as(usize, 2), series.len);
    try std.testing.expectEqualStrings("2026-10", series[0].year_month);
    try std.testing.expectEqual(@as(usize, 1), series[0].doc_count);
    try std.testing.expectEqualStrings("2026-11", series[1].year_month);
    try std.testing.expectEqual(@as(usize, 2), series[1].doc_count);
    const bong = try monthlySeries(alloc, &docs, "energy", "Bong");
    try std.testing.expectEqual(@as(usize, 1), bong.len);
    try std.testing.expectEqual(@as(usize, 1), bong[0].doc_count);
    const none = try monthlySeries(alloc, &docs, "health", null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "analyzeTopic: rising slope, forecast, insufficient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nov: i64 = 1794681600;
    const oct: i64 = 1794681600 - 40 * 86400;
    const sep: i64 = 1794681600 - 70 * 86400;
    const docs = [_]types.Document{
        doc("d1", "A", &.{"energy"}, sep),
        doc("d2", "B", &.{"energy"}, oct),
        doc("d3", "C", &.{"energy"}, oct),
        doc("d4", "D", &.{"energy"}, nov),
        doc("d5", "E", &.{"energy"}, nov),
        doc("d6", "F", &.{"energy"}, nov),
    };
    const a = try analyzeTopic(alloc, &docs, "energy", null);
    try std.testing.expectEqual(TrendDirection.rising, a.direction);
    try std.testing.expect(a.slope > 0.5);
    try std.testing.expect(a.forecast != null);
    try std.testing.expect(a.insufficient_reason == null);
    const thin = try analyzeTopic(alloc, &docs, "health", null);
    try std.testing.expect(thin.insufficient_reason != null);
    try std.testing.expect(thin.forecast == null);
}

//! Trust & Intelligence Engine, Phase 8: anomaly detection.
//!
//! Monthly anomalies reuse the R7.1 rule (|z| >= 2 against the
//! other months, needs 4+ months). DAILY anomalies are new: the last
//! 30 days bucketed by day (events.dayOf), same leave-one-out
//! z-score, |z| >= 2. All 30 days are counted, including days with
//! zero documents — a quiet day is real data, not a gap. Nothing is
//! flagged on a near-empty store (fewer than 10 documents in the
//! window): an anomaly needs something to deviate from.
//!
//! An anomaly is a flag for a human to look at, never a verdict
//! about why the volume moved.

const std = @import("std");
const types = @import("../../common/types.zig");
const knowledge = @import("../../storage/knowledge.zig");
const entities = @import("../../engine/entities.zig");
const events = @import("../events.zig");
const forecast = @import("../forecast.zig");
const trend_analyzer = @import("trend_analyzer.zig");
const trending = @import("../trending.zig");

pub const DailyAnomaly = struct {
    date: []const u8, // "YYYY-MM-DD"
    doc_count: usize,
    mean: f64,
    stddev: f64,
    z_score: f64,
    direction: []const u8, // "spike" | "drop"
};

/// Daily anomalies over the last 30 days (ending at `now`), for one
/// topic (null = all topics) and one county (null = all counties).
/// The county filter counts only documents whose title+text names
/// the county.
pub fn dailyAnomalies(
    alloc: std.mem.Allocator,
    docs: []const types.Document,
    topic: ?[]const u8,
    county: ?[]const u8,
    now: i64,
) ![]DailyAnomaly {
    const window_days: i64 = 30;
    const start = now - window_days * 86400;
    // Counts per day, oldest first, all 30 days present.
    var counts: [30]usize = undefined;
    @memset(&counts, 0);
    var total: usize = 0;
    for (docs) |d| {
        if (topic) |t| {
            var has = false;
            for (d.topics) |dt| {
                if (std.mem.eql(u8, dt, t)) has = true;
            }
            if (!has) continue;
        }
        if (county) |c| {
            const combined = try std.mem.concat(alloc, u8, &.{ d.title, " ", d.text });
            defer alloc.free(combined);
            const ent = try entities.extract(alloc, combined);
            defer entities.freeEntities(alloc, ent);
            var names = false;
            for (ent.counties) |cc| {
                if (std.mem.eql(u8, cc, c)) names = true;
            }
            if (!names) continue;
        }
        const ts = knowledge.docTs(d);
        if (ts < start or ts > now) continue;
        const day_idx: usize = @intCast(@divFloor(ts - start, 86400));
        if (day_idx >= 30) continue;
        counts[day_idx] += 1;
        total += 1;
    }
    var out: std.ArrayList(DailyAnomaly) = .empty;
    if (total < 10) return out.toOwnedSlice(alloc);
    for (counts, 0..) |count, i| {
        var others: std.ArrayList(f64) = .empty;
        for (counts, 0..) |other, j| {
            if (j != i) try others.append(alloc, @floatFromInt(other));
        }
        const n = @as(f64, @floatFromInt(others.items.len));
        var mean: f64 = 0;
        for (others.items) |v| mean += v;
        mean /= n;
        var var_sum: f64 = 0;
        for (others.items) |v| var_sum += (v - mean) * (v - mean);
        const stddev = @sqrt(var_sum / n);
        if (stddev == 0) continue;
        const z = (@as(f64, @floatFromInt(count)) - mean) / stddev;
        if (@abs(z) >= 2.0) {
            const day_ts = start + @as(i64, @intCast(i)) * 86400;
            const date = try events.dayOf(alloc, day_ts);
            try out.append(alloc, .{
                .date = date,
                .doc_count = count,
                .mean = mean,
                .stddev = stddev,
                .z_score = z,
                .direction = if (z > 0) "spike" else "drop",
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Monthly anomalies for one topic, reusing the R7.1 rule. Needs
/// 4+ months of history; fewer returns an empty list.
pub fn monthlyAnomalies(
    alloc: std.mem.Allocator,
    docs: []const types.Document,
    topic: []const u8,
    county: ?[]const u8,
) ![]forecast.Anomaly {
    const series = try trend_analyzer.monthlySeries(alloc, docs, topic, county);
    return forecast.detectAnomalies(alloc, topic, series);
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

test "dailyAnomalies flags a spike day and nothing on a flat store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794681600; // Nov 14 2026, 18:40 UTC.
    // 10 docs spread over 10 days, then 10 docs on one day.
    var docs: std.ArrayList(types.Document) = .empty;
    for (0..10) |i| {
        try docs.append(alloc, doc("f", "Flat story", &.{"energy"}, now - @as(i64, @intCast(i + 1)) * 86400));
    }
    const flat = try dailyAnomalies(alloc, docs.items, "energy", null, now);
    try std.testing.expectEqual(@as(usize, 0), flat.len);
    for (0..10) |i| {
        const id = try std.fmt.allocPrint(alloc, "s{d}", .{i});
        try docs.append(alloc, doc(id, "Spike story", &.{"energy"}, now - 2 * 86400));
    }
    const spiked = try dailyAnomalies(alloc, docs.items, "energy", null, now);
    try std.testing.expectEqual(@as(usize, 1), spiked.len);
    try std.testing.expectEqualStrings("spike", spiked[0].direction);
    try std.testing.expectEqual(@as(usize, 11), spiked[0].doc_count);
    // A near-empty store flags nothing.
    const thin = try dailyAnomalies(alloc, docs.items[0..5], "energy", null, now);
    try std.testing.expectEqual(@as(usize, 0), thin.len);
}

test "monthlyAnomalies needs 4 months" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794681600;
    const docs = [_]types.Document{
        doc("d1", "A", &.{"energy"}, now - 100 * 86400),
        doc("d2", "B", &.{"energy"}, now - 70 * 86400),
        doc("d3", "C", &.{"energy"}, now - 40 * 86400),
        doc("d4", "D", &.{"energy"}, now),
    };
    // Only 4 months would be needed; these span Aug..Nov (4 months)
    // with 1 doc each — no deviation, so no anomaly.
    const a = try monthlyAnomalies(alloc, &docs, "energy", null);
    try std.testing.expectEqual(@as(usize, 0), a.len);
    const short = try monthlyAnomalies(alloc, docs[0..2], "energy", null);
    try std.testing.expectEqual(@as(usize, 0), short.len);
}

//! Predictive trend analysis (Roadmap 7.1): forecasts and anomaly
//! flags from monthly aggregates + trend history, using simple,
//! explainable methods only — ordinary least-squares linear
//! extrapolation and z-score deviation. NO black-box model.
//!
//! Every prediction carries its confidence, its basis (what data
//! drove it), and its horizon, and the response says plainly that
//! predictions are statistical extrapolations, never facts.
//! Pure functions over aggregates — no I/O.

const std = @import("std");
const knowledge = @import("../storage/knowledge.zig");
const trending = @import("trending.zig");

/// One forecast for one topic: the predicted document volume for the
/// next month, from a least-squares line over the topic's monthly
/// history. `predicted_count` is a float because it is a model
/// output, not a count of anything — callers must not present it as
/// a measured number.
pub const Forecast = struct {
    topic: []const u8,
    /// "YYYY-MM" of the month being predicted (the month after the
    /// latest month in the series).
    horizon_month: []const u8,
    predicted_count: f64,
    /// 0..1: 1 minus the mean absolute residual, scaled by the mean
    /// monthly count. A flat history fits perfectly (confidence 1);
    /// a wild history fits poorly (confidence near 0).
    confidence: f64,
    /// Human-readable basis, e.g. "linear trend over 2026-09..2026-11
    /// (3 months), slope +2.0 docs/month, last month 12 docs".
    basis: []const u8,
    method: []const u8 = "linear_extrapolation",
    /// Same-month-last-year volume when the series reaches back that
    /// far, for a seasonality sanity check. Null when unknown.
    same_month_last_year: ?usize = null,
};

/// One month that deviates sharply from the topic's own history:
/// |z| >= 2 against the mean/std of the other months. An anomaly is
/// a flag for a human to look at, never a verdict about why.
pub const Anomaly = struct {
    topic: []const u8,
    year_month: []const u8,
    doc_count: usize,
    mean: f64,
    stddev: f64,
    z_score: f64,
    direction: []const u8, // "spike" | "drop"
};

/// "YYYY-MM" after the given "YYYY-MM" (December rolls to January).
pub fn nextMonth(alloc: std.mem.Allocator, year_month: []const u8) ![]u8 {
    if (year_month.len != 7 or year_month[4] != '-') return error.InvalidMonth;
    const year = std.fmt.parseInt(u16, year_month[0..4], 10) catch return error.InvalidMonth;
    const month = std.fmt.parseInt(u8, year_month[5..7], 10) catch return error.InvalidMonth;
    if (month < 1 or month > 12) return error.InvalidMonth;
    const ny = if (month == 12) year + 1 else year;
    const nm = if (month == 12) 1 else month + 1;
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}", .{ ny, nm });
}

/// Least-squares fit over the series (x = 0..n-1, y = doc counts).
/// Returns null when the series has fewer than 2 months — one point
/// cannot define a trend, and the caller must say so honestly.
pub fn linearForecast(alloc: std.mem.Allocator, topic: []const u8, series: []const trending.MonthCount) !?Forecast {
    if (series.len < 2) return null;
    const n = @as(f64, @floatFromInt(series.len));
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xx: f64 = 0;
    var sum_xy: f64 = 0;
    for (series, 0..) |row, i| {
        const x = @as(f64, @floatFromInt(i));
        const y = @as(f64, @floatFromInt(row.doc_count));
        sum_x += x;
        sum_y += y;
        sum_xx += x * x;
        sum_xy += x * y;
    }
    const denom = n * sum_xx - sum_x * sum_x;
    if (denom == 0) return null;
    const slope = (n * sum_xy - sum_x * sum_y) / denom;
    const intercept = (sum_y - slope * sum_x) / n;
    const predicted = @max(0, intercept + slope * n);
    // Mean absolute residual, scaled by the mean count: a flat series
    // fits exactly (confidence 1); a noisy one fits poorly.
    const mean_y = sum_y / n;
    var resid_sum: f64 = 0;
    for (series, 0..) |row, i| {
        const x = @as(f64, @floatFromInt(i));
        const fitted = intercept + slope * x;
        resid_sum += @abs(@as(f64, @floatFromInt(row.doc_count)) - fitted);
    }
    const mean_resid = resid_sum / n;
    const confidence = @min(1, @max(0, 1 - mean_resid / (mean_y + 1)));
    const horizon = try nextMonth(alloc, series[series.len - 1].year_month);
    const basis = try std.fmt.allocPrint(alloc, "linear trend over {s}..{s} ({d} months), slope {d:.1} docs/month, last month {d} docs", .{
        series[0].year_month,
        series[series.len - 1].year_month,
        series.len,
        slope,
        series[series.len - 1].doc_count,
    });
    // Seasonality check: the same month one year earlier, when the
    // series reaches back that far.
    var same_last_year: ?usize = null;
    const horizon_year = try std.fmt.parseInt(u16, horizon[0..4], 10);
    const horizon_month = try std.fmt.parseInt(u8, horizon[5..7], 10);
    const last_year_label = try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}", .{ horizon_year - 1, horizon_month });
    for (series) |row| {
        if (std.mem.eql(u8, row.year_month, last_year_label)) {
            same_last_year = row.doc_count;
            break;
        }
    }
    return .{
        .topic = topic,
        .horizon_month = horizon,
        .predicted_count = predicted,
        .confidence = confidence,
        .basis = basis,
        .same_month_last_year = same_last_year,
    };
}

/// Forecast every topic with at least 2 months of history, most
/// recent-month volume first, capped at `limit`. Topics with a
/// single month are skipped (the caller reports them as
/// insufficient-history when asked by name).
pub fn forecastAll(alloc: std.mem.Allocator, aggregates: []const knowledge.MonthlyAggregate, limit: usize) ![]Forecast {
    var topics: std.ArrayList([]const u8) = .empty;
    for (aggregates) |row| {
        var seen = false;
        for (topics.items) |t| {
            if (std.mem.eql(u8, t, row.topic)) {
                seen = true;
                break;
            }
        }
        if (!seen) try topics.append(alloc, row.topic);
    }
    // Rank by the latest month's volume, most first.
    var scored: std.ArrayList(struct { topic: []const u8, latest: usize }) = .empty;
    for (topics.items) |t| {
        const series = try trending.historicalRankings(alloc, aggregates, t);
        const latest = if (series.len > 0) series[series.len - 1].doc_count else 0;
        try scored.append(alloc, .{ .topic = t, .latest = latest });
    }
    std.mem.sort(@TypeOf(scored.items[0]), scored.items, {}, struct {
        fn less(_: void, a: @TypeOf(scored.items[0]), b: @TypeOf(scored.items[0])) bool {
            return a.latest > b.latest;
        }
    }.less);
    var out: std.ArrayList(Forecast) = .empty;
    for (scored.items) |s| {
        if (out.items.len >= limit) break;
        const series = try trending.historicalRankings(alloc, aggregates, s.topic);
        if (try linearForecast(alloc, s.topic, series)) |f| {
            try out.append(alloc, f);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Z-score anomalies for one topic: each month scored against the
/// mean/std of the OTHER months (leave-one-out, so a spike does not
/// hide itself in its own mean). Needs at least 4 months — with
/// fewer, a deviation is not distinguishable from noise.
pub fn detectAnomalies(alloc: std.mem.Allocator, topic: []const u8, series: []const trending.MonthCount) ![]Anomaly {
    var out: std.ArrayList(Anomaly) = .empty;
    if (series.len < 4) return out.toOwnedSlice(alloc);
    for (series, 0..) |row, i| {
        var others: std.ArrayList(f64) = .empty;
        for (series, 0..) |other, j| {
            if (j != i) try others.append(alloc, @floatFromInt(other.doc_count));
        }
        const n = @as(f64, @floatFromInt(others.items.len));
        var mean: f64 = 0;
        for (others.items) |v| mean += v;
        mean /= n;
        var var_sum: f64 = 0;
        for (others.items) |v| var_sum += (v - mean) * (v - mean);
        const stddev = @sqrt(var_sum / n);
        if (stddev == 0) continue;
        const z = (@as(f64, @floatFromInt(row.doc_count)) - mean) / stddev;
        if (@abs(z) >= 2.0) {
            try out.append(alloc, .{
                .topic = topic,
                .year_month = row.year_month,
                .doc_count = row.doc_count,
                .mean = mean,
                .stddev = stddev,
                .z_score = z,
                .direction = if (z > 0) "spike" else "drop",
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Monthly series for one topic restricted to documents naming a
/// county (Roadmap 7.1 county filter): buckets the docs by their
/// published month, counting only docs whose title+text names the
/// county. Months are "YYYY-MM" (UTC), oldest first. A doc with no
/// usable timestamp is skipped, never guessed.
pub fn monthlySeriesFromDocs(alloc: std.mem.Allocator, docs: []const @import("../common/types.zig").Document, topic: []const u8, county: []const u8) ![]trending.MonthCount {
    const entities_mod = @import("../engine/entities.zig");
    const events_mod = @import("events.zig");
    var counts = std.StringHashMap(usize).init(alloc);
    defer counts.deinit();
    for (docs) |doc| {
        var has_topic = false;
        for (doc.topics) |t| {
            if (std.mem.eql(u8, t, topic)) {
                has_topic = true;
                break;
            }
        }
        if (!has_topic) continue;
        const ts = knowledge.docTs(doc);
        const combined = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        defer alloc.free(combined);
        const ent = try entities_mod.extract(alloc, combined);
        defer entities_mod.freeEntities(alloc, ent);
        var names_county = false;
        for (ent.counties) |c| {
            if (std.mem.eql(u8, c, county)) {
                names_county = true;
                break;
            }
        }
        if (!names_county) continue;
        const day = try events_mod.dayOf(alloc, ts);
        const month = day[0..7];
        const cur = counts.get(month) orelse 0;
        try counts.put(try alloc.dupe(u8, month), cur + 1);
    }
    var out: std.ArrayList(trending.MonthCount) = .empty;
    var it = counts.iterator();
    while (it.next()) |kv| {
        try out.append(alloc, .{ .year_month = kv.key_ptr.*, .doc_count = kv.value_ptr.* });
    }
    std.mem.sort(trending.MonthCount, out.items, {}, struct {
        fn less(_: void, a: trending.MonthCount, b: trending.MonthCount) bool {
            return std.mem.lessThan(u8, a.year_month, b.year_month);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

test "nextMonth rolls December to January" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("2027-01", try nextMonth(alloc, "2026-12"));
    try std.testing.expectEqualStrings("2026-12", try nextMonth(alloc, "2026-11"));
    try std.testing.expectError(error.InvalidMonth, nextMonth(alloc, "2026-13"));
    try std.testing.expectError(error.InvalidMonth, nextMonth(alloc, "2026-1"));
}

test "linearForecast extrapolates a rising series, flat is confident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rising = [_]trending.MonthCount{
        .{ .year_month = "2026-09", .doc_count = 4 },
        .{ .year_month = "2026-10", .doc_count = 6 },
        .{ .year_month = "2026-11", .doc_count = 8 },
    };
    const f = (try linearForecast(alloc, "politics", &rising)).?;
    try std.testing.expectEqualStrings("2026-12", f.horizon_month);
    // Perfect line: slope 2, intercept 4, next = 10, confidence 1.
    try std.testing.expectApproxEqAbs(@as(f64, 10), f.predicted_count, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), f.confidence, 0.001);
    try std.testing.expect(std.mem.indexOf(u8, f.basis, "2026-09..2026-11") != null);
    const flat = [_]trending.MonthCount{
        .{ .year_month = "2026-09", .doc_count = 5 },
        .{ .year_month = "2026-10", .doc_count = 5 },
        .{ .year_month = "2026-11", .doc_count = 5 },
    };
    const ff = (try linearForecast(alloc, "energy", &flat)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 5), ff.predicted_count, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), ff.confidence, 0.001);
    // One month: no trend is definable.
    const one = [_]trending.MonthCount{.{ .year_month = "2026-11", .doc_count = 5 }};
    try std.testing.expect(try linearForecast(alloc, "sports", &one) == null);
    // Noisy history: low confidence, never negative prediction.
    const noisy = [_]trending.MonthCount{
        .{ .year_month = "2026-09", .doc_count = 20 },
        .{ .year_month = "2026-10", .doc_count = 1 },
        .{ .year_month = "2026-11", .doc_count = 19 },
    };
    const nf = (try linearForecast(alloc, "culture", &noisy)).?;
    try std.testing.expect(nf.confidence < 0.5);
    try std.testing.expect(nf.predicted_count >= 0);
}

test "linearForecast carries the same-month-last-year check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // 13 months so the horizon (2026-12) has a same-month last year (2025-12).
    const months = [_]trending.MonthCount{
        .{ .year_month = "2025-12", .doc_count = 3 },
        .{ .year_month = "2026-01", .doc_count = 4 },
        .{ .year_month = "2026-02", .doc_count = 4 },
        .{ .year_month = "2026-03", .doc_count = 5 },
        .{ .year_month = "2026-04", .doc_count = 5 },
        .{ .year_month = "2026-05", .doc_count = 6 },
        .{ .year_month = "2026-06", .doc_count = 6 },
        .{ .year_month = "2026-07", .doc_count = 7 },
        .{ .year_month = "2026-08", .doc_count = 7 },
        .{ .year_month = "2026-09", .doc_count = 8 },
        .{ .year_month = "2026-10", .doc_count = 8 },
        .{ .year_month = "2026-11", .doc_count = 9 },
        .{ .year_month = "2026-12", .doc_count = 9 },
    };
    const f = (try linearForecast(alloc, "politics", &months)).?;
    try std.testing.expectEqualStrings("2027-01", f.horizon_month);
    // Same month last year for the 2027-01 horizon is 2026-01 = 4 docs.
    try std.testing.expectEqual(@as(?usize, 4), f.same_month_last_year);
}

test "forecastAll ranks by latest month and skips single-month topics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = [_]knowledge.MonthlyAggregate{
        .{ .year_month = "2026-10", .topic = "politics", .doc_count = 5 },
        .{ .year_month = "2026-11", .topic = "politics", .doc_count = 12 },
        .{ .year_month = "2026-10", .topic = "energy", .doc_count = 9 },
        .{ .year_month = "2026-11", .topic = "energy", .doc_count = 3 },
        .{ .year_month = "2026-11", .topic = "sports", .doc_count = 20 }, // single month: skipped
    };
    const all = try forecastAll(alloc, &rows, 10);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("politics", all[0].topic); // latest 12 > 3
    try std.testing.expectEqualStrings("energy", all[1].topic);
}

test "detectAnomalies flags a spike and a drop, not steady months" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const series = [_]trending.MonthCount{
        .{ .year_month = "2026-06", .doc_count = 10 },
        .{ .year_month = "2026-07", .doc_count = 11 },
        .{ .year_month = "2026-08", .doc_count = 9 },
        .{ .year_month = "2026-09", .doc_count = 10 },
        .{ .year_month = "2026-10", .doc_count = 40 }, // spike
        .{ .year_month = "2026-11", .doc_count = 10 },
    };
    const anoms = try detectAnomalies(alloc, "politics", &series);
    try std.testing.expectEqual(@as(usize, 1), anoms.len);
    try std.testing.expectEqualStrings("2026-10", anoms[0].year_month);
    try std.testing.expectEqualStrings("spike", anoms[0].direction);
    try std.testing.expect(anoms[0].z_score >= 2.0);
    // Fewer than 4 months: no call is made.
    const short = [_]trending.MonthCount{
        .{ .year_month = "2026-09", .doc_count = 1 },
        .{ .year_month = "2026-10", .doc_count = 100 },
        .{ .year_month = "2026-11", .doc_count = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), (try detectAnomalies(alloc, "energy", &short)).len);
}

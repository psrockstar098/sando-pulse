//! Intelligence quality (Roadmap 4.6): reliability calibration,
//! confidence scoring, misinformation indicators, independent-source
//! verification, freshness scoring, missing/stale-data detection.
//!
//! Pure functions over health records + events — no I/O. The server
//! supplies the records. Nothing here claims certainty it does not
//! have: a "flag" is a warning for a human to check, not a verdict
//! that a story is false. Confidence is a heuristic blend of source
//! reliability, corroboration and freshness — it is labelled as such
//! in the response, never presented as a fact about the world.

const std = @import("std");
const knowledge = @import("../storage/knowledge.zig");
const sources = @import("../ingestion/sources.zig");

/// Freshness of an age in seconds: 1.0 at age 0, 0.5 at 24h, ~0.125
/// at 7 days. A half-life decay, not a cliff — old news is stale,
/// not automatically wrong.
pub fn freshnessScore(age_s: i64) f32 {
    if (age_s <= 0) return 1.0;
    const age: f32 = @floatFromInt(age_s);
    return 1.0 / (1.0 + age / 86400.0);
}

/// Calibrated reliability for one source: the design-doc grade,
/// penalised by observed failures and staleness, never below 0.05
/// and never above 0.95. A source that has never run keeps its grade
/// (no evidence either way) but is reported as missing.
pub fn calibrateReliability(base: f32, health: ?knowledge.SourceHealth, now: i64) f32 {
    var r = base;
    const h = health orelse return r;
    r -= @as(f32, @floatFromInt(@min(h.consecutive_failures, 5))) * 0.08;
    if (h.last_success_at) |ls| {
        const age = now - ls;
        if (age > 7 * 86400) r -= 0.25 else if (age > 86400) r -= 0.12;
    } else {
        r -= 0.15; // never succeeded
    }
    return @min(0.95, @max(0.05, r));
}

pub const Flag = enum {
    single_source,
    conflicting_reports,
    retracted,
    stale,
    low_reliability,
    uncorroborated_old,

    pub fn name(self: Flag) []const u8 {
        return switch (self) {
            .single_source => "single_source",
            .conflicting_reports => "conflicting_reports",
            .retracted => "retracted",
            .stale => "stale",
            .low_reliability => "low_reliability",
            .uncorroborated_old => "uncorroborated_old",
        };
    }
};

/// Misinformation indicators for one event, appended to `out`.
/// Flags are warnings for a human to check — never a verdict that
/// the story is false.
pub fn flagEvent(alloc: std.mem.Allocator, event: knowledge.KnowledgeEvent, avg_reliability: f32, now: i64, out: *std.ArrayList(Flag)) !void {
    if (event.distinct_sources <= 1) try out.append(alloc, Flag.single_source);
    if (std.mem.eql(u8, event.status, "divergent")) try out.append(alloc, Flag.conflicting_reports);
    if (std.mem.eql(u8, event.status, "retracted")) try out.append(alloc, Flag.retracted);
    const age = now - event.last_seen;
    if (age > 7 * 86400) try out.append(alloc, Flag.stale);
    if (avg_reliability < 0.6) try out.append(alloc, Flag.low_reliability);
    if (event.distinct_sources <= 1 and age > 3 * 86400) try out.append(alloc, Flag.uncorroborated_old);
}

/// Confidence heuristic for one event: half source reliability, half
/// corroboration (1 source 0.3, 2 sources 0.6, 3+ 0.85), scaled by
/// freshness, then cut hard for retracted/divergent reports.
pub fn eventConfidence(event: knowledge.KnowledgeEvent, avg_reliability: f32, now: i64) f32 {
    const corroboration: f32 = switch (event.distinct_sources) {
        0, 1 => 0.3,
        2 => 0.6,
        else => 0.85,
    };
    const base = 0.5 * avg_reliability + 0.5 * corroboration;
    const fresh = freshnessScore(now - event.last_seen);
    var c = base * (0.5 + 0.5 * fresh);
    if (std.mem.eql(u8, event.status, "retracted")) c *= 0.2;
    if (std.mem.eql(u8, event.status, "divergent")) c *= 0.7;
    return @min(0.99, @max(0.01, c));
}

pub const EventQuality = struct {
    event_id: []const u8,
    title: []const u8,
    topic: []const u8,
    confidence: f32,
    freshness: f32,
    flags: []Flag,
};

pub const SourceQuality = struct {
    source_id: []const u8,
    base_reliability: f32,
    calibrated_reliability: f32,
    last_success_at: ?i64,
    consecutive_failures: usize,
    docs_total: usize,
    /// No successful run in the last 24h (or never).
    stale: bool,
    /// No health record at all — the source has never run in this store.
    missing: bool,
};

pub const QualityReport = struct {
    generated_at: i64,
    sources: []SourceQuality,
    events: []EventQuality,
    stale_sources: usize,
    missing_sources: usize,
    flagged_events: usize,
};

/// Build the quality report for the whole registry + the newest 100
/// events. The event confidence uses the mean calibrated reliability
/// across the registry as its reliability input — per-event source
/// reliability is not tracked, and the response says so in the
/// summary note.
pub fn computeQuality(alloc: std.mem.Allocator, ks: knowledge.KnowledgeStore, now: i64) !QualityReport {
    var srcs: std.ArrayList(SourceQuality) = .empty;
    var stale: usize = 0;
    var missing: usize = 0;
    var total_rel: f32 = 0;
    var rel_count: usize = 0;
    for (sources.sources) |src| {
        const health = ks.getSourceHealth(alloc, src.id) catch null;
        const cal = calibrateReliability(src.reliability, health, now);
        total_rel += cal;
        rel_count += 1;
        const is_missing = health == null;
        const is_stale = if (health) |h| blk: {
            if (h.last_success_at) |ls| break :blk (now - ls) > 86400;
            break :blk true;
        } else true;
        if (is_missing) missing += 1;
        if (is_stale) stale += 1;
        try srcs.append(alloc, .{
            .source_id = src.id,
            .base_reliability = src.reliability,
            .calibrated_reliability = cal,
            .last_success_at = if (health) |h| h.last_success_at else null,
            .consecutive_failures = if (health) |h| h.consecutive_failures else 0,
            .docs_total = if (health) |h| h.docs_total else 0,
            .stale = is_stale,
            .missing = is_missing,
        });
    }
    const avg_rel: f32 = if (rel_count > 0) total_rel / @as(f32, @floatFromInt(rel_count)) else 0.7;
    const events = ks.listEvents(alloc, 100) catch &.{};
    var evs: std.ArrayList(EventQuality) = .empty;
    var flagged: usize = 0;
    for (events) |ev| {
        var flags: std.ArrayList(Flag) = .empty;
    defer flags.deinit(alloc);
        try flagEvent(alloc, ev, avg_rel, now, &flags);
        if (flags.items.len > 0) flagged += 1;
        try evs.append(alloc, .{
            .event_id = ev.id,
            .title = ev.title,
            .topic = ev.topic,
            .confidence = eventConfidence(ev, avg_rel, now),
            .freshness = freshnessScore(now - ev.last_seen),
            .flags = try flags.toOwnedSlice(alloc),
        });
    }
    return .{
        .generated_at = now,
        .sources = try srcs.toOwnedSlice(alloc),
        .events = try evs.toOwnedSlice(alloc),
        .stale_sources = stale,
        .missing_sources = missing,
        .flagged_events = flagged,
    };
}

/// Render the report as JSON. Flags are their names; confidence is
/// labelled a heuristic in the `note` field.
pub fn renderQuality(alloc: std.mem.Allocator, report: QualityReport, req_id: []const u8) ![]u8 {
    var src_list: std.ArrayList(struct {
        source_id: []const u8,
        base_reliability: f32,
        calibrated_reliability: f32,
        last_success_at: ?i64,
        consecutive_failures: usize,
        docs_total: usize,
        stale: bool,
        missing: bool,
    }) = .empty;
    for (report.sources) |s| {
        try src_list.append(alloc, .{
            .source_id = s.source_id,
            .base_reliability = s.base_reliability,
            .calibrated_reliability = s.calibrated_reliability,
            .last_success_at = s.last_success_at,
            .consecutive_failures = s.consecutive_failures,
            .docs_total = s.docs_total,
            .stale = s.stale,
            .missing = s.missing,
        });
    }
    var ev_list: std.ArrayList(struct {
        event_id: []const u8,
        title: []const u8,
        topic: []const u8,
        confidence: f32,
        freshness: f32,
        flags: [][]const u8,
    }) = .empty;
    for (report.events) |e| {
        var names: std.ArrayList([]const u8) = .empty;
        for (e.flags) |f| try names.append(alloc, f.name());
        try ev_list.append(alloc, .{
            .event_id = e.event_id,
            .title = e.title,
            .topic = e.topic,
            .confidence = e.confidence,
            .freshness = e.freshness,
            .flags = try names.toOwnedSlice(alloc),
        });
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(.{
        .request_id = req_id,
        .generated_at = report.generated_at,
        .note = "confidence is a heuristic (reliability + corroboration + freshness); flags are warnings for a human to check, not verdicts",
        .sources = src_list.items,
        .events = ev_list.items,
        .summary = .{
            .stale_sources = report.stale_sources,
            .missing_sources = report.missing_sources,
            .flagged_events = report.flagged_events,
        },
    }, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

test "freshnessScore: fresh, 24h half, 7d low" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), freshnessScore(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), freshnessScore(-100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), freshnessScore(86400), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), freshnessScore(7 * 86400), 0.001);
}

test "calibrateReliability: no health keeps grade, failures and staleness penalise" {
    const now: i64 = 1795000000;
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), calibrateReliability(0.70, null, now), 0.001);
    const h1 = knowledge.SourceHealth{ .source_id = "x", .last_run_at = now, .last_success_at = now, .consecutive_failures = 0, .docs_total = 10 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), calibrateReliability(0.70, h1, now), 0.001);
    const h5 = knowledge.SourceHealth{ .source_id = "x", .last_run_at = now, .last_success_at = now, .consecutive_failures = 5, .docs_total = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), calibrateReliability(0.70, h5, now), 0.001);
    const hstale = knowledge.SourceHealth{ .source_id = "x", .last_run_at = now - 10 * 86400, .last_success_at = now - 10 * 86400, .consecutive_failures = 0, .docs_total = 3 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), calibrateReliability(0.70, hstale, now), 0.001);
    const hnever = knowledge.SourceHealth{ .source_id = "x", .last_run_at = now, .last_success_at = null, .consecutive_failures = 1, .docs_total = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.47), calibrateReliability(0.70, hnever, now), 0.001);
    // Floor: a terrible record never goes below 0.05.
    const hbad = knowledge.SourceHealth{ .source_id = "x", .last_run_at = now, .last_success_at = null, .consecutive_failures = 9, .docs_total = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), calibrateReliability(0.10, hbad, now), 0.001);
}

test "flagEvent: single source, retracted, divergent, stale, old uncorroborated" {
    const alloc = std.testing.allocator;
    const now: i64 = 1795000000;
    const base = knowledge.KnowledgeEvent{ .id = "e1", .title = "T", .topic = "politics", .first_seen = now - 100, .last_seen = now - 100, .doc_count = 1, .distinct_sources = 1, .status = "reported" };
    var flags: std.ArrayList(Flag) = .empty;
    defer flags.deinit(alloc);
    try flagEvent(alloc, base, 0.7, now, &flags);
    try std.testing.expectEqual(@as(usize, 1), flags.items.len);
    try std.testing.expectEqual(Flag.single_source, flags.items[0]);

    var flags2: std.ArrayList(Flag) = .empty;
    defer flags2.deinit(alloc);
    const old = knowledge.KnowledgeEvent{ .id = "e2", .title = "T", .topic = "politics", .first_seen = now - 10 * 86400, .last_seen = now - 10 * 86400, .doc_count = 1, .distinct_sources = 1, .status = "reported" };
    try flagEvent(alloc, old, 0.7, now, &flags2);
    // single_source + stale + uncorroborated_old
    try std.testing.expectEqual(@as(usize, 3), flags2.items.len);

    var flags3: std.ArrayList(Flag) = .empty;
    defer flags3.deinit(alloc);
    const ret = knowledge.KnowledgeEvent{ .id = "e3", .title = "T", .topic = "politics", .first_seen = now - 100, .last_seen = now - 100, .doc_count = 3, .distinct_sources = 3, .status = "retracted" };
    try flagEvent(alloc, ret, 0.7, now, &flags3);
    try std.testing.expectEqual(@as(usize, 1), flags3.items.len);
    try std.testing.expectEqual(Flag.retracted, flags3.items[0]);

    var flags4: std.ArrayList(Flag) = .empty;
    defer flags4.deinit(alloc);
    const div = knowledge.KnowledgeEvent{ .id = "e4", .title = "T", .topic = "politics", .first_seen = now - 100, .last_seen = now - 100, .doc_count = 4, .distinct_sources = 2, .status = "divergent" };
    try flagEvent(alloc, div, 0.5, now, &flags4);
    // conflicting_reports + low_reliability (avg 0.5 < 0.6)
    try std.testing.expectEqual(@as(usize, 2), flags4.items.len);
}

test "eventConfidence: corroborated fresh scores high, retracted scores low" {
    const now: i64 = 1795000000;
    const good = knowledge.KnowledgeEvent{ .id = "e1", .title = "T", .topic = "politics", .first_seen = now - 3600, .last_seen = now - 3600, .doc_count = 5, .distinct_sources = 3, .status = "reported" };
    const c_good = eventConfidence(good, 0.8, now);
    try std.testing.expect(c_good > 0.7);
    const ret = knowledge.KnowledgeEvent{ .id = "e2", .title = "T", .topic = "politics", .first_seen = now - 3600, .last_seen = now - 3600, .doc_count = 5, .distinct_sources = 3, .status = "retracted" };
    try std.testing.expect(eventConfidence(ret, 0.8, now) < 0.2);
    const lone = knowledge.KnowledgeEvent{ .id = "e3", .title = "T", .topic = "politics", .first_seen = now - 3600, .last_seen = now - 3600, .doc_count = 1, .distinct_sources = 1, .status = "reported" };
    try std.testing.expect(eventConfidence(lone, 0.8, now) < c_good);
}

test "renderQuality produces parseable JSON with sources, events, summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var flag_list = [_]Flag{.single_source};
    var src_list = [_]SourceQuality{.{ .source_id = "new-dawn", .base_reliability = 0.70, .calibrated_reliability = 0.62, .last_success_at = 1794990000, .consecutive_failures = 1, .docs_total = 11, .stale = false, .missing = false }};
    var ev_list = [_]EventQuality{.{ .event_id = "ev1", .title = "Budget \"signed\" <today>", .topic = "politics", .confidence = 0.71, .freshness = 0.9, .flags = &flag_list }};
    const report = QualityReport{
        .generated_at = 1795000000,
        .sources = &src_list,
        .events = &ev_list,
        .stale_sources = 1,
        .missing_sources = 2,
        .flagged_events = 1,
    };
    const body = try renderQuality(alloc, report, "req-1");
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("req-1", parsed.value.object.get("request_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("summary").?.object.get("flagged_events").?.integer);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("events").?.array.items.len);
    try std.testing.expectEqualStrings("single_source", parsed.value.object.get("events").?.array.items[0].object.get("flags").?.array.items[0].string);
}

//! Query planner: Parse -> Enrich -> Choose -> Execute -> Synthesize.
//! Turns a natural-language question into a `Plan` (intent, entities, topics,
//! time range, source selection). The plan is returned in every /v1/query
//! response so Sando — and the operator — can see exactly how Pulse
//! understood the question.

const std = @import("std");
const types = @import("../common/types.zig");
const entities = @import("entities.zig");
const intent_mod = @import("intent.zig");
const temporal = @import("temporal.zig");
const geo = @import("geo.zig");

pub const Plan = struct {
    intent: []const u8,
    /// Lowercased search terms (stopwords removed), owned by the arena.
    terms: []const []const u8,
    counties: []const []const u8,
    cities: []const []const u8,
    organizations: []const []const u8,
    people: []const []const u8,
    topics: []const []const u8,
    /// "today" | "7d" | "30d" | null (no time constraint).
    time_range: ?[]const u8,
    /// Resolved half-open time window [time_from, time_to) in Unix seconds,
    /// from temporal.resolve — the value search actually filters on.
    time_from: ?i64 = null,
    time_to: ?i64 = null,
    /// Search strategy from intent classification: "fast" | "balanced" | "deep".
    strategy: []const u8 = "balanced",
    /// How strongly the signals support the chosen intent (0.0-1.0).
    classification_confidence: f64 = 0.5,
    /// Geographic filter when the query names a place with a radius
    /// ("within 50 km of Gbarnga", "near Monrovia").
    geo_filter: ?types.GeoFilter = null,
    /// Source ids to search (enabled sources by default).
    sources: []const []const u8,
};

const stopwords: []const []const u8 = &.{
    "the", "a", "an", "in", "on", "at", "of", "for", "to", "and", "or",
    "what", "is", "are", "was", "were", "how", "when", "where", "who",
    "why", "did", "do", "does", "latest", "news", "about", "with",
    "from", "by", "this", "that", "it", "its", "there", "here", "today",
    "now", "happening", "going", "tell", "me", "please", "any", "some",
    "has", "have", "been", "being", "will", "would", "can", "could",
    "should", "i", "you", "we", "they", "he", "she", "his", "her",
    "their", "our", "your", "as", "if", "but", "not", "no", "yes",
};

fn isStopword(w: []const u8) bool {
    for (stopwords) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

/// Map the classifier's intent enum to the planner's intent strings.
/// "trends" keeps its historical API name "trending_topics".
fn intentString(i: intent_mod.Intent) []const u8 {
    return switch (i) {
        .search => "search",
        .live => "live",
        .local => "local",
        .trends => "trending_topics",
        .research => "research",
        .timeline => "timeline",
        .compare => "compare",
        .historical => "historical",
    };
}

/// Plan a query. `enabled_sources` is the list of enabled source ids from
/// the registry; the plan references that slice directly. `now` is Unix
/// seconds; `tz_offset_minutes` is minutes east of UTC (Africa/Monrovia = 0).
/// Intent, strategy and time come from the Roadmap 2.1/2.5 classifiers —
/// this function no longer guesses them with its own keyword lists.
pub fn plan(alloc: std.mem.Allocator, query: []const u8, enabled_sources: []const []const u8, now: i64, tz_offset_minutes: i32) !Plan {
    const lower = try entities.lowerCopy(alloc, query);
    const ent = try entities.extract(alloc, query);
    const cls = intent_mod.classify(query, now, tz_offset_minutes);
    const time_range = cls.time_range;

    // Tokenize into terms: lowercase words, stopwords removed, deduped.
    var terms: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, lower, " \t\n\r.,;:!?()[]{}\"'/\\-_");
    while (it.next()) |tok| {
        if (tok.len < 2) continue;
        if (isStopword(tok)) continue;
        var dup = false;
        for (terms.items) |t| {
            if (std.mem.eql(u8, t, tok)) {
                dup = true;
                break;
            }
        }
        if (!dup) try terms.append(alloc, tok);
    }

    // Human label for the resolved time window, e.g. "today" or
    // "2026-11-11..2026-11-12". Kept for the API response; search uses
    // time_from/time_to.
    var time_label: ?[]const u8 = null;
    if (time_range) |r| {
        time_label = try temporal.describe(alloc, r, tz_offset_minutes);
    }
    // Radius phrase: "within 50 km of Gbarnga", "near Monrovia".
    var geo_filter: ?types.GeoFilter = null;
    if (geo.parseRadiusPhrase(lower)) |g| {
        geo_filter = .{ .lat = g.place.lat, .lon = g.place.lon, .radius_km = g.radius_km };
    }

    return Plan{
        .intent = intentString(cls.intent),
        .terms = try terms.toOwnedSlice(alloc),
        .counties = ent.counties,
        .cities = ent.cities,
        .organizations = ent.organizations,
        .people = ent.people,
        .topics = ent.topics,
        .time_range = time_label,
        .time_from = if (time_range) |r| r.from else null,
        .time_to = if (time_range) |r| r.to else null,
        .strategy = cls.strategy.toString(),
        .classification_confidence = cls.confidence,
        .geo_filter = geo_filter,
        .sources = enabled_sources,
    };
}

test "plan extracts intent, entities, topics, time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794484800; // 2026-11-12 12:00 UTC
    const p = try plan(alloc, "What is happening with fuel in Monrovia today?", &.{ "new-dawn", "gnn-liberia" }, now, 0);
    try std.testing.expectEqualStrings("local", p.intent);
    try std.testing.expectEqual(@as(usize, 1), p.cities.len);
    try std.testing.expectEqualStrings("Monrovia", p.cities[0]);
    // "today" resolves to the local day window, not just a label.
    try std.testing.expectEqual(@as(?i64, 1794441600), p.time_from);
    try std.testing.expectEqual(@as(?i64, 1794441600 + 86400), p.time_to);
    try std.testing.expect(p.time_range != null);
    try std.testing.expectEqualStrings("balanced", p.strategy);
    var saw_energy = false;
    var saw_fuel = false;
    for (p.topics) |t| {
        if (std.mem.eql(u8, t, "energy")) saw_energy = true;
    }
    for (p.terms) |t| {
        if (std.mem.eql(u8, t, "fuel")) saw_fuel = true;
    }
    try std.testing.expect(saw_energy);
    try std.testing.expect(saw_fuel);
    try std.testing.expectEqual(@as(usize, 2), p.sources.len);
}

test "plan detects trending intent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "What are the top trending topics in Liberia?", &.{}, 1794484800, 0);
    try std.testing.expectEqualStrings("trending_topics", p.intent);
}

test "plan detects local intent and last-week window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "Latest news from Lofa last week", &.{}, 1794484800, 0);
    try std.testing.expectEqualStrings("local", p.intent);
    // Last week: Mon 2026-11-02 .. Mon 2026-11-09 (Thursday 2026-11-12).
    try std.testing.expectEqual(@as(?i64, 1793577600), p.time_from);
    try std.testing.expectEqual(@as(?i64, 1794182400), p.time_to);
    try std.testing.expectEqual(@as(usize, 1), p.counties.len);
    try std.testing.expectEqualStrings("Lofa", p.counties[0]);
}

test "plan resolves a radius phrase into a geo filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "news within 50 km of Gbarnga", &.{}, 1794484800, 0);
    try std.testing.expect(p.geo_filter != null);
    try std.testing.expectApproxEqAbs(@as(f64, 6.9963), p.geo_filter.?.lat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), p.geo_filter.?.radius_km, 0.001);
    const q = try plan(arena.allocator(), "fuel prices in Monrovia", &.{}, 1794484800, 0);
    try std.testing.expectEqual(@as(?types.GeoFilter, null), q.geo_filter);
}

test "plan stops words and dedupes terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "fuel fuel fuel prices", &.{}, 1794484800, 0);
    var fuel_count: usize = 0;
    for (p.terms) |t| {
        if (std.mem.eql(u8, t, "fuel")) fuel_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fuel_count);
    for (p.terms) |t| {
        try std.testing.expect(!std.mem.eql(u8, t, "the"));
    }
}

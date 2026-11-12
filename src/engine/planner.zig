//! Query planner: Parse -> Enrich -> Choose -> Execute -> Synthesize.
//! Turns a natural-language question into a `Plan` (intent, entities, topics,
//! time range, source selection). The plan is returned in every /v1/query
//! response so Sando — and the operator — can see exactly how Pulse
//! understood the question.

const std = @import("std");
const entities = @import("entities.zig");

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

fn containsWordLower(text_lower: []const u8, needle: []const u8) bool {
    return entities.containsWord(text_lower, needle);
}

fn detectIntent(lower: []const u8, ent: entities.Entities) []const u8 {
    if (containsWordLower(lower, "trend") or containsWordLower(lower, "trending") or
        containsWordLower(lower, "top") or containsWordLower(lower, "most discussed") or
        containsWordLower(lower, "geez"))
    {
        return "trending_topics";
    }
    if (containsWordLower(lower, "deep") or containsWordLower(lower, "report") or
        containsWordLower(lower, "analysis") or containsWordLower(lower, "history") or
        containsWordLower(lower, "research"))
    {
        return "research";
    }
    if (ent.counties.len > 0 or ent.cities.len > 0) return "local";
    if (containsWordLower(lower, "today") or containsWordLower(lower, "now") or
        containsWordLower(lower, "latest") or containsWordLower(lower, "breaking") or
        containsWordLower(lower, "happening"))
    {
        return "live";
    }
    return "search";
}

fn detectTimeRange(lower: []const u8) ?[]const u8 {
    if (containsWordLower(lower, "today") or containsWordLower(lower, "now")) return "today";
    if (containsWordLower(lower, "last week") or containsWordLower(lower, "this week")) return "7d";
    if (containsWordLower(lower, "last month") or containsWordLower(lower, "this month")) return "30d";
    if (containsWordLower(lower, "yesterday")) return "today";
    return null;
}

/// Plan a query. `enabled_sources` is the list of enabled source ids from
/// the registry; the plan references that slice directly.
pub fn plan(alloc: std.mem.Allocator, query: []const u8, enabled_sources: []const []const u8) !Plan {
    const lower = try entities.lowerCopy(alloc, query);
    const ent = try entities.extract(alloc, query);

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

    return Plan{
        .intent = detectIntent(lower, ent),
        .terms = try terms.toOwnedSlice(alloc),
        .counties = ent.counties,
        .cities = ent.cities,
        .organizations = ent.organizations,
        .people = ent.people,
        .topics = ent.topics,
        .time_range = detectTimeRange(lower),
        .sources = enabled_sources,
    };
}

test "plan extracts intent, entities, topics, time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try plan(alloc, "What is happening with fuel in Monrovia today?", &.{ "new-dawn", "gnn-liberia" });
    try std.testing.expectEqualStrings("local", p.intent);
    try std.testing.expectEqual(@as(usize, 1), p.cities.len);
    try std.testing.expectEqualStrings("Monrovia", p.cities[0]);
    try std.testing.expectEqualStrings("today", p.time_range.?);
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
    const p = try plan(arena.allocator(), "What are the top trending topics in Liberia?", &.{});
    try std.testing.expectEqualStrings("trending_topics", p.intent);
}

test "plan detects live intent and 7d range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "Latest news from Lofa last week", &.{});
    try std.testing.expectEqualStrings("local", p.intent);
    try std.testing.expectEqualStrings("7d", p.time_range.?);
    try std.testing.expectEqual(@as(usize, 1), p.counties.len);
    try std.testing.expectEqualStrings("Lofa", p.counties[0]);
}

test "plan stops words and dedupes terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), "fuel fuel fuel prices", &.{});
    var fuel_count: usize = 0;
    for (p.terms) |t| {
        if (std.mem.eql(u8, t, "fuel")) fuel_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fuel_count);
    for (p.terms) |t| {
        try std.testing.expect(!std.mem.eql(u8, t, "the"));
    }
}

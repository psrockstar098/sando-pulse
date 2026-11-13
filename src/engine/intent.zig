//! Query intent detection and search-strategy selection (Roadmap 2.1).
//! A query is classified into an intent (what the user wants) and a
//! strategy (how deep the engine should dig). Keyword scoring only — no
//! model calls here; the classification interface in ai/providers.zig can
//! replace this with a model later.

const std = @import("std");
const entities = @import("entities.zig");
const temporal = @import("temporal.zig");

pub const Intent = enum {
    search,
    live,
    local,
    trends,
    research,
    timeline,
    compare,
    historical,
    /// A count/stat question answerable from the knowledge store
    /// (Roadmap 7.2): "how many schools...", "population of...".
    stat,

    pub fn toString(self: Intent) []const u8 {
        return switch (self) {
            .search => "search",
            .live => "live",
            .local => "local",
            .trends => "trends",
            .research => "research",
            .timeline => "timeline",
            .compare => "compare",
            .historical => "historical",
            .stat => "stat",
        };
    }

    pub fn fromString(s: []const u8) ?Intent {
        if (std.mem.eql(u8, s, "search")) return .search;
        if (std.mem.eql(u8, s, "live")) return .live;
        if (std.mem.eql(u8, s, "local")) return .local;
        if (std.mem.eql(u8, s, "trends")) return .trends;
        if (std.mem.eql(u8, s, "research")) return .research;
        if (std.mem.eql(u8, s, "timeline")) return .timeline;
        if (std.mem.eql(u8, s, "compare")) return .compare;
        if (std.mem.eql(u8, s, "historical")) return .historical;
        if (std.mem.eql(u8, s, "stat")) return .stat;
        return null;
    }
};

pub const Strategy = enum {
    fast,
    balanced,
    deep,

    pub fn toString(self: Strategy) []const u8 {
        return switch (self) {
            .fast => "fast",
            .balanced => "balanced",
            .deep => "deep",
        };
    }

    pub fn fromString(s: []const u8) ?Strategy {
        if (std.mem.eql(u8, s, "fast")) return .fast;
        if (std.mem.eql(u8, s, "balanced")) return .balanced;
        if (std.mem.eql(u8, s, "deep")) return .deep;
        return null;
    }
};

pub const Classification = struct {
    intent: Intent,
    strategy: Strategy,
    /// 0.0-1.0; how strongly the signals support the chosen intent.
    confidence: f64,
    /// The time range implied by the query, if any.
    time_range: ?temporal.TimeRange = null,
};

fn countPhrase(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        n += 1;
        start += idx + needle.len;
    }
    return n;
}

fn scorePhrases(haystack: []const u8, needles: []const []const u8) usize {
    var total: usize = 0;
    for (needles) |n| total += countPhrase(haystack, n);
    return total;
}

const live_words = [_][]const u8{ "breaking", "latest", "just now", "right now", "happening now", "update", "today", "this morning", "tonight" };
const timeline_words = [_][]const u8{ "timeline", "history of", "over time", "chronology", "when did", "how did it start", "evolution of" };
const trends_words = [_][]const u8{ "trending", "trend", "popular", "most talked", "viral", "everyone is talking" };
const research_words = [_][]const u8{ "analysis", "deep dive", "research", "background on", "explain", "why did", "what caused", "investigat" };
const compare_words = [_][]const u8{ "compare", "versus", " vs ", "difference between", "before and after", "then and now" };
const historical_words = [_][]const u8{ "last year", "in 20", "history", "years ago", "decade", "in the past" };
const deep_words = [_][]const u8{ "comprehensive", "in depth", "in-depth", "thorough", "all about", "everything about" };
const fast_words = [_][]const u8{ "quick", "brief", "short answer", "just tell me" };
/// Stat questions (Roadmap 7.2): a count or a population. Scored
/// x4 so the stat intent beats the local intent a place name
/// would otherwise trigger ("How many schools are in Montserrado
/// County?" scores local 3 — county +2, the word "county" +1 — so
/// one stat phrase must outscore that).
const stat_words = [_][]const u8{ "how many", "population of", "number of" };

/// Classify a natural-language query. `now` is Unix seconds; the timezone
/// offset is minutes east of UTC. No allocation.
pub fn classify(query: []const u8, now: i64, tz_offset_minutes: i32) Classification {
    var lower_buf: [512]u8 = undefined;
    const s = if (query.len <= lower_buf.len)
        std.ascii.lowerString(lower_buf[0..query.len], query)
    else
        query;

    const time_range = temporal.resolve(s, now, tz_offset_minutes);

    var live_score = scorePhrases(s, &live_words);
    const timeline_score = scorePhrases(s, &timeline_words);
    const trends_score = scorePhrases(s, &trends_words);
    const research_score = scorePhrases(s, &research_words);
    const compare_score = scorePhrases(s, &compare_words);
    var historical_score = scorePhrases(s, &historical_words);
    const stat_score = scorePhrases(s, &stat_words) * 4;

    // A known Liberian place name in the query strongly suggests local intent.
    // Location names are stored capitalized; lowercase them to match the
    // lowercased query.
    var local_score: usize = 0;
    for (entities.counties) |name| {
        var name_buf: [64]u8 = undefined;
        if (name.len > name_buf.len) continue;
        const lname = std.ascii.lowerString(name_buf[0..name.len], name);
        if (countPhrase(s, lname) > 0) local_score += 2;
    }
    for (entities.cities) |name| {
        var name_buf: [64]u8 = undefined;
        if (name.len > name_buf.len) continue;
        const lname = std.ascii.lowerString(name_buf[0..name.len], name);
        if (countPhrase(s, lname) > 0) local_score += 2;
    }
    if (countPhrase(s, "liberia") > 0) local_score += 1;
    if (countPhrase(s, "county") > 0) local_score += 1;
    if (countPhrase(s, "monrovia") > 0) local_score += 1;

    // Time expressions push toward live (today/yesterday) or historical.
    if (time_range) |r| {
        const today = temporal.dayStart(now, tz_offset_minutes);
        if (r.to > today and r.from >= today - temporal.seconds_per_day) {
            live_score += 1;
        } else if (r.to <= today - temporal.seconds_per_day) {
            historical_score += 1;
        }
    }

    // Pick the highest-scoring intent; ties resolve in a fixed priority order.
    var intent: Intent = .search;
    var best: usize = 0;
    const candidates = [_]struct { intent: Intent, score: usize }{
        .{ .intent = .stat, .score = stat_score },
        .{ .intent = .live, .score = live_score },
        .{ .intent = .timeline, .score = timeline_score },
        .{ .intent = .trends, .score = trends_score },
        .{ .intent = .research, .score = research_score },
        .{ .intent = .compare, .score = compare_score },
        .{ .intent = .historical, .score = historical_score },
        .{ .intent = .local, .score = local_score },
    };
    for (candidates) |c| {
        if (c.score > best) {
            best = c.score;
            intent = c.intent;
        }
    }

    // Strategy: deep for research/compare/timeline or explicit depth words;
    // fast for live or explicit brevity words; balanced otherwise.
    var strategy: Strategy = .balanced;
    if (intent == .research or intent == .compare or intent == .timeline) {
        strategy = .deep;
    } else if (intent == .live) {
        strategy = .fast;
    }
    if (scorePhrases(s, &deep_words) > 0) strategy = .deep;
    if (scorePhrases(s, &fast_words) > 0 and strategy != .deep) strategy = .fast;

    const confidence: f64 = if (best == 0) 0.5 else @min(0.95, 0.55 + 0.1 * @as(f64, @floatFromInt(best)));

    return .{ .intent = intent, .strategy = strategy, .confidence = confidence, .time_range = time_range };
}

test "intent: basic classification" {
    const now: i64 = 1794484800;
    const live = classify("latest news today", now, 0);
    try std.testing.expectEqual(Intent.live, live.intent);
    try std.testing.expectEqual(Strategy.fast, live.strategy);
    try std.testing.expect(live.time_range != null);

    const tl = classify("timeline of the fuel shortage", now, 0);
    try std.testing.expectEqual(Intent.timeline, tl.intent);
    try std.testing.expectEqual(Strategy.deep, tl.strategy);

    const local = classify("what is happening in Nimba county", now, 0);
    try std.testing.expectEqual(Intent.local, local.intent);

    const cmp = classify("compare fuel prices before and after the shortage", now, 0);
    try std.testing.expectEqual(Intent.compare, cmp.intent);

    const res = classify("deep dive analysis of the budget", now, 0);
    try std.testing.expectEqual(Intent.research, res.intent);
    try std.testing.expectEqual(Strategy.deep, res.strategy);

    const tr = classify("what is trending in Liberia", now, 0);
    try std.testing.expectEqual(Intent.trends, tr.intent);

    const hist = classify("what happened in 2024", now, 0);
    try std.testing.expectEqual(Intent.historical, hist.intent);
    try std.testing.expect(hist.time_range != null);

    const plain = classify("fuel prices", now, 0);
    try std.testing.expectEqual(Intent.search, plain.intent);
    try std.testing.expectEqual(Strategy.balanced, plain.strategy);
    try std.testing.expect(plain.time_range == null);
}

test "intent: strategy words" {
    const now: i64 = 1794484800;
    const quick = classify("quick summary of the election", now, 0);
    try std.testing.expectEqual(Strategy.fast, quick.strategy);
    const deep = classify("comprehensive report on mining", now, 0);
    try std.testing.expectEqual(Strategy.deep, deep.strategy);
}

test "intent: stat questions beat the local intent" {
    const now: i64 = 1794484800;
    const q1 = classify("How many schools are in Montserrado County?", now, 0);
    try std.testing.expectEqual(Intent.stat, q1.intent);
    const q2 = classify("What is the population of Nimba?", now, 0);
    try std.testing.expectEqual(Intent.stat, q2.intent);
    // "How many people attended the rally" names no facility or
    // population phrase, so it is NOT a stat question — but the
    // intent classifier only sees the "how many" phrase and still
    // tags it .stat. That is fine: the strict gate is
    // statanswer.detectStatQuestion (facility word or population
    // required), which rejects it and the query falls through to
    // the normal search. A query with no stat phrase at all
    // classifies local, not stat.
    const q3 = classify("Who attended the rally in Monrovia?", now, 0);
    try std.testing.expect(q3.intent != .stat);
}

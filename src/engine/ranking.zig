//! Ranking and confidence, per the design doc.
//!
//! Score = 0.35*relevance + 0.22*reliability + 0.18*recency + 0.15*context + 0.10*coverage
//! Confidence = 0.40*agreement + 0.30*consensus + 0.30*freshness
//!
//! A document is only usable as evidence when its score clears
//! `min_evidence_score` (0.25). Below that, Pulse says it does not know.

const std = @import("std");
const types = @import("../common/types.zig");
const entities = @import("entities.zig");

pub const min_evidence_score: f32 = 0.25;

fn termHits(text_lower: []const u8, term: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + term.len <= text_lower.len) : (i += 1) {
        if (std.mem.eql(u8, text_lower[i .. i + term.len], term)) {
            n += 1;
            i += term.len - 1;
        }
    }
    return n;
}

fn countMatchedTerms(alloc: std.mem.Allocator, text: []const u8, terms: []const []const u8) !usize {
    const lower = try entities.lowerCopy(alloc, text);
    var matched: usize = 0;
    for (terms) |t| {
        if (termHits(lower, t) > 0) matched += 1;
    }
    return matched;
}

/// Recency from a unix timestamp: 1.0 when fresh, ~0.5 at 7 days, ~0.19 at 30.
/// `now` is unix seconds; a missing timestamp scores neutral (0.5).
pub fn recencyScore(published_at: ?i64, now: i64) f32 {
    const ts = published_at orelse return 0.5;
    const age_days = @as(f32, @floatFromInt(@max(0, now - ts))) / 86400.0;
    return 1.0 / (1.0 + age_days / 7.0);
}

pub const ScoreParts = struct {
    relevance: f32,
    reliability: f32,
    recency: f32,
    context: f32,
    coverage: f32,
    total: f32,
};

/// Score one document against a planned query.
/// `terms` are the planner's lowercased terms. All component scores are 0..1.
pub fn scoreDocument(
    alloc: std.mem.Allocator,
    doc: types.Document,
    terms: []const []const u8,
    counties: []const []const u8,
    organizations: []const []const u8,
    topics: []const []const u8,
    now: i64,
) !ScoreParts {
    // Relevance: title hits count double, text hits single; normalized by the
    // maximum achievable (every term twice in the title + once in the text).
    var relevance: f32 = 0;
    var coverage: f32 = 0;
    if (terms.len > 0) {
        const title_lower = try entities.lowerCopy(alloc, doc.title);
        const text_lower = try entities.lowerCopy(alloc, doc.text);
        var title_hits: usize = 0;
        var text_hits: usize = 0;
        var matched_terms: usize = 0;
        for (terms) |t| {
            const th = termHits(title_lower, t);
            const xh = termHits(text_lower, t);
            if (th > 0 or xh > 0) matched_terms += 1;
            title_hits += @min(th, 2);
            text_hits += @min(xh, 2);
        }
        const max_points = @as(f32, @floatFromInt(terms.len)) * 4.0; // 2 title + 2 text per term
        const points = @as(f32, @floatFromInt(title_hits * 2 + text_hits));
        relevance = @min(1.0, points / max_points);
        coverage = @as(f32, @floatFromInt(matched_terms)) / @as(f32, @floatFromInt(terms.len));
    }

    const reliability = doc.reliability;
    const recency = recencyScore(doc.published_at, now);

    // Context: fraction of the query's counties/orgs/topics present in the doc.
    var context: f32 = 0.5; // neutral when the query names no entities
    const entity_total = counties.len + organizations.len + topics.len;
    if (entity_total > 0) {
        var matched: usize = 0;
        const hay = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        const hay_lower = try entities.lowerCopy(alloc, hay);
        for (counties) |c| {
            const cl = try entities.lowerCopy(alloc, c);
            if (entities.containsWord(hay_lower, cl)) matched += 1;
        }
        for (organizations) |o| {
            const ol = try entities.lowerCopy(alloc, o);
            if (entities.containsWord(hay_lower, ol)) matched += 1;
        }
        for (topics) |t| {
            for (doc.topics) |dt| {
                if (std.mem.eql(u8, dt, t)) {
                    matched += 1;
                    break;
                }
            }
        }
        context = @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(entity_total));
    }

    // Relevance gate: a document with zero query-term overlap carries no
    // evidence for this query, however fresh or reliable its source is.
    // Without it, recency + reliability alone (0.18 + 0.22*0.7 = 0.334)
    // would push a totally unrelated document over the evidence threshold.
    const total = if (relevance == 0)
        0
    else
        0.35 * relevance + 0.22 * reliability + 0.18 * recency + 0.15 * context + 0.10 * coverage;
    return .{
        .relevance = relevance,
        .reliability = reliability,
        .recency = recency,
        .context = context,
        .coverage = coverage,
        .total = total,
    };
}

pub const ConfidenceParts = struct {
    agreement: f32,
    consensus: f32,
    freshness: f32,
    total: f32,
};

/// Confidence over a ranked result set (top docs already sorted by score).
/// - agreement: share of top docs sharing at least one topic with the query
///   (1.0 when the query names no topics — nothing to disagree with).
/// - consensus: distinct sources among results / 3, clamped to 1.
/// - freshness: mean recency of the top docs.
pub fn confidence(top_docs: []const types.Document, query_topics: []const []const u8, now: i64) f32 {
    if (top_docs.len == 0) return 0;
    var agreeing: usize = 0;
    var recency_sum: f32 = 0;
    var distinct: [8][]const u8 = undefined;
    var distinct_n: usize = 0;
    for (top_docs) |d| {
        recency_sum += recencyScore(d.published_at, now);
        var is_new = true;
        for (distinct[0..distinct_n]) |s| {
            if (std.mem.eql(u8, s, d.source_id)) {
                is_new = false;
                break;
            }
        }
        if (is_new and distinct_n < distinct.len) {
            distinct[distinct_n] = d.source_id;
            distinct_n += 1;
        }
        if (query_topics.len == 0) {
            agreeing += 1;
        } else {
            for (query_topics) |qt| {
                var hit = false;
                for (d.topics) |dt| {
                    if (std.mem.eql(u8, dt, qt)) {
                        hit = true;
                        break;
                    }
                }
                if (hit) {
                    agreeing += 1;
                    break;
                }
            }
        }
    }
    const agreement = @as(f32, @floatFromInt(agreeing)) / @as(f32, @floatFromInt(top_docs.len));
    const consensus = @min(1.0, @as(f32, @floatFromInt(distinct_n)) / 3.0);
    const freshness = recency_sum / @as(f32, @floatFromInt(top_docs.len));
    return 0.40 * agreement + 0.30 * consensus + 0.30 * freshness;
}

test "recencyScore decays with age" {
    const now: i64 = 1_800_000_000;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), recencyScore(now, now), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), recencyScore(now - 7 * 86400, now), 0.01);
    try std.testing.expect(recencyScore(now - 30 * 86400, now) < 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), recencyScore(null, now), 0.001);
}

test "scoreDocument ranks a matching doc above an unrelated one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1_800_000_000;
    const good = types.Document{
        .id = "a",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues as the fuel shortage continues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{ "energy", "economy" },
        .content_hash = "a",
    };
    const bad = types.Document{
        .id = "b",
        .source_id = "gnn-liberia",
        .source_name = "GNN Liberia",
        .source_url = "https://gnnliberia.com/",
        .title = "Local football league resumes",
        .url = "https://example.com/2",
        .text = "The football season opened with a match in Ganta.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{"sports"},
        .content_hash = "b",
    };
    const terms: []const []const u8 = &.{ "fuel", "shortage", "monrovia" };
    const gs = try scoreDocument(alloc, good, terms, &.{}, &.{}, &.{ "energy", "economy" }, now);
    const bs = try scoreDocument(alloc, bad, terms, &.{}, &.{}, &.{ "energy", "economy" }, now);
    try std.testing.expect(gs.total > bs.total);
    try std.testing.expect(gs.total > min_evidence_score);
    try std.testing.expect(bs.total < min_evidence_score);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), gs.coverage, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bs.coverage, 0.001);
}

test "confidence rewards multi-source agreement" {
    const now: i64 = 1_800_000_000;
    var docs: [3]types.Document = undefined;
    const ids = [_][]const u8{ "a", "b", "c" };
    const srcs = [_][]const u8{ "new-dawn", "gnn-liberia", "the-news" };
    for (0..3) |i| {
        docs[i] = .{
            .id = ids[i],
            .source_id = srcs[i],
            .source_name = srcs[i],
            .source_url = "https://example.com/",
            .title = "Fuel in Monrovia",
            .url = "https://example.com/x",
            .text = "Fuel.",
            .published_at = now - 3600,
            .fetched_at = now,
            .reliability = 0.70,
            .topics = &.{"energy"},
            .content_hash = ids[i],
        };
    }
    const c3 = confidence(&docs, &.{"energy"}, now);
    const c1 = confidence(docs[0..1], &.{"energy"}, now);
    try std.testing.expect(c3 > c1);
    try std.testing.expect(c3 > 0.7);
}

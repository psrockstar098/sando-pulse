//! Three-path query router (Roadmap 6.1/6.7).
//!
//! Every /v1/query is served on exactly one path:
//!
//! - `instant` — the answer already exists: an L1 cache hit. No store
//!   access at all. (Precomputed answers — trends, briefing — are served
//!   by their own endpoints today; routing a *query* to a precomputed
//!   payload is a future step, recorded in STATUS.md, because the
//!   payload shape differs from the query response.)
//! - `fast` — the indexed path: the in-memory index shortlists
//!   candidates (bounded, newest-first), resolved via getDocument, then
//!   the standard ranking. Falls back to the store search when the
//!   index returns too few candidates.
//! - `deep` — the full path: store search over the whole candidate set
//!   (no index shortlist), semantic scoring when an embedder is
//!   configured, fuzzy second pass when thin. Used for research,
//!   comparison, and historical intents, and for queries with no
//!   lexical terms (embedding-only).
//!
//! Routing is pure and fast: it reads only the plan and a few flags,
//! never the store. The response carries `path`, the measured
//! server-side `latency_ms`, and `routing_reason` on every query.

const std = @import("std");
const planner = @import("planner.zig");

pub const Path = enum {
    instant,
    fast,
    deep,

    pub fn name(self: Path) []const u8 {
        return switch (self) {
            .instant => "instant",
            .fast => "fast",
            .deep => "deep",
        };
    }
};

pub const Decision = struct {
    path: Path,
    reason: []const u8,
};

pub const RouteContext = struct {
    /// The L1 cache already holds this exact query.
    l1_hit: bool = false,
};

/// Route a planned query. Pure function of the plan + flags.
pub fn route(p: planner.Plan, ctx: RouteContext) Decision {
    if (ctx.l1_hit) return .{ .path = .instant, .reason = "l1_hit" };
    // Deep intents need the whole candidate set + semantic/correlation
    // work; the index shortlist would cut evidence they depend on.
    if (std.mem.eql(u8, p.intent, "research") or
        std.mem.eql(u8, p.intent, "compare") or
        std.mem.eql(u8, p.intent, "historical"))
    {
        return .{ .path = .deep, .reason = "intent_deep" };
    }
    if (std.mem.eql(u8, p.strategy, "deep")) {
        return .{ .path = .deep, .reason = "strategy_deep" };
    }
    // No lexical terms: only an embedding can answer. That is deep by
    // definition (semantic search over the store).
    if (p.terms.len == 0) {
        return .{ .path = .deep, .reason = "semantic_only" };
    }
    if (p.geo_filter != null) {
        return .{ .path = .fast, .reason = "geo_indexed" };
    }
    if (p.terms.len <= 2 and p.classification_confidence >= 0.7) {
        return .{ .path = .fast, .reason = "simple_indexed" };
    }
    return .{ .path = .fast, .reason = "default_fast" };
}

fn testPlan(intent: []const u8, strategy: []const u8, terms: []const []const u8, confidence: f64) planner.Plan {
    return .{
        .intent = intent,
        .terms = terms,
        .counties = &.{},
        .cities = &.{},
        .organizations = &.{},
        .people = &.{},
        .topics = &.{},
        .time_range = null,
        .strategy = strategy,
        .classification_confidence = confidence,
        .sources = &.{},
    };
}

test "router: l1 hit is always instant" {
    const p = testPlan("local", "balanced", &.{"fuel"}, 0.9);
    const d = route(p, .{ .l1_hit = true });
    try std.testing.expectEqual(Path.instant, d.path);
    try std.testing.expectEqualStrings("l1_hit", d.reason);
}

test "router: research/compare/historical intents are deep" {
    for ([_][]const u8{ "research", "compare", "historical" }) |intent| {
        const p = testPlan(intent, "balanced", &.{"fuel"}, 0.9);
        const d = route(p, .{});
        try std.testing.expectEqual(Path.deep, d.path);
        try std.testing.expectEqualStrings("intent_deep", d.reason);
    }
}

test "router: deep strategy is deep even for a search intent" {
    const p = testPlan("search", "deep", &.{"fuel"}, 0.9);
    try std.testing.expectEqual(Path.deep, route(p, .{}).path);
}

test "router: no terms means semantic-only deep" {
    const p = testPlan("search", "balanced", &.{}, 0.5);
    const d = route(p, .{});
    try std.testing.expectEqual(Path.deep, d.path);
    try std.testing.expectEqualStrings("semantic_only", d.reason);
}

test "router: short confident queries are fast, simple_indexed" {
    const p = testPlan("local", "fast", &.{"fuel"}, 0.85);
    const d = route(p, .{});
    try std.testing.expectEqual(Path.fast, d.path);
    try std.testing.expectEqualStrings("simple_indexed", d.reason);
}

test "router: default is fast" {
    const p = testPlan("local", "balanced", &.{ "fuel", "shortage", "monrovia", "prices" }, 0.5);
    const d = route(p, .{});
    try std.testing.expectEqual(Path.fast, d.path);
    try std.testing.expectEqualStrings("default_fast", d.reason);
}

test "router: path names are the API strings" {
    try std.testing.expectEqualStrings("instant", Path.instant.name());
    try std.testing.expectEqualStrings("fast", Path.fast.name());
    try std.testing.expectEqualStrings("deep", Path.deep.name());
}

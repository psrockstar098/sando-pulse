//! JSON request parsing and response building for the REST API.
//! All responses carry a request_id; all errors use one envelope shape.

const std = @import("std");
const format = @import("../common/format.zig");
const knowledge = @import("../storage/knowledge.zig");
const planner = @import("../engine/planner.zig");
const search = @import("../engine/search.zig");
const temporal = @import("../engine/temporal.zig");
const unified = @import("../search/unified.zig");

pub const QueryRequest = struct {
    query: []const u8,
    limit: usize = 10,
};

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Parse the body into a std.json.Value whose strings are owned by the
/// caller's arena (no Parsed wrapper: parseFromSlice would free the strings
/// on deinit, leaving the returned slices dangling — that bug shipped once
/// and produced garbage query text in responses).
fn parseJsonValue(alloc: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return error.InvalidRequest;
}

/// Parse a POST /v1/query body: {"query": "...", "options": {"limit": N}}.
/// The query must be a non-empty string of at most 1000 chars.
pub fn parseQueryRequest(alloc: std.mem.Allocator, body: []const u8) !QueryRequest {
    const parsed = try parseJsonValue(alloc, body);
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    const q = getString(obj, "query") orelse return error.InvalidRequest;
    const trimmed = std.mem.trim(u8, q, " \t\n\r");
    if (trimmed.len == 0 or trimmed.len > 1000) return error.InvalidRequest;
    var limit: usize = 10;
    if (obj.get("options")) |opts| {
        if (opts == .object) {
            if (opts.object.get("limit")) |lv| {
                if (lv == .integer) {
                    if (lv.integer < 1 or lv.integer > 20) return error.InvalidRequest;
                    limit = @intCast(lv.integer);
                } else return error.InvalidRequest;
            }
        } else return error.InvalidRequest;
    }
    return .{ .query = trimmed, .limit = limit };
}

/// Format unix seconds as ISO 8601 UTC ("2026-11-12T10:00:00Z").
pub fn formatIso(alloc: std.mem.Allocator, unix: i64) ![]u8 {
    const days = @divFloor(unix, 86400);
    const secs = @mod(unix, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const hh = @divFloor(secs, 3600);
    const mm = @divFloor(@mod(secs, 3600), 60);
    const ss = @mod(secs, 60);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, m, 2);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, d, 2);
    try w.writeAll("T");
    try format.writeZeroPadded(&w, hh, 2);
    try w.writeByte(':');
    try format.writeZeroPadded(&w, mm, 2);
    try w.writeByte(':');
    try format.writeZeroPadded(&w, ss, 2);
    try w.writeByte('Z');
    return alloc.dupe(u8, w.buffered());
}

fn truncateSummary(alloc: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    if (text.len <= max_len) return alloc.dupe(u8, text);
    const cut = text[0..max_len];
    const last_space = std.mem.lastIndexOfScalar(u8, cut, ' ') orelse max_len;
    return std.fmt.allocPrint(alloc, "{s}...", .{cut[0..last_space]});
}

fn stringifyAlloc(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

const ResultJson = struct {
    title: []const u8,
    summary: []const u8,
    url: []const u8,
    source: struct {
        name: []const u8,
        url: []const u8,
    },
    /// "local" for RSS documents, "social" for Facebook posts
    /// (source_id "facebook:<page_id>") — one list, labelled.
    kind: []const u8,
    published_at: ?[]const u8,
    score: f64,
    /// Fused score (what the ranking actually used) + the keyword base
    /// parts, so callers can see why a document ranked where it did.
    score_parts: struct {
        relevance: f64,
        reliability: f64,
        recency: f64,
        context: f64,
        coverage: f64,
    },
    fuzzy_score: ?f64 = null,
    semantic_score: ?f64 = null,
};

const PlanJson = struct {
    intent: []const u8,
    topics: []const []const u8,
    counties: []const []const u8,
    organizations: []const []const u8,
    time_range: ?[]const u8,
    time_from: ?[]const u8 = null,
    time_to: ?[]const u8 = null,
    strategy: []const u8,
    classification_confidence: f64,
    sources: []const []const u8,
};

const EventJson = struct {
    id: []const u8,
    title: []const u8,
    topic: []const u8,
    first_seen: []const u8,
    last_seen: []const u8,
    doc_count: usize,
};

const TimelineDayJson = struct {
    day: []const u8,
    doc_count: usize,
    event_titles: []const []const u8,
};

/// Fan-out enrichment attached to a query response (Roadmap 6.6):
/// knowledge-store locations and statistics that match the query's
/// places/topics, fetched concurrently with the news search.
/// `fanout_complete` is false when a backend was still running when the
/// deadline passed — its section is then empty (partial results,
/// labelled, never silently stale).
/// `stat_answer` (Roadmap 7.2) is set when the query is a count/stat
/// question answered (or honestly refused) from the knowledge store.
pub const Enrichment = struct {
    locations: []const knowledge.LocationRow = &.{},
    statistics: []const knowledge.StatisticRow = &.{},
    fanout_complete: bool = true,
    stat_answer: ?statanswer.StatAnswer = null,
};

pub fn buildQueryResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    query: []const u8,
    p: planner.Plan,
    outcome: search.Outcome,
    sources_checked: usize,
    now: i64,
    /// Execution path that served this response (Roadmap 6.1):
    /// "instant" | "fast" | "deep".
    path: []const u8,
    /// Measured server-side latency in milliseconds (fractional).
    latency_ms: f64,
    /// Why the router chose this path.
    routing_reason: []const u8,
    enrich: Enrichment,
    /// How many results to render (Roadmap 6.12): the API's
    /// options.limit. Was a hardcoded 10, which made options.limit
    /// a no-op — every response carried 10 results regardless.
    limit: usize,
    /// Unified search (web + social fan-out): the web results
    /// (already deduplicated against the local results by the
    /// server) and the per-source statuses. Empty when the query
    /// did not fan out (stat answers, cache warming of a
    /// local-only path) — the section still renders, honestly.
    unified_in: unified.Unified,
) ![]u8 {
    var results: std.ArrayList(ResultJson) = .empty;
    const shown = @min(outcome.results.len, limit);
    var social_count: usize = 0;
    for (outcome.results[0..shown]) |r| {
        if (unified.isSocialSource(r.doc.source_id)) social_count += 1;
        try results.append(alloc, .{
            .title = r.doc.title,
            .summary = try truncateSummary(alloc, r.doc.text, 280),
            .url = r.doc.url,
            .source = .{ .name = r.doc.source_name, .url = r.doc.source_url },
            .kind = if (unified.isSocialSource(r.doc.source_id)) "social" else "local",
            .published_at = if (r.doc.published_at) |ts| try formatIso(alloc, ts) else null,
            .score = r.fused,
            .score_parts = .{
                .relevance = r.score.relevance,
                .reliability = r.score.reliability,
                .recency = r.score.recency,
                .context = r.score.context,
                .coverage = r.score.coverage,
            },
            .fuzzy_score = r.fuzzy_score,
            .semantic_score = r.semantic_score,
        });
    }
    var events: std.ArrayList(EventJson) = .empty;
    for (outcome.events) |e| {
        try events.append(alloc, .{
            .id = e.id,
            .title = e.title,
            .topic = e.topic,
            .first_seen = try formatIso(alloc, e.first_seen),
            .last_seen = try formatIso(alloc, e.last_seen),
            .doc_count = e.doc_count,
        });
    }
    var timeline: std.ArrayList(TimelineDayJson) = .empty;
    for (outcome.timeline) |d| {
        const day_label = try temporal.describe(alloc, .{ .from = d.day_start, .to = d.day_start + 86400 }, 0);
        try timeline.append(alloc, .{
            .day = day_label,
            .doc_count = d.doc_count,
            .event_titles = d.event_titles,
        });
    }
    // Unified web section: SearXNG results in SearXNG's order,
    // already deduplicated against the local results by the server.
    // Each cites its engine as the source — no score is invented.
    var web_items: std.ArrayList(struct {
        title: []const u8,
        summary: []const u8,
        url: []const u8,
        engine: []const u8,
        source: struct {
            name: []const u8,
            url: []const u8,
        },
    }) = .empty;
    for (unified_in.web) |w| {
        try web_items.append(alloc, .{
            .title = w.title,
            .summary = try truncateSummary(alloc, w.content, 280),
            .url = w.url,
            .engine = w.engine,
            .source = .{ .name = w.engine, .url = w.url },
        });
    }
    const resp = .{
        .query = query,
        .answer = outcome.answer,
        .sufficient = outcome.sufficient,
        .insufficient_reason = outcome.insufficient_reason,
        .confidence = outcome.confidence,
        .path = path,
        .latency_ms = latency_ms,
        .routing_reason = routing_reason,
        .locations = enrich.locations,
        .statistics = enrich.statistics,
        .fanout_complete = enrich.fanout_complete,
        .stat_answer = enrich.stat_answer,
        .results = results.items,
        .unified = .{
            .web = web_items.items,
            .web_complete = unified_in.web_complete,
            .sources = [_]struct {
                name: []const u8,
                status: []const u8,
                results: usize,
                detail: ?[]const u8,
            }{
                .{ .name = "local", .status = "ok", .results = shown, .detail = null },
                .{ .name = "web", .status = unified.webStatusName(unified_in.web_status), .results = unified_in.web.len, .detail = unified_in.web_detail },
                .{ .name = "facebook", .status = if (unified_in.facebook_configured) "configured" else "not_configured", .results = social_count, .detail = if (unified_in.facebook_configured) null else "Facebook is not configured — set PULSE_FACEBOOK_ACCESS_TOKEN" },
            },
        },
        .events = events.items,
        .timeline = timeline.items,
        .query_plan = PlanJson{
            .intent = p.intent,
            .topics = p.topics,
            .counties = p.counties,
            .organizations = p.organizations,
            .time_range = p.time_range,
            .time_from = if (p.time_from) |ts| try formatIso(alloc, ts) else null,
            .time_to = if (p.time_to) |ts| try formatIso(alloc, ts) else null,
            .strategy = p.strategy,
            .classification_confidence = p.classification_confidence,
            .sources = p.sources,
        },
        .meta = .{
            .request_id = req_id,
            .results_count = shown,
            .sources_checked = sources_checked,
            .generated_at = try formatIso(alloc, now),
        },
    };
    return stringifyAlloc(alloc, resp);
}

pub fn buildErrorResponse(alloc: std.mem.Allocator, req_id: []const u8, code: []const u8, message: []const u8) ![]u8 {
    return stringifyAlloc(alloc, .{
        .@"error" = .{ .code = code, .message = message },
        .request_id = req_id,
    });
}

pub fn buildHealthResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    doc_count: usize,
    sources_enabled: usize,
    store_name: []const u8,
    country: []const u8,
) ![]u8 {
    return stringifyAlloc(alloc, .{
        .status = "ok",
        .version = "0.1.0",
        .api_version = "1",
        .country = country,
        .documents = doc_count,
        .sources_enabled = sources_enabled,
        .store = store_name,
        .request_id = req_id,
    });
}

const statanswer = @import("../intelligence/statanswer.zig");

test "buildQueryResponse carries path, latency_ms and routing_reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p: planner.Plan = .{
        .intent = "local",
        .terms = &.{"fuel"},
        .counties = &.{},
        .cities = &.{},
        .organizations = &.{},
        .people = &.{},
        .topics = &.{},
        .time_range = null,
        .sources = &.{},
    };
    const outcome: search.Outcome = .{
        .answer = null,
        .results = &.{},
        .confidence = 0,
        .sufficient = false,
        .insufficient_reason = "no_documents_matched",
        .events = &.{},
        .timeline = &.{},
    };
    // The live shape: real path + measured latency.
    const live = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 12.345678, "simple_indexed", .{}, 10, .{});
    try std.testing.expect(std.mem.indexOf(u8, live, "\"path\":\"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "\"latency_ms\":12.345678") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "\"routing_reason\":\"simple_indexed\"") != null);
    // The storable shape: empty markers stampServed expects.
    const stored = try buildQueryResponse(alloc, "", "fuel", p, outcome, 5, 1794477600, "", 0, "", .{}, 10, .{});
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"path\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"latency_ms\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"routing_reason\":\"\"") != null);
    const cache = @import("cache.zig");
    const stamped = try cache.stampServed(alloc, stored, "req-9", "instant", 0.5, "l1_hit");
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"request_id\":\"req-9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"path\":\"instant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"routing_reason\":\"l1_hit\"") != null);
}

test "formatIso renders UTC dates" {
    const s = try formatIso(std.testing.allocator, 1794477600);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2026-11-12T10:00:00Z", s);
    const s2 = try formatIso(std.testing.allocator, 0);
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s2);
}

test "parseQueryRequest validates input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ok = try parseQueryRequest(alloc, "{\"query\": \"fuel in Monrovia\", \"options\": {\"limit\": 5}}");
    try std.testing.expectEqualStrings("fuel in Monrovia", ok.query);
    try std.testing.expectEqual(@as(usize, 5), ok.limit);
    const def = try parseQueryRequest(alloc, "{\"query\": \"fuel\"}");
    try std.testing.expectEqual(@as(usize, 10), def.limit);
    try std.testing.expectError(error.InvalidRequest, parseQueryRequest(alloc, "{\"query\": \"\"}"));
    try std.testing.expectError(error.InvalidRequest, parseQueryRequest(alloc, "{\"query\": 42}"));
    try std.testing.expectError(error.InvalidRequest, parseQueryRequest(alloc, "{\"query\": \"fuel\", \"options\": {\"limit\": 0}}"));
    try std.testing.expectError(error.InvalidRequest, parseQueryRequest(alloc, "not json"));
    try std.testing.expectError(error.InvalidRequest, parseQueryRequest(alloc, "{}"));
}

test "buildErrorResponse shape" {
    const s = try buildErrorResponse(std.testing.allocator, "req-1", "not_found", "No such route");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"code\":\"not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"request_id\":\"req-1\"") != null);
}

test "buildQueryResponse renders exactly options.limit results" {
    // Regression test (Roadmap 6.12): the limit was validated and
    // hashed into the cache key but the response always rendered 10.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p: planner.Plan = .{
        .intent = "local",
        .terms = &.{"fuel"},
        .counties = &.{},
        .cities = &.{},
        .organizations = &.{},
        .people = &.{},
        .topics = &.{},
        .time_range = null,
        .sources = &.{},
    };
    var ranked: [5]search.RankedDoc = undefined;
    for (&ranked, 0..) |*r, i| {
        r.* = .{
            .doc = .{
                .id = "d",
                .source_id = "new-dawn",
                .source_name = "New Dawn",
                .source_url = "https://thenewdawnliberia.com/",
                .title = "Fuel shortage hits Monrovia",
                .url = "https://example.com/x",
                .text = "Fuel stations report long queues.",
                .published_at = null,
                .fetched_at = 1000,
                .reliability = 0.7,
                .topics = &.{},
                .content_hash = "h",
                .lang = "en",
            },
            .score = .{ .relevance = 0.9, .reliability = 0.7, .recency = 0.5, .context = 0.5, .coverage = 0.5, .total = 0.8 },
            .fused = 0.8 - @as(f64, @floatFromInt(i)) * 0.01,
        };
    }
    const outcome: search.Outcome = .{
        .answer = "Fuel stations report long queues. [1]",
        .results = &ranked,
        .confidence = 0.8,
        .sufficient = true,
        .insufficient_reason = null,
        .events = &.{},
        .timeline = &.{},
    };
    const two = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 1.0, "simple_indexed", .{}, 2, .{});
    // Two result objects: count the "title" fields in the results array.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, two, "\"title\":"));
    const all = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 1.0, "simple_indexed", .{}, 20, .{});
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, all, "\"title\":"));
}

test "buildQueryResponse renders the unified web + social sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p: planner.Plan = .{
        .intent = "local",
        .terms = &.{"fuel"},
        .counties = &.{},
        .cities = &.{},
        .organizations = &.{},
        .people = &.{},
        .topics = &.{},
        .time_range = null,
        .sources = &.{},
    };
    var ranked: [2]search.RankedDoc = undefined;
    ranked[0] = .{
        .doc = .{
            .id = "d1",
            .source_id = "new-dawn",
            .source_name = "New Dawn",
            .source_url = "https://thenewdawnliberia.com/",
            .title = "Fuel shortage hits Monrovia",
            .url = "https://thenewdawnliberia.com/fuel",
            .text = "Fuel stations report long queues.",
            .published_at = null,
            .fetched_at = 1000,
            .reliability = 0.7,
            .topics = &.{},
            .content_hash = "h1",
            .lang = "en",
        },
        .score = .{ .relevance = 0.9, .reliability = 0.7, .recency = 0.5, .context = 0.5, .coverage = 0.5, .total = 0.8 },
        .fused = 0.8,
    };
    ranked[1] = .{
        .doc = .{
            .id = "d2",
            .source_id = "facebook:106003915444667",
            .source_name = "Chronic circle",
            .source_url = "https://www.facebook.com/chroniccircle",
            .title = "Fuel queue at Broad Street",
            .url = "https://www.facebook.com/chroniccircle/posts/1",
            .text = "Long queue at the Broad Street station today.",
            .published_at = null,
            .fetched_at = 1000,
            .reliability = 0.5,
            .topics = &.{},
            .content_hash = "h2",
            .lang = "en",
        },
        .score = .{ .relevance = 0.8, .reliability = 0.5, .recency = 0.6, .context = 0.5, .coverage = 0.5, .total = 0.7 },
        .fused = 0.7,
    };
    const outcome: search.Outcome = .{
        .answer = null,
        .results = &ranked,
        .confidence = 0.8,
        .sufficient = true,
        .insufficient_reason = null,
        .events = &.{},
        .timeline = &.{},
    };
    var web = [_]unified.WebResult{
        .{ .title = "Liberia fuel imports rise", .url = "https://example.com/fuel-imports", .content = "Imports rose in October.", .engine = "bing" },
    };
    const s = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 1.0, "simple_indexed", .{}, 10, .{
        .web = &web,
        .web_complete = true,
        .web_status = .ok,
        .facebook_configured = false,
    });
    // One list, labelled kinds: the RSS doc and the Facebook post.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"kind\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"kind\":\"social\"") != null);
    // Web result cited with its engine, in SearXNG's order.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"title\":\"Liberia fuel imports rise\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"engine\":\"bing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"web_complete\":true") != null);
    // Source statuses: local ok, web ok, facebook honestly unconfigured.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"local\",\"status\":\"ok\",\"results\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"web\",\"status\":\"ok\",\"results\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\":\"facebook\",\"status\":\"not_configured\",\"results\":1") != null);
}

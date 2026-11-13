//! JSON request parsing and response building for the REST API.
//! All responses carry a request_id; all errors use one envelope shape.

const std = @import("std");
const format = @import("../common/format.zig");
const types = @import("../common/types.zig");
const knowledge = @import("../storage/knowledge.zig");
const events_intel = @import("../intelligence/events.zig");
const planner = @import("../engine/planner.zig");
const search = @import("../engine/search.zig");
const temporal = @import("../engine/temporal.zig");
const sources = @import("../ingestion/sources.zig");

pub const QueryRequest = struct {
    query: []const u8,
    limit: usize = 10,
};

pub const IngestRequest = struct {
    title: []const u8,
    text: []const u8,
    url: []const u8,
    source_id: []const u8,
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

/// Parse a POST /v1/ingest body: {title, text, url, source_id}.
/// The source_id must name a registered source.
pub fn parseIngestRequest(alloc: std.mem.Allocator, body: []const u8) !IngestRequest {
    const parsed = try parseJsonValue(alloc, body);
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    const title = getString(obj, "title") orelse return error.InvalidRequest;
    const text = getString(obj, "text") orelse return error.InvalidRequest;
    const url = getString(obj, "url") orelse return error.InvalidRequest;
    const source_id = getString(obj, "source_id") orelse return error.InvalidRequest;
    if (title.len == 0 or title.len > 500) return error.InvalidRequest;
    if (text.len == 0 or text.len > 20000) return error.InvalidRequest;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return error.InvalidRequest;
    if (sources.find(source_id) == null) return error.InvalidRequest;
    return .{ .title = title, .text = text, .url = url, .source_id = source_id };
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

pub fn buildQueryResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    query: []const u8,
    p: planner.Plan,
    outcome: search.Outcome,
    sources_checked: usize,
    now: i64,
) ![]u8 {
    var results: std.ArrayList(ResultJson) = .empty;
    const shown = @min(outcome.results.len, 10);
    for (outcome.results[0..shown]) |r| {
        try results.append(alloc, .{
            .title = r.doc.title,
            .summary = try truncateSummary(alloc, r.doc.text, 280),
            .url = r.doc.url,
            .source = .{ .name = r.doc.source_name, .url = r.doc.source_url },
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
    const resp = .{
        .query = query,
        .answer = outcome.answer,
        .sufficient = outcome.sufficient,
        .insufficient_reason = outcome.insufficient_reason,
        .confidence = outcome.confidence,
        .results = results.items,
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

/// GET /v1/usage response (Roadmap 5.3): one UsageRow per consumer for
/// the given UTC day. `usage` is the upstream module to avoid a cycle
/// between the JSON builders and the tracker.
pub fn buildUsageResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    day: []const u8,
    rows: []const @import("usage.zig").UsageRow,
) ![]u8 {
    return stringifyAlloc(alloc, .{
        .day = day,
        .usage = rows,
        .request_id = req_id,
    });
}

pub fn buildSourcesResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    counts: []const types.SourceCount,
) ![]u8 {
    var list: std.ArrayList(struct {
        id: []const u8,
        name: []const u8,
        home_url: []const u8,
        feed_url: []const u8,
        reliability: f32,
        enabled: bool,
        disabled_reason: ?[]const u8,
        documents: usize,
    }) = .empty;
    for (sources.sources) |s| {
        var n: usize = 0;
        for (counts) |c| {
            if (std.mem.eql(u8, c.source_id, s.id)) {
                n = c.count;
                break;
            }
        }
        try list.append(alloc, .{
            .id = s.id,
            .name = s.name,
            .home_url = s.home_url,
            .feed_url = s.feed_url,
            .reliability = s.reliability,
            .enabled = s.enabled,
            .disabled_reason = s.disabled_reason,
            .documents = n,
        });
    }
    return stringifyAlloc(alloc, .{
        .sources = list.items,
        .request_id = req_id,
    });
}

/// GET /v1/events — persisted event clusters, newest first.
pub fn buildEventsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    events: []const knowledge.KnowledgeEvent,
    now: i64,
) ![]u8 {
    var list: std.ArrayList(struct {
        id: []const u8,
        title: []const u8,
        topic: []const u8,
        first_seen: []const u8,
        last_seen: []const u8,
        doc_count: usize,
        summary: ?[]const u8,
        distinct_sources: usize,
        status: []const u8,
        importance: f64,
    }) = .empty;
    for (events) |e| {
        try list.append(alloc, .{
            .id = e.id,
            .title = e.title,
            .topic = e.topic,
            .first_seen = try formatIso(alloc, e.first_seen),
            .last_seen = try formatIso(alloc, e.last_seen),
            .doc_count = e.doc_count,
            .summary = e.summary,
            .distinct_sources = e.distinct_sources,
            .status = e.status,
            .importance = events_intel.importanceScore(e.doc_count, e.distinct_sources, now - e.last_seen),
        });
    }
    return stringifyAlloc(alloc, .{
        .events = list.items,
        .request_id = req_id,
    });
}

/// One event in full (4.1): its documents, corroboration, status,
/// conflict report and day timeline. `docs` are newest-first.
pub fn buildEventDetailResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    event: knowledge.KnowledgeEvent,
    docs: []const knowledge.EventDoc,
    now: i64,
) ![]u8 {
    const status = try events_intel.eventStatus(alloc, docs);
    const conflicts = try events_intel.detectConflicts(alloc, docs);
    const timeline = try events_intel.timelineBuckets(alloc, docs);
    const corroboration = try events_intel.corroboration(alloc, docs);
    var doc_list: std.ArrayList(struct {
        id: []const u8,
        title: []const u8,
        source_id: []const u8,
        source_name: []const u8,
        published_at: []const u8,
    }) = .empty;
    for (docs) |d| {
        try doc_list.append(alloc, .{
            .id = d.id,
            .title = d.title,
            .source_id = d.source_id,
            .source_name = d.source_name,
            .published_at = try formatIso(alloc, d.published_at),
        });
    }
    var day_list: std.ArrayList(struct {
        day: []const u8,
        doc_count: usize,
    }) = .empty;
    for (timeline) |t| {
        try day_list.append(alloc, .{ .day = t.day, .doc_count = t.doc_count });
    }
    return stringifyAlloc(alloc, .{
        .event = .{
            .id = event.id,
            .title = event.title,
            .topic = event.topic,
            .first_seen = try formatIso(alloc, event.first_seen),
            .last_seen = try formatIso(alloc, event.last_seen),
            .doc_count = event.doc_count,
            .summary = event.summary,
            .distinct_sources = corroboration,
            .status = status,
            .importance = events_intel.importanceScore(event.doc_count, corroboration, now - event.last_seen),
        },
        .corroboration = corroboration,
        .status = status,
        .conflicts = .{
            .divergent = conflicts.divergent,
            .min_similarity = conflicts.min_similarity,
            .a_title = conflicts.a_title,
            .b_title = conflicts.b_title,
        },
        .timeline = day_list.items,
        .documents = doc_list.items,
        .request_id = req_id,
    });
}

const trending = @import("../intelligence/trending.zig");

/// GET /v1/trends — Geez and trending engine (Roadmap 4.2): ranked
/// topics with velocity, geographic trending, and monthly snapshots.
/// `snapshots` are the latest 3 months present in the aggregates.
pub fn buildTrendsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    trends: []const trending.TopicTrend,
    geo: []const trending.GeoTrend,
    snapshots: []const trending.MonthSnapshot,
) ![]u8 {
    var trend_list: std.ArrayList(struct {
        topic: []const u8,
        category: []const u8,
        recent_count: usize,
        prior_count: usize,
        velocity: f64,
        score: f64,
    }) = .empty;
    for (trends) |t| {
        try trend_list.append(alloc, .{
            .topic = t.topic,
            .category = t.category,
            .recent_count = t.recent_count,
            .prior_count = t.prior_count,
            .velocity = t.velocity,
            .score = t.score,
        });
    }
    var geo_list: std.ArrayList(struct {
        county: []const u8,
        doc_count: usize,
        top_topic: []const u8,
    }) = .empty;
    for (geo) |g| {
        try geo_list.append(alloc, .{
            .county = g.county,
            .doc_count = g.doc_count,
            .top_topic = g.top_topic,
        });
    }
    var snap_list: std.ArrayList(struct {
        year_month: []const u8,
        topics: []trending.TopicCount,
    }) = .empty;
    for (snapshots) |s| {
        try snap_list.append(alloc, .{ .year_month = s.year_month, .topics = s.topics });
    }
    return stringifyAlloc(alloc, .{
        .trends = trend_list.items,
        .geo = geo_list.items,
        .snapshots = snap_list.items,
        .request_id = req_id,
    });
}

/// GET /v1/locations — seeded + OSM reference places.
pub fn buildLocationsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    locations: []const knowledge.LocationRow,
) ![]u8 {
    var list: std.ArrayList(struct {
        name: []const u8,
        kind: []const u8,
        county: ?[]const u8,
        lat: ?f64,
        lon: ?f64,
        population: ?i64,
        source: []const u8,
        verified_at: ?[]const u8,
    }) = .empty;
    for (locations) |l| {
        try list.append(alloc, .{
            .name = l.name,
            .kind = l.kind,
            .county = l.county,
            .lat = l.lat,
            .lon = l.lon,
            .population = l.population,
            .source = l.source,
            .verified_at = l.verified_at,
        });
    }
    return stringifyAlloc(alloc, .{
        .locations = list.items,
        .request_id = req_id,
    });
}

/// GET /v1/statistics — seeded statistical datasets with provenance.
pub fn buildStatisticsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    stats: []const knowledge.StatisticRow,
) ![]u8 {
    var list: std.ArrayList(struct {
        key: []const u8,
        value: f64,
        unit: []const u8,
        period: []const u8,
        source: []const u8,
        verified_at: ?[]const u8,
    }) = .empty;
    for (stats) |s| {
        try list.append(alloc, .{
            .key = s.key,
            .value = s.value,
            .unit = s.unit,
            .period = s.period,
            .source = s.source,
            .verified_at = s.verified_at,
        });
    }
    return stringifyAlloc(alloc, .{
        .statistics = list.items,
        .request_id = req_id,
    });
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

test "parseIngestRequest validates input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ok = try parseIngestRequest(alloc,
        \\{"title": "T", "text": "Some text.", "url": "https://example.com/1", "source_id": "new-dawn"}
    );
    try std.testing.expectEqualStrings("new-dawn", ok.source_id);
    try std.testing.expectError(error.InvalidRequest, parseIngestRequest(alloc,
        \\{"title": "T", "text": "x", "url": "https://example.com/1", "source_id": "nope"}
    ));
    try std.testing.expectError(error.InvalidRequest, parseIngestRequest(alloc,
        \\{"title": "T", "text": "x", "url": "ftp://example.com/1", "source_id": "new-dawn"}
    ));
}

test "buildErrorResponse shape" {
    const s = try buildErrorResponse(std.testing.allocator, "req-1", "not_found", "No such route");
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"code\":\"not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"request_id\":\"req-1\"") != null);
}

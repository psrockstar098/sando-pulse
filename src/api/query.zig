//! JSON request parsing and response building for the REST API.
//! All responses carry a request_id; all errors use one envelope shape.

const std = @import("std");
const popular = @import("popular.zig");
const format = @import("../common/format.zig");
const types = @import("../common/types.zig");
const knowledge = @import("../storage/knowledge.zig");
const events_intel = @import("../intelligence/events.zig");
const planner = @import("../engine/planner.zig");
const search = @import("../engine/search.zig");
const temporal = @import("../engine/temporal.zig");
const sources = @import("../ingestion/sources.zig");
const trust_registry = @import("../intelligence/trust/source_registry.zig");
const trust_history = @import("../intelligence/trust/source_history.zig");
const trust_evidence = @import("../intelligence/trust/evidence_tracker.zig");
const trust_corroboration = @import("../intelligence/trust/corroboration.zig");
const trust_score = @import("../intelligence/trust/credibility_score.zig");
const monitor = @import("../intelligence/monitor/account_monitor.zig");

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
) ![]u8 {
    var results: std.ArrayList(ResultJson) = .empty;
    const shown = @min(outcome.results.len, limit);
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
        .path = path,
        .latency_ms = latency_ms,
        .routing_reason = routing_reason,
        .locations = enrich.locations,
        .statistics = enrich.statistics,
        .fanout_complete = enrich.fanout_complete,
        .stat_answer = enrich.stat_answer,
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

/// One source profile as JSON (Trust & Intelligence Engine, Phase 1).
/// `performance` is always null — not measured until Phase 4.
/// `posting_frequency` / `last_update` are null until the worker
/// tracks per-source freshness; `documents_total` IS live, from the
/// store's per-source counts.
const ProfileJson = struct {
    id: []const u8,
    name: []const u8,
    platform: []const u8,
    home_url: []const u8,
    feed_url: []const u8,
    county: []const u8,
    county_confidence: []const u8,
    county_note: []const u8,
    district: ?[]const u8,
    community: ?[]const u8,
    scope: []const u8,
    coverage: []const []const u8,
    reliability: f32,
    status: []const u8,
    disabled_reason: ?[]const u8,
    activity: struct {
        documents_total: usize,
        posting_frequency: ?[]const u8,
        last_update: ?[]const u8,
    },
    evidence: struct {
        documents_indexed: usize,
    },
    performance: ?[]const u8,
};

fn documentsFor(counts: []const types.SourceCount, id: []const u8) usize {
    for (counts) |c| {
        if (std.mem.eql(u8, c.source_id, id)) return c.count;
    }
    return 0;
}

fn profileJson(p: trust_registry.SourceProfile, documents: usize) ProfileJson {
    return .{
        .id = p.id,
        .name = p.name,
        .platform = p.platform,
        .home_url = p.home_url,
        .feed_url = p.feed_url,
        .county = p.county,
        .county_confidence = p.county_confidence,
        .county_note = p.county_note,
        .district = p.district,
        .community = p.community,
        .scope = p.scope,
        .coverage = p.coverage,
        .reliability = p.reliability,
        .status = p.status.name(),
        .disabled_reason = p.disabled_reason,
        .activity = .{ .documents_total = documents, .posting_frequency = null, .last_update = null },
        .evidence = .{ .documents_indexed = documents },
        .performance = null,
    };
}

/// GET /v1/sources/profiles — source profiles (Phase 1). The list is
/// already filtered by the handler (county / status); `counts` are
/// the live per-source document counts from the store.
pub fn buildSourceProfilesResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    profiles: []const trust_registry.SourceProfile,
    counts: []const types.SourceCount,
) ![]u8 {
    var list: std.ArrayList(ProfileJson) = .empty;
    for (profiles) |p| try list.append(alloc, profileJson(p, documentsFor(counts, p.id)));
    return stringifyAlloc(alloc, .{
        .profiles = list.items,
        .total = list.items.len,
        .reliability_note = "reliability is the registry's design-doc grade (news 0.70), not a computed credibility score — scoring is Phase 4.",
        .request_id = req_id,
    });
}

const HistoryJson = struct {
    seq: u64,
    action: []const u8,
    detail: []const u8,
    at: i64,
};

/// GET /v1/sources/profiles?id=<id> — one profile with its history.
pub fn buildSourceProfileResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    profile: trust_registry.SourceProfile,
    documents: usize,
    history: []const trust_history.HistoryEntry,
) ![]u8 {
    var hist: std.ArrayList(HistoryJson) = .empty;
    for (history) |h| try hist.append(alloc, .{ .seq = h.seq, .action = h.action, .detail = h.detail, .at = h.at });
    return stringifyAlloc(alloc, .{
        .profile = profileJson(profile, documents),
        .history = hist.items,
        .request_id = req_id,
    });
}

const CountyJson = struct {
    county: []const u8,
    capital: []const u8,
    sources: usize,
    note: []const u8,
};

/// GET /v1/counties — all 15 counties with source counts (Phase 1).
pub fn buildCountiesResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    counties: []const trust_registry.CountyCount,
) ![]u8 {
    var list: std.ArrayList(CountyJson) = .empty;
    var total: usize = 0;
    for (counties) |c| {
        total += c.sources;
        try list.append(alloc, .{ .county = c.county, .capital = c.capital, .sources = c.sources, .note = c.note });
    }
    return stringifyAlloc(alloc, .{
        .counties = list.items,
        .total_counties = list.items.len,
        .total_sources = total,
        .request_id = req_id,
    });
}

/// Facebook connector state inside the monitor response (Phase 2).
/// Null when no connector is configured on the server at all.
pub const FacebookMonitorJson = struct {
    available: bool,
    reason: ?[]const u8,
    registered_pages: usize,
    pending_pages: usize,
    pages_polled_total: usize,
    pages_failed_total: usize,
    notifications_pending: usize,
};

const MonitorStatusJson = struct {
    source_id: []const u8,
    name: []const u8,
    channel: []const u8,
    enabled: bool,
    last_checked_at: ?[]const u8,
    last_success_at: ?[]const u8,
    last_new_at: ?[]const u8,
    consecutive_failures: usize,
    documents_total: usize,
    last_error: ?[]const u8,
    freshness: []const u8,
    change_detection: []const u8,
    latest_doc: ?struct {
        title: []const u8,
        url: []const u8,
        fetched_at: []const u8,
    },
    note: []const u8,
};

fn isoOrNull(alloc: std.mem.Allocator, ts: ?i64) !?[]u8 {
    const t = ts orelse return null;
    return try formatIso(alloc, t);
}

/// GET /v1/monitor — live account monitoring (Trust & Intelligence
/// Engine, Phase 2). One status per registry source plus the
/// Facebook connector state. `freshness` is fresh/stale/unknown per
/// the 2x-ingest-interval rule; `last_new_at` moves only when a run
/// inserts a document. Timestamps are ISO strings, null when the
/// event has never happened.
pub fn buildMonitorResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    statuses: []const monitor.MonitorStatus,
    facebook: ?FacebookMonitorJson,
    interval_s: i64,
) ![]u8 {
    var list: std.ArrayList(MonitorStatusJson) = .empty;
    var fresh: usize = 0;
    var stale: usize = 0;
    var unknown: usize = 0;
    for (statuses) |s| {
        switch (s.freshness) {
            .fresh => fresh += 1,
            .stale => stale += 1,
            .unknown => unknown += 1,
        }
        try list.append(alloc, .{
            .source_id = s.source_id,
            .name = s.name,
            .channel = s.channel,
            .enabled = s.enabled,
            .last_checked_at = try isoOrNull(alloc, s.last_checked_at),
            .last_success_at = try isoOrNull(alloc, s.last_success_at),
            .last_new_at = try isoOrNull(alloc, s.last_new_at),
            .consecutive_failures = s.consecutive_failures,
            .documents_total = s.documents_total,
            .last_error = s.last_error,
            .freshness = s.freshness.name(),
            .change_detection = s.change_detection,
            .latest_doc = if (s.latest) |l| .{
                .title = l.title,
                .url = l.url,
                .fetched_at = try formatIso(alloc, l.fetched_at),
            } else null,
            .note = s.note,
        });
    }
    return stringifyAlloc(alloc, .{
        .sources = list.items,
        .facebook = facebook,
        .interval_s = interval_s,
        .summary = .{ .fresh = fresh, .stale = stale, .unknown = unknown },
        .freshness_rule = "fresh: last success within twice the ingest interval; stale: older; unknown: never succeeded",
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
    const flags = try events_intel.detectContradictionFlags(alloc, docs);
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
        // Contradiction flags (Roadmap 7.5): every divergent pair,
        // most dissimilar first, both sources cited. Each flag is a
        // WARNING for a human to check — never a verdict about
        // which report is right. Empty when the reports agree.
        .contradictions = flags,
        .timeline = day_list.items,
        .documents = doc_list.items,
        .request_id = req_id,
    });
}

const trending = @import("../intelligence/trending.zig");
const forecast_mod = @import("../intelligence/forecast.zig");
const statanswer = @import("../intelligence/statanswer.zig");
const alerts_mod = @import("../intelligence/alerts.zig");
const social_mod = @import("../intelligence/social.zig");
const connectors = @import("../ingestion/connectors.zig");

/// GET /v1/social — social ingestion status (Roadmap 7.7, GATED).
/// Reports the registry honestly: post counts by platform and top
/// hashtags from real authorized posts only, plus every social
/// connector's availability with its reason. With zero social data
/// connected — the state today — `social_available` is false,
/// the lists are empty, and the note says why. No counts are ever
/// synthesized, and no post text is returned here (the registry is
/// a trend feed, not a post mirror).
pub fn buildSocialResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    registry: *const social_mod.SocialRegistry,
    all: []const connectors.Connector,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    var conn_list: std.ArrayList(struct {
        kind: []const u8,
        name: []const u8,
        available: bool,
        reason: ?[]const u8,
    }) = .empty;
    for (all) |c| {
        // Only the social connectors belong here: Facebook, X,
        // Reddit, YouTube. RSS/news/government/OSM are not social.
        const k = c.kind;
        if (k != .facebook and k != .x and k != .reddit and k != .youtube) continue;
        const av = c.check(alloc, environ);
        try conn_list.append(alloc, .{
            .kind = @tagName(k),
            .name = c.name,
            .available = av == .available,
            .reason = if (av == .unavailable) av.unavailable else null,
        });
    }
    var platform_list: std.ArrayList(struct {
        platform: []const u8,
        count: usize,
    }) = .empty;
    for ([_][]const u8{ "facebook", "x", "reddit", "youtube" }) |p| {
        try platform_list.append(alloc, .{ .platform = p, .count = registry.countByPlatform(p) });
    }
    const tags = try registry.topHashtags(alloc, 10);
    return stringifyAlloc(alloc, .{
        .social_available = registry.count() > 0,
        .post_count = registry.count(),
        .posts_by_platform = platform_list.items,
        .top_hashtags = tags,
        .connectors = conn_list.items,
        .note = "No authorized social data is connected — the social section is empty by design. Authorize a social connector (Facebook Page, X, Reddit) to fill it; nothing here is scraped or invented.",
        .request_id = req_id,
    });
}

/// GET /v1/alerts — breaking alerts (Roadmap 7.3): merged
/// incidents from the knowledge store's breaking events, kinds
/// classified rules-based from the reports' own words, every
/// source cited. `stream_available` says whether the
/// `pulse:alerts` Redis stream exists for Sando to subscribe to;
/// the alerts in this response are computed live either way, so
/// the endpoint never depends on the stream.
pub fn buildAlertsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    now: i64,
    alerts: []const alerts_mod.MergedAlert,
    stream_available: bool,
) ![]u8 {
    var list: std.ArrayList(struct {
        kind: []const u8,
        title: []const u8,
        event_ids: []const []const u8,
        sources: []const []const u8,
        doc_count: usize,
        importance: f64,
        first_seen: i64,
        last_seen: i64,
    }) = .empty;
    for (alerts) |a| {
        try list.append(alloc, .{
            .kind = a.kind.toString(),
            .title = a.title,
            .event_ids = a.event_ids,
            .sources = a.source_ids,
            .doc_count = a.doc_count,
            .importance = a.importance,
            .first_seen = a.first_seen,
            .last_seen = a.last_seen,
        });
    }
    return stringifyAlloc(alloc, .{
        .alerts = list.items,
        .stream = alerts_mod.alert_stream,
        .stream_group = alerts_mod.alert_group,
        .stream_available = stream_available,
        .computed_at = now,
        .request_id = req_id,
    });
}

/// GET /v1/forecast — predictive trends (Roadmap 7.1): linear
/// extrapolations + z-score anomalies from monthly aggregates.
/// `insufficient` names topics asked for by name whose history is
/// too short to forecast (fewer than 2 months) — an honest refusal,
/// never a made-up number. The disclaimer is part of the payload:
/// predictions are statistical extrapolations, not facts.
pub fn buildForecastResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    now: i64,
    forecasts: []const forecast_mod.Forecast,
    anomalies: []const forecast_mod.Anomaly,
    insufficient: []const []const u8,
) ![]u8 {
    var fc_list: std.ArrayList(struct {
        topic: []const u8,
        horizon_month: []const u8,
        predicted_count: f64,
        confidence: f64,
        basis: []const u8,
        method: []const u8,
        same_month_last_year: ?usize,
    }) = .empty;
    for (forecasts) |f| {
        try fc_list.append(alloc, .{
            .topic = f.topic,
            .horizon_month = f.horizon_month,
            .predicted_count = f.predicted_count,
            .confidence = f.confidence,
            .basis = f.basis,
            .method = f.method,
            .same_month_last_year = f.same_month_last_year,
        });
    }
    var an_list: std.ArrayList(struct {
        topic: []const u8,
        year_month: []const u8,
        doc_count: usize,
        mean: f64,
        stddev: f64,
        z_score: f64,
        direction: []const u8,
    }) = .empty;
    for (anomalies) |a| {
        try an_list.append(alloc, .{
            .topic = a.topic,
            .year_month = a.year_month,
            .doc_count = a.doc_count,
            .mean = a.mean,
            .stddev = a.stddev,
            .z_score = a.z_score,
            .direction = a.direction,
        });
    }
    return stringifyAlloc(alloc, .{
        .forecasts = fc_list.items,
        .anomalies = an_list.items,
        .insufficient_history = insufficient,
        .disclaimer = "Predictions are statistical extrapolations from past document volume, not facts. Confidence reflects how well a straight line fits the topic's own history, nothing more.",
        .computed_at = now,
        .request_id = req_id,
    });
}

/// GET /v1/trends — Geez and trending engine (Roadmap 4.2): ranked
/// topics with velocity, geographic trending, and monthly snapshots.
/// `snapshots` are the latest 3 months present in the aggregates.
/// `forecasts` (Roadmap 7.1) is the forecast section: the top
/// topics' next-month predictions, same shape as /v1/forecast.
pub fn buildTrendsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    now: i64,
    trends: []const trending.TopicTrend,
    geo: []const trending.GeoTrend,
    snapshots: []const trending.MonthSnapshot,
    forecasts: []const forecast_mod.Forecast,
    social_trends: []const trending.TopicTrend,
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
    var fc_list: std.ArrayList(struct {
        topic: []const u8,
        horizon_month: []const u8,
        predicted_count: f64,
        confidence: f64,
        basis: []const u8,
        method: []const u8,
        same_month_last_year: ?usize,
    }) = .empty;
    for (forecasts) |f| {
        try fc_list.append(alloc, .{
            .topic = f.topic,
            .horizon_month = f.horizon_month,
            .predicted_count = f.predicted_count,
            .confidence = f.confidence,
            .basis = f.basis,
            .method = f.method,
            .same_month_last_year = f.same_month_last_year,
        });
    }
    var social_list: std.ArrayList(struct {
        topic: []const u8,
        category: []const u8,
        recent_count: usize,
        prior_count: usize,
        velocity: f64,
        score: f64,
    }) = .empty;
    for (social_trends) |t| {
        try social_list.append(alloc, .{
            .topic = t.topic,
            .category = t.category,
            .recent_count = t.recent_count,
            .prior_count = t.prior_count,
            .velocity = t.velocity,
            .score = t.score,
        });
    }
    return stringifyAlloc(alloc, .{
        .trends = trend_list.items,
        .geo = geo_list.items,
        .snapshots = snap_list.items,
        .forecast = fc_list.items,
        // Social lane (Roadmap 7.7): hashtag trends from authorized
        // social posts only, category "social". Empty until a social
        // connector is authorized and feeds the registry — never
        // synthesized.
        .social = social_list.items,
        // Trends are computed live from a store scan on every request,
        // so they are never stale — the fields exist so callers can
        // treat every precomputed payload the same way (Roadmap 6.4).
        .computed_at = now,
        .stale = false,
        .request_id = req_id,
    });
}

/// GET /v1/popular — the most-asked queries (Roadmap 6.4). Only the
/// query text and a count are ever exposed; no consumer or identity
/// is recorded, so there is nothing to leak.
pub fn buildPopularResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    top_list: []const popular.ScoredQuery,
    tracked: usize,
) ![]u8 {
    var list: std.ArrayList(struct {
        query: []const u8,
        count: u64,
    }) = .empty;
    for (top_list) |row| try list.append(alloc, .{ .query = row.query, .count = row.count });
    return stringifyAlloc(alloc, .{
        .popular = list.items,
        .tracked = tracked,
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

test "buildEventDetailResponse carries contradiction flags (Roadmap 7.5)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const event = knowledge.KnowledgeEvent{
        .id = "ev1",
        .title = "Fuel shortage",
        .topic = "energy",
        .first_seen = 0,
        .last_seen = 86400,
        .doc_count = 3,
    };
    const docs = [_]knowledge.EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "Daily Observer", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "Fuel shortage hits Monrovia", .source_id = "s2", .source_name = "New Dawn", .published_at = 3600, .text = "" },
        .{ .id = "c", .title = "Kakata market opens new stalls", .source_id = "s3", .source_name = "GNN Liberia", .published_at = 7200, .text = "" },
    };
    const out = try buildEventDetailResponse(alloc, "req-test", event, &docs, 172800);
    // Two divergent pairs (a,c) and (b,c); the agreeing pair (a,b)
    // is not flagged. Both sources are cited on each flag, and the
    // warning note is present — never a verdict.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"contradictions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Kakata market opens new stalls") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Daily Observer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "check both sources") != null);
    // The agreeing event has no flags at all.
    const agree = [_]knowledge.EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "Daily Observer", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "Fuel shortage hits Monrovia", .source_id = "s2", .source_name = "New Dawn", .published_at = 3600, .text = "" },
    };
    const out2 = try buildEventDetailResponse(alloc, "req-test", event, &agree, 172800);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"contradictions\":[]") != null);
}

test "buildSocialResponse is honestly empty until real data arrives (Roadmap 7.7)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = social_mod.SocialRegistry.init(alloc);
    defer reg.deinit();
    const all = connectors.allConnectors();
    const out = try buildSocialResponse(alloc, "req-test", &reg, &all, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"social_available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"post_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"top_hashtags\":[]") != null);
    // Every social connector is listed as unavailable with its
    // reason — Facebook (no token), X (no API client), Reddit and
    // YouTube (no keys). No connector is faked as available.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"facebook\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PULSE_FACEBOOK_ACCESS_TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "X_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "scraped or invented") != null);
    // One real post lights it up with real counts only.
    try reg.ingest(.{ .id = "1", .platform = "facebook", .author = "A", .text = "Tonight #Geez", .posted_at = 1000, .url = "" });
    const out2 = try buildSocialResponse(alloc, "req-test", &reg, &all, null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"social_available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"post_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"tag\":\"geez\"") != null);
}

test "buildSourceProfilesResponse lists 12 profiles with live counts (Phase 1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = try trust_registry.Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const all = try reg.allProfiles(alloc);
    const counts = [_]types.SourceCount{
        .{ .source_id = "new-dawn", .count = 15 },
        .{ .source_id = "frontpage-africa", .count = 10 },
    };
    const out = try buildSourceProfilesResponse(alloc, "req-test", all, &counts);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"total\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"frontpage-africa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"county\":\"Montserrado\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"removed\"") != null);
    // Live counts land on the right profiles; uncounted sources read 0.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"documents_total\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"documents_total\":10") != null);
    // Honesty labels: not-yet-measured fields are null, and the
    // reliability note says the grade is not a credibility score.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"performance\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"posting_frequency\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not a computed credibility score") != null);
    // Local Voices is the one unverified county assignment.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"county_confidence\":\"unverified\"") != null);
}

test "buildSourceProfileResponse carries one profile plus its history (Phase 1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = try trust_registry.Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const prof = reg.profile("new-dawn").?;
    const hist = try reg.historyFor(alloc, "new-dawn");
    const out = try buildSourceProfileResponse(alloc, "req-test", prof, 15, hist);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"new-dawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"documents_total\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"profile_created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"at\":1763145600") != null);
}

test "buildCountiesResponse lists 15 counties, 12 sources, honest zeros (Phase 1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reg = try trust_registry.Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const counties = try reg.countByCounty(alloc);
    const out = try buildCountiesResponse(alloc, "req-test", counties);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"total_counties\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"total_sources\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"county\":\"Nimba\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"capital\":\"Sanniquellie\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"county\":\"Montserrado\",\"capital\":\"Monrovia\",\"sources\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "No sources registered for this county yet") != null);
}

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
    const live = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 12.345678, "simple_indexed", .{}, 10);
    try std.testing.expect(std.mem.indexOf(u8, live, "\"path\":\"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "\"latency_ms\":12.345678") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "\"routing_reason\":\"simple_indexed\"") != null);
    // The storable shape: empty markers stampServed expects.
    const stored = try buildQueryResponse(alloc, "", "fuel", p, outcome, 5, 1794477600, "", 0, "", .{}, 10);
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
    const two = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 1.0, "simple_indexed", .{}, 2);
    // Two result objects: count the "title" fields in the results array.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, two, "\"title\":"));
    const all = try buildQueryResponse(alloc, "req-1", "fuel", p, outcome, 5, 1794477600, "fast", 1.0, "simple_indexed", .{}, 20);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, all, "\"title\":"));
}

/// Trust & Intelligence Engine, Phase 3: one claim's evidence
/// assessment. The status is an assessment, never a verdict — see
/// corroboration.zig. `record` carries the supporting documents and
/// the contradiction flags so the reader can check the work.
pub fn buildEvidenceResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    record: trust_corroboration.EvidenceRecord,
) ![]u8 {
    var supporting: std.ArrayList(struct {
        source_id: []const u8,
        source_name: []const u8,
        title: []const u8,
        url: []const u8,
        published_at: []const u8,
        similarity: f64,
    }) = .empty;
    for (record.supporting) |s| {
        try supporting.append(alloc, .{
            .source_id = s.source_id,
            .source_name = s.source_name,
            .title = s.title,
            .url = s.url,
            .published_at = try formatIso(alloc, s.published_at),
            .similarity = s.similarity,
        });
    }
    var contradicting: std.ArrayList(struct {
        doc_a: []const u8,
        doc_b: []const u8,
        similarity: f64,
    }) = .empty;
    for (record.contradicting) |f| {
        try contradicting.append(alloc, .{
            .doc_a = f.a_title,
            .doc_b = f.b_title,
            .similarity = f.similarity,
        });
    }
    return stringifyAlloc(alloc, .{
        .claim = record.claim,
        .event_id = record.event_id,
        .status = record.status.name(),
        .confidence = record.confidence,
        .explanation = record.explanation,
        .basis = record.basis,
        .distinct_sources = record.distinct_sources,
        .supporting = supporting.items,
        .contradicting = contradicting.items,
        .assessed_at = try formatIso(alloc, record.assessed_at),
        .status_note = "Assessment, not a verdict: Pulse never calls a claim false. See STATUS.md.",
        .request_id = req_id,
    });
}

/// Trust & Intelligence Engine, Phase 3: the claims extracted from
/// one event's documents. Claim text is copied from the documents,
/// never generated.
pub fn buildClaimsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    event_id: []const u8,
    claims: []const trust_evidence.Claim,
) ![]u8 {
    var list: std.ArrayList(struct {
        text: []const u8,
        kind: []const u8,
        source_id: []const u8,
        source_name: []const u8,
        published_at: []const u8,
        url: []const u8,
    }) = .empty;
    for (claims) |c| {
        try list.append(alloc, .{
            .text = c.text,
            .kind = c.kind,
            .source_id = c.source_id,
            .source_name = c.source_name,
            .published_at = try formatIso(alloc, c.published_at),
            .url = c.url,
        });
    }
    return stringifyAlloc(alloc, .{
        .event_id = event_id,
        .total = list.items.len,
        .claims = list.items,
        .request_id = req_id,
    });
}

test "buildEvidenceResponse renders status, confidence, supporting and flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var supporting = [_]trust_corroboration.EvidenceDoc{.{
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .published_at = 1795000000,
        .similarity = 1,
    }};
    var no_flags = [_]events_intel.ContradictionFlag{};
    const rec = trust_corroboration.EvidenceRecord{
        .claim = "Fuel shortage hits Monrovia",
        .status = .corroborated,
        .confidence = 0.64,
        .explanation = "Two or more independent sources agree.",
        .basis = "2-3 independent sources agree",
        .supporting = &supporting,
        .contradicting = &no_flags,
        .distinct_sources = 2,
        .event_id = "ev1",
        .assessed_at = 1795000100,
    };
    const body = try buildEvidenceResponse(alloc, "req-9", rec);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"corroborated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "not a verdict") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "New Dawn") != null);
}

/// Trust & Intelligence Engine, Phase 4: one source's credibility
/// score as JSON (components with weights, values and the basis for
/// each; rating null when provisional).
pub const ScoreComponentJson = struct {
    name: []const u8,
    weight: f64,
    value: f64,
    basis: []const u8,
};

pub const ScoreJson = struct {
    source_id: []const u8,
    source_name: []const u8,
    total: f64,
    rating: ?u8,
    provisional: bool,
    provisional_reason: ?[]const u8,
    docs_in_window: usize,
    components: [7]ScoreComponentJson,
};

fn scoreJson(s: trust_score.Score) ScoreJson {
    var comps: [7]ScoreComponentJson = undefined;
    for (s.components, 0..) |c, i| {
        comps[i] = .{ .name = c.name, .weight = c.weight, .value = c.value, .basis = c.basis };
    }
    return .{
        .source_id = s.source_id,
        .source_name = s.source_name,
        .total = s.total,
        .rating = s.rating,
        .provisional = s.provisional,
        .provisional_reason = s.provisional_reason,
        .docs_in_window = s.docs_in_window,
        .components = comps,
    };
}

/// Trust & Intelligence Engine, Phase 4: all sources' scores.
pub fn buildScoresResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    scores: []const trust_score.Score,
    window_days: i64,
) ![]u8 {
    var list: std.ArrayList(ScoreJson) = .empty;
    for (scores) |s| try list.append(alloc, scoreJson(s));
    return stringifyAlloc(alloc, .{
        .window_days = window_days,
        .total = list.items.len,
        .scores = list.items,
        .weights_note = "accuracy 30%, corroboration 20%, evidence 15%, original reporting 10%, timeliness 10%, corrections 10%, local knowledge 5%. Rating 1-5; null when provisional (fewer than 5 documents in the window).",
        .request_id = req_id,
    });
}

/// Trust & Intelligence Engine, Phase 4: one county's ranking.
pub fn buildRankingsResponse(
    alloc: std.mem.Allocator,
    req_id: []const u8,
    county: []const u8,
    capital: []const u8,
    candidates: usize,
    ranked: []const trust_score.RankedEntry,
    note: []const u8,
) ![]u8 {
    var list: std.ArrayList(struct {
        rank: usize,
        source_id: []const u8,
        source_name: []const u8,
        total: f64,
        rating: ?u8,
        provisional: bool,
    }) = .empty;
    for (ranked) |r| {
        try list.append(alloc, .{
            .rank = r.rank,
            .source_id = r.score.source_id,
            .source_name = r.score.source_name,
            .total = r.score.total,
            .rating = r.score.rating,
            .provisional = r.score.provisional,
        });
    }
    return stringifyAlloc(alloc, .{
        .county = county,
        .capital = capital,
        .candidates = candidates,
        .total = list.items.len,
        .rankings = list.items,
        .note = note,
        .request_id = req_id,
    });
}

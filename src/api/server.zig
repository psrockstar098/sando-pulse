//! HTTP server (Roadmap 1.2): std.http.Server ONLY — no external framework.
//! Single-threaded accept loop; one arena allocator per request.
//! Routes:
//!   GET  /v1/health   public — liveness + index size
//!   GET  /v1/sources  public — source registry + per-source doc counts
//!   GET  /v1/events   public — persisted event clusters (Roadmap 3.4)
//!   GET  /v1/trends   public — Geez + trending engine (Roadmap 4.2)
//!   GET  /v1/briefing public — precomputed intelligence (Roadmap 4.4)
//!   GET  /v1/quality  public — reliability, confidence, flags (Roadmap 4.6)
//!   GET  /v1/locations public — reference places (Roadmap 3.6)
//!   GET  /v1/statistics public — seeded statistics (Roadmap 3.6)
//!   GET  /v1/connectors/facebook public — Facebook connector status (3.2)
//!   GET  /v1/webhooks/facebook public — Meta subscription handshake (3.2)
//!   POST /v1/webhooks/facebook public — Meta webhook receiver, HMAC-verified (3.2)
//!   GET  /metrics     public — Prometheus exposition (Roadmap 1.5)
//!   POST /v1/query    auth + rate limit — planned search with citations
//!   POST /v1/ingest   auth + rate limit — manual document ingest
//! Auth: Bearer API key when PULSE_API_KEY is set; open dev mode otherwise.
//! Rate limits: 100/min + 10,000/day per key (configurable).

const std = @import("std");
const logging = @import("../common/logging.zig");
const types = @import("../common/types.zig");
const config = @import("../config/config.zig");
const repository = @import("../storage/repository.zig");
const knowledge = @import("../storage/knowledge.zig");
const planner = @import("../engine/planner.zig");
const search = @import("../engine/search.zig");
const entities = @import("../engine/entities.zig");
const geo = @import("../engine/geo.zig");
const language = @import("../engine/language.zig");
const sources = @import("../ingestion/sources.zig");
const validate = @import("../ingestion/validate.zig");
const pipeline = @import("../ingestion/pipeline.zig");
const facebook = @import("../ingestion/connectors/facebook/facebook.zig");
const fb_webhooks = @import("../ingestion/connectors/facebook/webhooks.zig");
const trending = @import("../intelligence/trending.zig");
const precomputed = @import("../intelligence/precomputed.zig");
const quality = @import("../intelligence/quality.zig");
const redis = @import("../storage/redis.zig");
const providers = @import("../ai/providers.zig");
const auth = @import("auth.zig");
const ratelimit = @import("ratelimit.zig");
const metrics = @import("metrics.zig");
const cache = @import("cache.zig");
const timex = @import("../common/time.zig");
const query_json = @import("query.zig");

pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    repo: repository.Repository,
    store_name: []const u8,
    metrics: *metrics.Metrics,
    limiter: *ratelimit.RateLimiter,
    sink: ?pipeline.EventSink,
    /// Embedding provider for semantic search + ingest-time embeddings.
    /// Null when PULSE_EMBEDDING_PROVIDER=none (or external without keys).
    embedder: ?providers.EmbeddingProvider = null,
    /// Knowledge store for events/locations/statistics (Roadmap 3.4).
    /// Always present (memory or Postgres, matching the repo).
    knowledge: ?knowledge.KnowledgeStore = null,
    /// Facebook connector (Roadmap 3.2): status route + webhook
    /// receiver. Always present; it reports unavailable until a
    /// token + registry are configured.
    facebook: ?*facebook.FacebookConnector = null,
    /// Redis client for the briefing cache (Roadmap 4.4) and the query
    /// cache (Roadmap 4.5). Null when Redis is not configured — the
    /// endpoints recompute live instead.
    redis: ?*redis.RedisClient = null,

    pub fn serve(self: *Server) !void {
        const addr = std.Io.net.IpAddress.parse(self.cfg.host, self.cfg.port) catch |e| {
            logging.err("invalid listen address", &.{ .{ .key = "error", .value = @errorName(e) } });
            return e;
        };
        var listener = std.Io.net.IpAddress.listen(&addr, self.io, .{ .reuse_address = true }) catch |e| {
            logging.err("listen failed", &.{
                .{ .key = "host", .value = self.cfg.host },
                .{ .key = "port", .value = try std.fmt.allocPrint(self.alloc, "{d}", .{self.cfg.port}) },
                .{ .key = "error", .value = @errorName(e) },
            });
            return e;
        };
        defer listener.deinit(self.io);
        logging.info("pulse listening", &.{
            .{ .key = "host", .value = self.cfg.host },
            .{ .key = "port", .value = try std.fmt.allocPrint(self.alloc, "{d}", .{self.cfg.port}) },
            .{ .key = "store", .value = self.store_name },
            .{ .key = "auth", .value = if (self.cfg.api_key != null) "api-key" else "open-dev-mode" },
        });
        while (true) {
            var stream = listener.accept(self.io) catch |e| {
                logging.warn("accept failed", &.{.{ .key = "error", .value = @errorName(e) }});
                continue;
            };
            self.handleConnection(&stream);
            stream.close(self.io);
        }
    }

    fn handleConnection(self: *Server, stream: *std.Io.net.Stream) void {
        var in_buf: [16384]u8 = undefined;
        var out_buf: [16384]u8 = undefined;
        var in_reader = stream.reader(self.io, &in_buf);
        var out_writer = stream.writer(self.io, &out_buf);
        var http_server = std.http.Server.init(&in_reader.interface, &out_writer.interface);
        while (true) {
            var req = http_server.receiveHead() catch break;
            const keep = req.head.keep_alive;
            self.handleRequest(&req) catch |e| {
                logging.warn("request handling failed", &.{.{ .key = "error", .value = @errorName(e) }});
                break;
            };
            if (!keep) break;
        }
    }

    fn headerValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, head_buffer, "\r\n");
        _ = it.next(); // request line
        while (it.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const hn = std.mem.trim(u8, line[0..colon], " ");
                if (std.ascii.eqlIgnoreCase(hn, name)) {
                    return std.mem.trim(u8, line[colon + 1 ..], " ");
                }
            }
        }
        return null;
    }

    fn newRequestId(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
        const ts: i96 = timex.nowNanos(io);
        return std.fmt.allocPrint(alloc, "req-{x}", .{ts});
    }

    fn respondJsonCached(req: *std.http.Server.Request, status: std.http.Status, body: []const u8, req_id: []const u8, cached: bool) !void {
        try req.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-request-id", .value = req_id },
                .{ .name = "x-pulse-cached", .value = if (cached) "true" else "false" },
            },
        });
    }

    /// Read the top-level "sufficient" flag out of a cached query body.
    /// The renderer emits `"sufficient":true|false` exactly once.
    fn cachedSufficient(body: []const u8) ?bool {
        if (std.mem.indexOf(u8, body, "\"sufficient\":true") != null) return true;
        if (std.mem.indexOf(u8, body, "\"sufficient\":false") != null) return false;
        return null;
    }

    fn respondJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8, req_id: []const u8) !void {
        try req.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-request-id", .value = req_id },
            },
        });
    }

    fn respondError(self: *Server, req: *std.http.Server.Request, arena: std.mem.Allocator, req_id: []const u8, status: std.http.Status, code: []const u8, message: []const u8) void {
        const body = query_json.buildErrorResponse(arena, req_id, code, message) catch {
            req.respond("{\"error\":{\"code\":\"internal\",\"message\":\"failed to render error\"}}", .{ .status = .internal_server_error }) catch {};
            return;
        };
        self.metrics.observeRequest(@intFromEnum(status), 0);
        req.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-request-id", .value = req_id },
            },
        }) catch {};
    }

    fn readBody(req: *std.http.Server.Request, arena: std.mem.Allocator) ![]const u8 {
        const len = req.head.content_length orelse return "";
        if (len == 0) return "";
        if (len > 1_000_000) return error.InvalidRequest;
        var buf: [8192]u8 = undefined;
        var reader = if (req.head.expect != null)
            try req.readerExpectContinue(&buf)
        else
            req.readerExpectNone(&buf);
        return reader.readAllocAll(arena, @intCast(len));
    }

    fn checkAuthAndRate(self: *Server, req: *std.http.Server.Request, arena: std.mem.Allocator, req_id: []const u8) bool {
        const auth_header = headerValue(req.head_buffer, "authorization");
        switch (auth.authenticate(self.cfg.api_key, auth_header)) {
            .open, .ok => {},
            .missing => {
                self.respondError(req, arena, req_id, .unauthorized, "auth_required", "Missing Authorization: Bearer <api-key> header");
                return false;
            },
            .invalid => {
                self.respondError(req, arena, req_id, .unauthorized, "auth_invalid", "Invalid API key");
                return false;
            },
        }
        const key = self.cfg.api_key orelse "anonymous";
        const check = self.limiter.check(key, timex.nowMillis(self.io)) catch {
            self.respondError(req, arena, req_id, .too_many_requests, "rate_limited", "Rate limit exceeded");
            return false;
        };
        if (!check.allowed) {
            const body = query_json.buildErrorResponse(arena, req_id, "rate_limited", "Rate limit exceeded") catch {
                self.respondError(req, arena, req_id, .too_many_requests, "rate_limited", "Rate limit exceeded");
                return false;
            };
            self.metrics.observeRequest(429, 0);
            req.respond(body, .{
                .status = .too_many_requests,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "x-request-id", .value = req_id },
                    .{ .name = "retry-after", .value = std.fmt.allocPrint(arena, "{d}", .{check.retry_after_s}) catch "60" },
                },
            }) catch {};
            return false;
        }
        return true;
    }

    fn pathOf(target: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
        return target;
    }

    fn queryOf(target: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[i + 1 ..];
        return null;
    }

    /// One query-string parameter value (e.g. kind=city in
    /// "?kind=city&limit=20"), or null when absent. No URL-decoding:
    /// our parameter values (kind names, integers) never need it.
    fn queryParam(query: ?[]const u8, key: []const u8) ?[]const u8 {
        const q = query orelse return null;
        var it = std.mem.splitScalar(u8, q, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        return null;
    }

    fn handleRequest(self: *Server, req: *std.http.Server.Request) !void {
        const start_ms = timex.nowMillis(self.io);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const req_id = try newRequestId(alloc, self.io);
        const method = req.head.method;
        const path = pathOf(req.head.target);

        if (method == .GET and std.mem.eql(u8, path, "/v1/health")) {
            const body = try query_json.buildHealthResponse(alloc, req_id, self.repo.countDocuments(), sources.enabledCount(), self.store_name);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/sources")) {
            const counts = try self.repo.countBySource(alloc);
            const body = try query_json.buildSourcesResponse(alloc, req_id, counts);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/events")) {
            if (self.knowledge) |k| {
                // Detail: /v1/events?id=<event_id> — the event plus
                // its documents, corroboration, status, conflicts and
                // timeline (4.1).
                if (queryParam(queryOf(req.head.target), "id")) |ev_id| {
                    const ev = (k.getEvent(alloc, ev_id) catch {
                        self.respondError(req, alloc, req_id, .internal_server_error, "event_failed", "Failed to load event");
                        return;
                    }) orelse {
                        self.respondError(req, alloc, req_id, .not_found, "event_not_found", "No such event");
                        return;
                    };
                    const docs = k.eventDocs(alloc, ev_id) catch {
                        self.respondError(req, alloc, req_id, .internal_server_error, "event_docs_failed", "Failed to list event documents");
                        return;
                    };
                    const body = try query_json.buildEventDetailResponse(alloc, req_id, ev, docs, timex.nowSeconds(self.io));
                    self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                    try respondJson(req, .ok, body, req_id);
                    return;
                }
                const events = k.listEvents(alloc, 20) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "events_failed", "Failed to list events");
                    return;
                };
                const body = try query_json.buildEventsResponse(alloc, req_id, events, timex.nowSeconds(self.io));
                self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                try respondJson(req, .ok, body, req_id);
                return;
            }
            self.respondError(req, alloc, req_id, .internal_server_error, "events_unavailable", "Knowledge store unavailable");
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/trends")) {
            const q = queryOf(req.head.target);
            const window_s = trending.parseWindow(queryParam(q, "window")) orelse {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_window", "window must be 24h, 7d, or 30d");
                return;
            };
            const category = queryParam(q, "category");
            const county = queryParam(q, "county");
            var limit: usize = 10;
            if (queryParam(q, "limit")) |ls| {
                limit = std.fmt.parseInt(usize, ls, 10) catch 10;
                if (limit > 50) limit = 50;
            }
            const now = timex.nowSeconds(self.io);
            const docs = self.repo.scanDocuments(alloc, now, 5000) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "trends_failed", "Failed to scan documents");
                return;
            };
            var all_trends = trending.computeTrends(alloc, docs, now, window_s) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "trends_failed", "Failed to compute trends");
                return;
            };
            if (category) |cat| {
                var kept: std.ArrayList(trending.TopicTrend) = .empty;
                for (all_trends) |t| {
                    if (std.mem.eql(u8, t.category, cat)) try kept.append(alloc, t);
                }
                all_trends = kept.items;
            }
            if (all_trends.len > limit) all_trends = all_trends[0..limit];
            var geo_trends = trending.computeGeoTrends(alloc, docs, now, window_s) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "trends_failed", "Failed to compute geographic trends");
                return;
            };
            if (county) |c| {
                var kept: std.ArrayList(trending.GeoTrend) = .empty;
                for (geo_trends) |g| {
                    if (std.mem.eql(u8, g.county, c)) try kept.append(alloc, g);
                }
                geo_trends = kept.items;
            }
            // Monthly snapshots: the latest 3 months present in the
            // maintenance aggregates (Roadmap 3.5), newest first.
            var snapshots: std.ArrayList(trending.MonthSnapshot) = .empty;
            if (self.knowledge) |k| {
                const aggs = k.listMonthlyAggregates(alloc, 200) catch &.{};
                var months: std.ArrayList([]const u8) = .empty;
                for (aggs) |row| {
                    var seen = false;
                    for (months.items) |m| {
                        if (std.mem.eql(u8, m, row.year_month)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try months.append(alloc, row.year_month);
                }
                std.mem.sort([]const u8, months.items, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, b, a);
                    }
                }.less);
                for (months.items[0..@min(months.items.len, 3)]) |m| {
                    try snapshots.append(alloc, try trending.snapshotFromAggregates(alloc, aggs, m));
                }
            }
            const body = try query_json.buildTrendsResponse(alloc, req_id, all_trends, geo_trends, snapshots.items);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/briefing")) {
            const now = timex.nowSeconds(self.io);
            // Serve the worker's cached payload when fresh; otherwise
            // compute live (and refresh the cache best-effort). The
            // cached flag tells the caller which path served the read.
            var cached_payload: ?[]u8 = null;
            if (self.redis) |rc| {
                cached_payload = rc.get(alloc, precomputed.briefing_key) catch null;
            }
            const payload: []const u8 = cached_payload orelse blk: {
                const b = precomputed.computeBriefing(alloc, self.repo, self.knowledge, now) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "briefing_failed", "Failed to compute briefing");
                    return;
                };
                const rendered = precomputed.renderBriefing(alloc, b) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "briefing_failed", "Failed to render briefing");
                    return;
                };
                if (self.redis) |rc| {
                    rc.setex(precomputed.briefing_key, self.cfg.precompute_ttl_s, rendered) catch {};
                }
                break :blk rendered;
            };
            const body = try std.fmt.allocPrint(alloc, "{{\"briefing\":{s},\"cached\":{},\"request_id\":\"{s}\"}}", .{ payload, cached_payload != null, req_id });
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/quality")) {
            const now = timex.nowSeconds(self.io);
            if (self.knowledge) |k| {
                const report = quality.computeQuality(alloc, k, now) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "quality_failed", "Failed to compute quality report");
                    return;
                };
                const body = quality.renderQuality(alloc, report, req_id) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "quality_failed", "Failed to render quality report");
                    return;
                };
                self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                try respondJson(req, .ok, body, req_id);
                return;
            }
            self.respondError(req, alloc, req_id, .internal_server_error, "quality_unavailable", "Knowledge store unavailable");
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/locations")) {
            if (self.knowledge) |k| {
                const q = queryOf(req.head.target);
                const kind = queryParam(q, "kind");
                var limit: usize = 100;
                if (queryParam(q, "limit")) |ls| {
                    limit = std.fmt.parseInt(usize, ls, 10) catch 100;
                }
                const locs = k.listLocations(alloc, kind, limit) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "locations_failed", "Failed to list locations");
                    return;
                };
                const body = try query_json.buildLocationsResponse(alloc, req_id, locs);
                self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                try respondJson(req, .ok, body, req_id);
                return;
            }
            self.respondError(req, alloc, req_id, .internal_server_error, "locations_unavailable", "Knowledge store unavailable");
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/statistics")) {
            if (self.knowledge) |k| {
                const stats = k.listStatistics(alloc) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "statistics_failed", "Failed to list statistics");
                    return;
                };
                const body = try query_json.buildStatisticsResponse(alloc, req_id, stats);
                self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                try respondJson(req, .ok, body, req_id);
                return;
            }
            self.respondError(req, alloc, req_id, .internal_server_error, "statistics_unavailable", "Knowledge store unavailable");
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/metrics")) {
            const body = try self.metrics.render(alloc);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; version=0.0.4" },
                    .{ .name = "x-request-id", .value = req_id },
                },
            });
            return;
        }

        if (method == .POST and std.mem.eql(u8, path, "/v1/query")) {
            if (!self.checkAuthAndRate(req, alloc, req_id)) return;
            const body = readBody(req, alloc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Request body too large or unreadable");
                return;
            };
            const qr = query_json.parseQueryRequest(alloc, body) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Body must be JSON with a non-empty \"query\" string (max 1000 chars)");
                return;
            };
            var enabled: std.ArrayList([]const u8) = .empty;
            for (sources.sources) |s| {
                if (s.enabled) try enabled.append(alloc, s.id);
            }
            // Query cache (Roadmap 4.5): an identical query+limit within
            // the TTL and the same ingest epoch serves the stored body.
            // The stored body is rendered with an empty request id; the
            // current id is spliced in on the way out. A miss, a stale
            // epoch, or a malformed entry all fall through to planning.
            var cache_key: ?[]u8 = null;
            var cache_epoch: i64 = 0;
            if (self.redis) |rc| {
                if (self.cfg.query_cache_ttl_s > 0) {
                    cache_key = cache.cacheKey(alloc, qr.query, qr.limit) catch null;
                    if (cache_key) |k| {
                        cache_epoch = cache.currentEpoch(rc, alloc);
                        if (cache.get(rc, alloc, k, cache_epoch) catch null) |stored| {
                            if (cache.stampRequestId(alloc, stored, req_id) catch null) |stamped_body| {
                                self.metrics.observeCacheHit();
                                self.metrics.observeQuery(cachedSufficient(stamped_body) orelse true);
                                self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                                try respondJsonCached(req, .ok, stamped_body, req_id, true);
                                return;
                            }
                        }
                        self.metrics.observeCacheMiss();
                    }
                }
            }
            const now = timex.nowSeconds(self.io);
            const p = planner.plan(alloc, qr.query, enabled.items, now, self.cfg.tz_offset_minutes) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "planner_failed", "Query planning failed");
                return;
            };
            const outcome = search.searchAndRank(alloc, self.repo, p, now, .{
                .embedder = self.embedder,
                .tz_offset_minutes = self.cfg.tz_offset_minutes,
            }) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "search_failed", "Search failed");
                return;
            };
            self.metrics.observeQuery(outcome.sufficient);
            const resp = query_json.buildQueryResponse(alloc, req_id, qr.query, p, outcome, enabled.items.len, timex.nowSeconds(self.io)) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "response_failed", "Failed to render response");
                return;
            };
            // Store a copy rendered with an empty request id so a later
            // hit can splice in its own id. Oversized responses are
            // served but never stored.
            if (self.redis) |rc| {
                if (cache_key) |k| {
                    if (resp.len <= cache.max_response_bytes) {
                        const storable = query_json.buildQueryResponse(alloc, "", qr.query, p, outcome, enabled.items.len, timex.nowSeconds(self.io)) catch null;
                        if (storable) |s| cache.put(rc, alloc, k, cache_epoch, s, self.cfg.query_cache_ttl_s) catch {};
                    }
                }
            }
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJsonCached(req, .ok, resp, req_id, false);
            return;
        }

        if (method == .POST and std.mem.eql(u8, path, "/v1/ingest")) {
            if (!self.checkAuthAndRate(req, alloc, req_id)) return;
            const body = readBody(req, alloc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Request body too large or unreadable");
                return;
            };
            const ir = query_json.parseIngestRequest(alloc, body) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Body must be JSON with title, text, url, and a registered source_id");
                return;
            };
            const source = sources.find(ir.source_id).?;
            const now = timex.nowSeconds(self.io);
            const combined = try std.mem.concat(alloc, u8, &.{ ir.title, " ", ir.text });
            const ent = entities.extract(alloc, combined) catch entities.Entities{};
            const id = types.contentHash(alloc, source.id, ir.url, ir.title) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "ingest_failed", "Failed to hash document");
                return;
            };
            var doc = types.Document{
                .id = id,
                .source_id = source.id,
                .source_name = source.name,
                .source_url = source.home_url,
                .title = ir.title,
                .url = ir.url,
                .text = ir.text,
                .published_at = null,
                .fetched_at = now,
                .reliability = source.reliability,
                .topics = ent.topics,
                .content_hash = id,
                .lang = language.identify(combined),
            };
            // Summary (3.3): extractive only, stored when it condenses.
            {
                var summarizer = providers.ExtractiveSummarizer{};
                if (summarizer.provider().summarize(alloc, ir.text, 2)) |raw| {
                    if (!std.mem.eql(u8, raw, ir.text)) {
                        doc.summary = raw;
                    } else {
                        alloc.free(raw);
                    }
                } else |_| {}
            }
            // Validation (3.3): malformed manual ingests are rejected.
            validate.validate(doc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_document", "Document failed validation (title, URL, text, or source)");
                return;
            };
            // Geo-tag from the extracted entities, same as the pipeline.
            if (ent.cities.len > 0) {
                if (geo.lookup(ent.cities[0])) |place| {
                    doc.lat = place.lat;
                    doc.lon = place.lon;
                }
            }
            if (doc.lat == null and ent.counties.len > 0) {
                if (geo.countyPoint(ent.counties[0])) |place| {
                    doc.lat = place.lat;
                    doc.lon = place.lon;
                }
            }
            if (self.embedder) |emb| {
                const capped = if (combined.len > 4000) combined[0..4000] else combined;
                if (emb.embed(alloc, capped)) |vec| {
                    doc.embedding = vec;
                } else |_| {}
            }
            self.repo.insertDocument(doc) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "ingest_failed", "Failed to store document");
                return;
            };
            // Knowledge recording (3.4): entities + event clustering.
            // Failures are warnings only — the document is already stored.
            if (self.knowledge) |k| {
                k.recordEntities(alloc, doc, ent) catch {};
                if (k.upsertEventForDoc(alloc, doc, ent)) |ev| {
                    alloc.free(ev);
                } else |_| {}
            }
            if (self.sink) |s| {
                s.publish(s.ptr, alloc, doc.id, doc.source_id) catch {};
            }
            self.metrics.setDocumentsIndexed(@intCast(self.repo.countDocuments()));
            const resp = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"source_id\":\"{s}\",\"request_id\":\"{s}\"}}", .{ doc.id, doc.source_id, req_id });
            self.metrics.observeRequest(201, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .created, resp, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/connectors/facebook")) {
            const fb = self.facebook orelse {
                self.respondError(req, alloc, req_id, .service_unavailable, "facebook_unavailable", "Facebook connector unavailable");
                return;
            };
            const body = try fb.statusJson(alloc);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        // Meta subscription handshake: Meta GETs
        // ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...;
        // Pulse echoes hub.challenge only when the token matches.
        // No API-key auth here — Meta calls this endpoint, and the
        // verify token IS the credential.
        if (method == .GET and std.mem.eql(u8, path, "/v1/webhooks/facebook")) {
            const fb = self.facebook orelse {
                self.respondError(req, alloc, req_id, .service_unavailable, "facebook_unavailable", "Facebook connector unavailable");
                return;
            };
            const challenge = fb.handleWebhookVerification(queryOf(req.head.target)) orelse {
                self.respondError(req, alloc, req_id, .forbidden, "verification_failed", "Webhook verification failed (mode/token)");
                return;
            };
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try req.respond(challenge, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                    .{ .name = "x-request-id", .value = req_id },
                },
            });
            return;
        }

        // Meta webhook receiver: the HMAC signature IS the auth
        // (no API key — Meta calls this endpoint). A failed
        // signature is 401; an unconfigured app secret is 503.
        // Validated notifications are recorded for the worker; the
        // response counts received vs recorded.
        if (method == .POST and std.mem.eql(u8, path, "/v1/webhooks/facebook")) {
            const fb = self.facebook orelse {
                self.respondError(req, alloc, req_id, .service_unavailable, "facebook_unavailable", "Facebook connector unavailable");
                return;
            };
            if (!fb.auth_cfg.canVerifyWebhooks()) {
                self.respondError(req, alloc, req_id, .service_unavailable, "webhooks_unavailable", "Facebook webhooks not configured (PULSE_FACEBOOK_APP_SECRET)");
                return;
            }
            const body = readBody(req, alloc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Request body too large or unreadable");
                return;
            };
            const sig = headerValue(req.head_buffer, "x-hub-signature-256");
            if (!fb.verifyWebhookSignature(body, sig)) {
                self.respondError(req, alloc, req_id, .unauthorized, "bad_signature", "Webhook signature verification failed");
                return;
            }
            const now = timex.nowSeconds(self.io);
            const notes = fb_webhooks.parseNotification(alloc, body, now) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_notification", "Webhook body is not a valid page notification");
                return;
            };
            var recorded: usize = 0;
            for (notes) |n| {
                fb.recordWebhook(alloc, n) catch continue;
                recorded += 1;
            }
            const resp = try std.fmt.allocPrint(alloc, "{{\"received\":{d},\"recorded\":{d},\"request_id\":\"{s}\"}}", .{ notes.len, recorded, req_id });
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, resp, req_id);
            return;
        }

        if ((method == .GET or method == .POST) and
            (std.mem.eql(u8, path, "/v1/health") or std.mem.eql(u8, path, "/v1/sources") or
                std.mem.eql(u8, path, "/v1/events") or std.mem.eql(u8, path, "/v1/trends") or
                std.mem.eql(u8, path, "/v1/briefing") or
                std.mem.eql(u8, path, "/v1/locations") or
                std.mem.eql(u8, path, "/v1/statistics") or
                std.mem.eql(u8, path, "/v1/connectors/facebook") or
                std.mem.eql(u8, path, "/v1/webhooks/facebook") or
                std.mem.eql(u8, path, "/metrics") or std.mem.eql(u8, path, "/v1/query") or
                std.mem.eql(u8, path, "/v1/ingest")))
        {
            self.respondError(req, alloc, req_id, .method_not_allowed, "method_not_allowed", "Method not allowed on this route");
            return;
        }
        self.respondError(req, alloc, req_id, .not_found, "not_found", "No such route");
    }
};

test "queryParam parses kind and limit" {
    try std.testing.expectEqualStrings("city", Server.queryParam("kind=city&limit=20", "kind").?);
    try std.testing.expectEqualStrings("20", Server.queryParam("kind=city&limit=20", "limit").?);
    try std.testing.expect(Server.queryParam("kind=city", "limit") == null);
    try std.testing.expect(Server.queryParam(null, "kind") == null);
    try std.testing.expect(Server.queryParam("kind", "kind") == null);
    try std.testing.expectEqualStrings("district", Server.queryParam("limit=5&kind=district", "kind").?);
}

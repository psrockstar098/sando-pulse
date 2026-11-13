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
//!   GET  /v1/popular public — most-asked queries (Roadmap 6.4)
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
const popular = @import("popular.zig");
const l1cache = @import("l1cache.zig");
const memindex = @import("../engine/memindex.zig");
const router = @import("../engine/router.zig");
const fanout = @import("../engine/fanout.zig");
const autotune = @import("../engine/autotune.zig");
const breaker = @import("../engine/breaker.zig");
const usage = @import("usage.zig");

/// Fan-out task: knowledge-store locations matching the query's
/// counties/cities (Roadmap 6.6). Runs in a worker thread when the
/// store is Postgres, inline otherwise.
const LocationsTask = struct {
    ks: knowledge.KnowledgeStore,
    counties: []const []const u8,
    cities: []const []const u8,
    out: []knowledge.LocationRow = &.{},

    fn run(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
        const t: *LocationsTask = @ptrCast(@alignCast(ctx));
        const all = try t.ks.listLocations(alloc, null, 500);
        var filtered: std.ArrayList(knowledge.LocationRow) = .empty;
        for (all) |loc| {
            if (filtered.items.len >= 10) break;
            if (locationMatches(loc, t.counties, t.cities)) try filtered.append(alloc, loc);
        }
        t.out = try filtered.toOwnedSlice(alloc);
    }
};

fn locationMatches(loc: knowledge.LocationRow, counties: []const []const u8, cities: []const []const u8) bool {
    for (counties) |c| {
        if (std.ascii.eqlIgnoreCase(loc.name, c)) return true;
        if (loc.county) |county| {
            if (std.ascii.eqlIgnoreCase(county, c)) return true;
        }
    }
    for (cities) |city| {
        if (std.ascii.eqlIgnoreCase(loc.name, city)) return true;
    }
    return false;
}

/// Fan-out task: knowledge-store statistics whose key names a query
/// topic (Roadmap 6.6). The full stat-answer feature is Roadmap 7.2;
/// this is the plumbing: concurrent fetch + merge.
const StatisticsTask = struct {
    ks: knowledge.KnowledgeStore,
    topics: []const []const u8,
    out: []knowledge.StatisticRow = &.{},

    fn run(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
        const t: *StatisticsTask = @ptrCast(@alignCast(ctx));
        const all = try t.ks.listStatistics(alloc);
        var filtered: std.ArrayList(knowledge.StatisticRow) = .empty;
        for (all) |stat| {
            if (filtered.items.len >= 10) break;
            const key_lower = try entities.lowerCopy(alloc, stat.key);
            defer alloc.free(key_lower);
            for (t.topics) |topic| {
                if (std.mem.indexOf(u8, key_lower, topic) != null) {
                    try filtered.append(alloc, stat);
                    break;
                }
            }
        }
        t.out = try filtered.toOwnedSlice(alloc);
    }
};
const auditlog = @import("auditlog.zig");
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
    /// L1 in-process cache (Roadmap 6.2). Always present; sits in front
    /// of the Redis (L2) query cache. Keys are consumer-scoped.
    l1: *l1cache.L1Cache,
    /// In-memory inverted index (Roadmap 6.3/6.5). Null when the boot
    /// build failed — queries then always use the store search.
    /// `index_epoch` is the Redis cache epoch the index was built from;
    /// `index_built_ms` gates the epoch-triggered rebuild interval.
    index: ?*memindex.MemIndex = null,
    index_epoch: i64 = 0,
    index_built_ms: i64 = 0,
    /// Popular searches (Roadmap 6.4). Always present; every asked
    /// query is recorded here (text + count only, no identity) and
    /// the top list drives cache warming at boot.
    popular: *popular.PopularSearches,
    /// Usage tracking (Roadmap 5.3): per-consumer counters, Redis-backed
    /// when a client is configured, in-memory otherwise. Always present.
    usage_tracker: *usage.UsageTracker,
    /// Audit sink (Roadmap 5.3): Postgres + JSONL + structured log.
    /// Always present; the sink degrades to log-only when neither
    /// Postgres nor a file is configured.
    audit_sink: *auditlog.AuditSink,
    /// Bounded auto-tuning (Roadmap 6.10): holds the live knob values
    /// the tuner moves (L1 TTL, fan-out timeout). The configured
    /// defaults live in cfg and are restored by reset().
    autotuner: autotune.Autotuner,
    /// Live fan-out deadline in ms (Roadmap 6.10): initialised from
    /// cfg, moved by the tuner. Read here instead of cfg so an
    /// adjustment takes effect on the next query.
    fanout_timeout_ms: u64,
    /// Circuit breakers (Roadmap 6.11). `redis_breaker` guards the L2
    /// cache lookups (value — owned by the server). `embed_breaker`
    /// points at the breaker inside the wrapped embedding provider
    /// (main.zig creates it; null when no external embedder is
    /// configured — the local provider never fails, so it is never
    /// wrapped). Both are read by the /metrics handler.
    redis_breaker: breaker.CircuitBreaker,
    embed_breaker: ?*breaker.CircuitBreaker = null,
    /// Whether the Redis client is known dead (Roadmap 6.11): the
    /// client holds one persistent TCP stream with no reconnect, so
    /// after Redis dies every command fails until the server
    /// restarts. Set on any L2 error; the next allowed L2 call
    /// tries a fresh connect first, so the breaker can observe a
    /// real trial call and close again.
    redis_dead: bool = false,
    /// Live reindex interval in seconds (Roadmap 6.11): initialised
    /// from cfg, movable by POST /v1/admin/config. Read here instead
    /// of cfg so a hot reload takes effect on the next query.
    reindex_interval_s: u64,

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
            .{ .key = "auth", .value = if (self.cfg.api_key != null) (if (self.cfg.api_key_previous != null) "api-key+rotation" else "api-key") else if (self.cfg.api_key_previous != null) "api-key(previous-only)" else "open-dev-mode" },
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
                .{ .name = "x-pulse-api-version", .value = "1" },
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
                .{ .name = "x-pulse-api-version", .value = "1" },
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
                .{ .name = "x-pulse-api-version", .value = "1" },
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

    /// Captured request-head values, owned by the per-request arena.
    /// std.http.Server INVALIDATES head/head_buffer pointers once the
    /// body stream is initialized (readBody), so everything the request
    /// needs from the head is copied here at the top of handleRequest.
    /// Nothing below may touch req.head.* or req.head_buffer after a
    /// readBody call — doing so reads freed memory and crashes (seen
    /// 2026-11-13: GPF in auditCall's pathOf on the query success path,
    /// and the same latent bug in the Facebook webhook signature read).
    const HeadCapture = struct {
        path: []const u8,
        query: ?[]const u8,
        method: std.http.Method,
        auth_header: ?[]const u8,
        consumer_header: ?[]const u8,
        webhook_sig: ?[]const u8,
    };

    fn captureHead(req: *std.http.Server.Request, alloc: std.mem.Allocator) !HeadCapture {
        const target = req.head.target;
        return .{
            .path = try alloc.dupe(u8, pathOf(target)),
            .query = if (queryOf(target)) |q| try alloc.dupe(u8, q) else null,
            .method = req.head.method,
            .auth_header = if (headerValue(req.head_buffer, "authorization")) |h| try alloc.dupe(u8, h) else null,
            .consumer_header = if (headerValue(req.head_buffer, "x-pulse-consumer")) |h| try alloc.dupe(u8, h) else null,
            .webhook_sig = if (headerValue(req.head_buffer, "x-hub-signature-256")) |h| try alloc.dupe(u8, h) else null,
        };
    }

    /// The consumer named by X-Pulse-Consumer, or "default" when the
    /// header is absent. Callers only reach this after checkAuthAndRate
    /// validated the name.
    fn consumerOf(head: HeadCapture) []const u8 {
        return head.consumer_header orelse usage.default_consumer_name;
    }

    /// Epoch-triggered index rebuild (Roadmap 6.5). When Redis is
    /// present and the cache epoch moved since the index was built —
    /// worker ingests bump it — and the rebuild interval elapsed,
    /// clear and rebuild the index from the store. A rebuild failure
    /// keeps the old index; this never fails a query.
    fn maybeRebuildIndex(self: *Server, alloc: std.mem.Allocator) void {
        const idx = self.index orelse return;
        const rc = self.redis orelse return;
        const epoch = cache.currentEpoch(rc, alloc);
        if (epoch == self.index_epoch) return;
        const now_ms = timex.nowMillis(self.io);
        if (now_ms - self.index_built_ms < @as(i64, @intCast(self.reindex_interval_s)) * 1000) return;
        idx.clear();
        const start_ms = now_ms;
        const report = idx.buildFromRepo(alloc, self.repo, timex.nowMillis(self.io), start_ms) catch {
            logging.warn("memindex rebuild failed, keeping old index", &.{});
            return;
        };
        self.index_epoch = epoch;
        self.index_built_ms = timex.nowMillis(self.io);
        logging.info("memindex rebuilt on epoch change", &.{
            .{ .key = "docs_added", .value = std.fmt.allocPrint(alloc, "{d}", .{report.docs_added}) catch "?" },
            .{ .key = "terms", .value = std.fmt.allocPrint(alloc, "{d}", .{report.terms}) catch "?" },
            .{ .key = "duration_ms", .value = std.fmt.allocPrint(alloc, "{d}", .{report.duration_ms}) catch "?" },
        });
    }

    /// Bounded auto-tuning check (Roadmap 6.10): after each query,
    /// ask the tuner whether a safe knob should move. The tuner
    /// decides from the metrics snapshot; at most one adjustment per
    /// 100 queries. An adjustment is applied to the live knob, logged
    /// (old -> new + reason), and counted in metrics. It never fails
    /// the query — a logging failure is swallowed.
    fn maybeAutotune(self: *Server) void {
        const m = self.metrics;
        const adj = self.autotuner.maybeTuneServer(.{
            .l1_hits = m.l1_cache_hits_total,
            .l1_misses = m.l1_cache_misses_total,
            .fanout_total = m.fanout_total,
            .fanout_incomplete = m.fanout_incomplete_total,
        }, m.queries_total) orelse return;
        switch (adj.knob) {
            .l1_ttl_s => self.l1.ttl_s = adj.new_value,
            .fanout_timeout_ms => self.fanout_timeout_ms = adj.new_value,
            .max_concurrent_sources => {}, // worker-side knob; the server never moves it.
        }
        m.observeAutotune();
        m.setAutotuneValues(self.autotuner.l1_ttl_s, self.autotuner.fanout_timeout_ms, self.autotuner.max_concurrent_sources);
        const knob_name = switch (adj.knob) {
            .l1_ttl_s => "l1_ttl_s",
            .fanout_timeout_ms => "fanout_timeout_ms",
            .max_concurrent_sources => "max_concurrent_sources",
        };
        logging.info("autotune adjustment", &.{
            .{ .key = "knob", .value = knob_name },
            .{ .key = "old", .value = std.fmt.allocPrint(self.alloc, "{d}", .{adj.old_value}) catch "?" },
            .{ .key = "new", .value = std.fmt.allocPrint(self.alloc, "{d}", .{adj.new_value}) catch "?" },
            .{ .key = "reason", .value = adj.reason },
        });
    }

    /// Process resident set size in bytes, Linux-only (Roadmap 6.10 /
    /// 6.12): reads /proc/self/statm (second field = resident pages).
    /// Returns 0 when the platform cannot report it — never an error.
    fn processRssBytes(self: *Server) u64 {
        const file = std.Io.Dir.cwd().openFile(self.io, "/proc/self/statm", .{}) catch return 0;
        defer file.close(self.io);
        var buf: [256]u8 = undefined;
        var rbuf: [256]u8 = undefined;
        var reader = file.reader(self.io, &rbuf);
        const n = reader.interface.readSliceShort(&buf) catch return 0;
        const text = buf[0..n];
        var it = std.mem.splitScalar(u8, text, ' ');
        _ = it.next(); // size (pages)
        const rss_pages = it.next() orelse return 0;
        const pages = std.fmt.parseInt(u64, std.mem.trim(u8, rss_pages, " \n"), 10) catch return 0;
        // Linux x86_64 page size (std has no page_size constant in 0.17.1).
        return pages * 4096;
    }

    /// Lazy Redis reconnect (Roadmap 6.11): the client holds one
    /// persistent TCP stream with no reconnect, so after Redis dies
    /// every command fails until the server restarts. When the L2
    /// path has marked the client dead, try a fresh connect and
    /// overwrite the client IN PLACE — the usage tracker and the
    /// event-bus sink hold the same pointer, so every holder sees
    /// the fresh connection at once. Order matters: connect FIRST,
    /// then close the old stream and overwrite. A failed connect
    /// leaves the old client untouched (dead but open — its
    /// commands fail as errors). Closing it first would leave a
    /// closed fd behind, and the next write from another holder
    /// panics the process (BADF is a programmer-bug panic in
    /// std.Io.Threaded, not a catchable error — found by the smoke
    /// test). Returns true when a live client is present afterwards.
    fn reconnectRedis(self: *Server) bool {
        const url = self.cfg.redis_url orelse return false;
        const client = self.redis orelse return false;
        const connected = redis.RedisClient.connect(self.alloc, self.io, url) catch return false;
        client.close();
        client.* = connected;
        self.redis_dead = false;
        logging.info("redis reconnected", &.{});
        return true;
    }

    fn keyFpOf(head: HeadCapture, arena: std.mem.Allocator) []const u8 {
        const presented = auth.presentedToken(head.auth_header);
        return auditlog.keyFingerprint(arena, presented) catch "anonymous";
    }

    /// Write one audit record for this request (best-effort, never fails
    /// the request). `status` is the final HTTP status.
    fn auditCall(self: *Server, head: HeadCapture, arena: std.mem.Allocator, req_id: []const u8, status: u16) void {
        self.audit_sink.record(.{
            .ts = timex.nowSeconds(self.io),
            .consumer = consumerOf(head),
            .key_fingerprint = keyFpOf(head, arena),
            .route = head.path,
            .method = @tagName(head.method),
            .status = status,
            .request_id = req_id,
        });
    }

    /// Count one completed query/ingest call against the consumer's
    /// daily usage. Best-effort: a tracking failure never fails the
    /// request (the quota check reads the same counter, so a lost
    /// increment only ever under-counts).
    fn recordUsage(self: *Server, head: HeadCapture, kind: usage.UsageKind) void {
        const day = usage.dayOf(self.alloc, timex.nowSeconds(self.io)) catch return;
        defer self.alloc.free(day);
        self.usage_tracker.record(consumerOf(head), kind, day) catch {};
    }

    /// Auth + scope + rate limit + quota gate (Roadmap 5.3).
    /// `kind` is the usage kind being gated, or null for the admin
    /// endpoint (/v1/usage), which is rate-limited but not quota-counted.
    /// Denials are audit-recorded with their status before responding.
    /// Check order: auth first, then consumer/scope — a missing key must
    /// report auth_required, not unknown_consumer.
    fn checkAuthAndRate(self: *Server, req: *std.http.Server.Request, head: HeadCapture, arena: std.mem.Allocator, req_id: []const u8, kind: ?usage.UsageKind) bool {
        const auth_header = head.auth_header;
        switch (auth.authenticateRotated(self.cfg.api_key, self.cfg.api_key_previous, auth_header)) {
            .open, .ok => {},
            .missing => {
                self.auditCall(head, arena, req_id, 401);
                self.respondError(req, arena, req_id, .unauthorized, "auth_required", "Missing Authorization: Bearer <api-key> header");
                return false;
            },
            .invalid => {
                self.auditCall(head, arena, req_id, 401);
                self.respondError(req, arena, req_id, .unauthorized, "auth_invalid", "Invalid API key");
                return false;
            },
        }
        // Consumer resolution: unknown names and malformed names are
        // denials, not defaults — a typo'd consumer must not silently
        // spend the default consumer's quota.
        const consumer_name = consumerOf(head);
        if (!usage.validConsumerName(consumer_name)) {
            self.auditCall(head, arena, req_id, 400);
            self.respondError(req, arena, req_id, .bad_request, "invalid_consumer", "X-Pulse-Consumer must be 1-64 chars of [a-z0-9_-]");
            return false;
        }
        var default_consumer = usage.Consumer{
            .name = usage.default_consumer_name,
            .scopes = &.{ .query, .ingest, .admin },
            .quota_per_day = 0,
        };
        const consumer: *const usage.Consumer = if (self.cfg.consumers.len == 0)
            &default_consumer
        else if (usage.findConsumer(self.cfg.consumers, consumer_name)) |c|
            c
        else {
            self.auditCall(head, arena, req_id, 401);
            self.respondError(req, arena, req_id, .unauthorized, "unknown_consumer", "No such consumer is registered");
            return false;
        };
        const needed: usage.Scope = if (kind) |k| switch (k) {
            .query => .query,
            .ingest => .ingest,
        } else .admin;
        if (!usage.consumerHasScope(consumer, needed)) {
            self.auditCall(head, arena, req_id, 403);
            self.respondError(req, arena, req_id, .forbidden, "forbidden_scope", "This consumer does not hold the scope for this endpoint");
            return false;
        }
        // Rate-limit bucket: the presented token (each key gets its own
        // budget during rotation); "anonymous" in open dev mode.
        const key = auth.presentedToken(auth_header) orelse "anonymous";
        const check = self.limiter.check(key, timex.nowMillis(self.io)) catch {
            self.auditCall(head, arena, req_id, 429);
            self.respondError(req, arena, req_id, .too_many_requests, "rate_limited", "Rate limit exceeded");
            return false;
        };
        if (!check.allowed) {
            const body = query_json.buildErrorResponse(arena, req_id, "rate_limited", "Rate limit exceeded") catch {
                self.auditCall(head, arena, req_id, 429);
                self.respondError(req, arena, req_id, .too_many_requests, "rate_limited", "Rate limit exceeded");
                return false;
            };
            self.metrics.observeRequest(429, 0);
            self.auditCall(head, arena, req_id, 429);
            req.respond(body, .{
                .status = .too_many_requests,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "x-request-id", .value = req_id },
                    .{ .name = "retry-after", .value = std.fmt.allocPrint(arena, "{d}", .{check.retry_after_s}) catch "60" },
                    .{ .name = "x-pulse-api-version", .value = "1" },
                },
            }) catch {};
            return false;
        }
        // Per-consumer daily quota (query/ingest only). The effective
        // quota is the consumer's own, or the global daily limit when
        // the consumer's is 0 (unset).
        if (kind) |k| {
            const effective = if (consumer.quota_per_day > 0) consumer.quota_per_day else self.cfg.rate_limit_per_day;
            const day = usage.dayOf(arena, timex.nowSeconds(self.io)) catch {
                self.auditCall(head, arena, req_id, 429);
                self.respondError(req, arena, req_id, .too_many_requests, "quota_exceeded", "Daily quota exceeded");
                return false;
            };
            const used = self.usage_tracker.count(arena, consumer.name, k, day);
            if (used >= effective) {
                self.auditCall(head, arena, req_id, 429);
                self.respondError(req, arena, req_id, .too_many_requests, "quota_exceeded", "Daily quota exceeded for this consumer");
                return false;
            }
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

    /// Result of running the full query pipeline (Roadmap 6.4 warming).
    /// `resp` is rendered with the caller's request id for immediate
    /// serving; `storable` is the same response with empty markers for
    /// the L1/L2 caches (null when rendering it failed — the response is
    /// still served, just never stored). `tags` are the plan's
    /// topics/counties/cities for L1 tag invalidation. `fo` is the
    /// fan-out handle: the caller MUST call joinAll AFTER the response
    /// is sent — the task contexts live in `alloc` (the caller's arena),
    /// so they stay valid until the caller frees it.
    const ComputeResult = struct {
        resp: []u8,
        storable: ?[]u8,
        path: []const u8,
        reason: []const u8,
        latency_ms: f64,
        sufficient: bool,
        tags: []const []const u8,
        fo: ?fanout.Fanout,
    };

    /// Run the whole query pipeline for one query: plan, route, index
    /// shortlist, parallel fan-out, search, render. Used by the query
    /// handler on a cache miss AND by cache warming at boot — one path,
    /// so a warmed answer is byte-identical to a freshly computed one.
    fn computeQuery(self: *Server, alloc: std.mem.Allocator, query_text: []const u8, enabled: []const []const u8, req_id: []const u8, query_start_ns: i96) !ComputeResult {
        const now = timex.nowSeconds(self.io);
        const p = planner.plan(alloc, query_text, enabled, now, self.cfg.tz_offset_minutes) catch return error.PlannerFailed;
        // Three-path router (Roadmap 6.1/6.7): instant is served by the
        // caches above; here we choose fast vs deep.
        const decision = router.route(p, .{});
        // Fast path: shortlist candidates from the in-memory index
        // (Roadmap 6.3) and resolve them via getDocument. Fewer than
        // 3 usable candidates falls back to the store search — the
        // deep path skips the index entirely.
        var index_docs: ?[]types.Document = null;
        if (decision.path == .fast) {
            if (self.index) |idx| {
                if (idx.search(alloc, p.terms, timex.nowMillis(self.io), 50) catch null) |cands| {
                    self.metrics.observeMemindexLookup();
                    if (cands.len >= 3) {
                        var docs: std.ArrayList(types.Document) = .empty;
                        for (cands) |c| {
                            if (self.repo.getDocument(alloc, c.doc_id) catch null) |d| {
                                docs.append(alloc, d) catch {};
                            }
                        }
                        if (docs.items.len >= 3) {
                            index_docs = docs.items;
                            self.metrics.observeMemindexHit();
                        } else docs.deinit(alloc);
                    }
                }
            }
        }
        // Parallel fan-out (Roadmap 6.6): locations + statistics from
        // the knowledge store run concurrently with the news search
        // below. Parallel only when the store is Postgres (its
        // knowledge store is mutex-guarded); the memory store runs
        // the same tasks inline. When PULSE_PARALLEL_QUERY=0 the
        // tasks run inline too. No entities in the plan = nothing
        // to enrich, so no fan-out at all. The task contexts and the
        // task list live in the caller's arena, NOT on this stack:
        // the threads may still be running when computeQuery returns,
        // and the caller joins them after the response is sent.
        var fo: ?fanout.Fanout = null;
        var loc_task: ?*LocationsTask = null;
        var stat_task: ?*StatisticsTask = null;
        if ((p.counties.len > 0 or p.cities.len > 0 or p.topics.len > 0) and self.knowledge != null) {
            const lt = try alloc.create(LocationsTask);
            lt.* = .{ .ks = self.knowledge.?, .counties = p.counties, .cities = p.cities };
            loc_task = lt;
            const st = try alloc.create(StatisticsTask);
            st.* = .{ .ks = self.knowledge.?, .topics = p.topics };
            stat_task = st;
            const tasks = try alloc.alloc(fanout.Task, 2);
            tasks[0] = .{ .name = "locations", .run = LocationsTask.run, .ctx = loc_task.? };
            tasks[1] = .{ .name = "statistics", .run = StatisticsTask.run, .ctx = stat_task.? };
            const parallel = self.cfg.parallel_query and std.mem.eql(u8, self.store_name, "postgres");
            fo = fanout.Fanout.start(alloc, tasks, parallel) catch null;
            if (fo == null) fanout.runSequential(alloc, tasks);
        }
        const outcome = search.searchAndRank(alloc, self.repo, p, now, .{
            .embedder = self.embedder,
            .tz_offset_minutes = self.cfg.tz_offset_minutes,
            .candidates = index_docs,
        }) catch {
            if (fo) |*f| f.joinAll();
            return error.SearchFailed;
        };
        // Fan-out merge (Roadmap 6.6): wait for the knowledge tasks
        // until the deadline, then take whatever completed. A task
        // still running leaves its section empty and
        // fanout_complete false (partial results, labelled).
        var enrich = query_json.Enrichment{};
        if (fo) |*f| {
            f.wait(self.fanout_timeout_ms);
            enrich.fanout_complete = f.allDone();
            self.metrics.observeFanout(enrich.fanout_complete);
            if (f.completed("locations")) enrich.locations = loc_task.?.out;
            if (f.completed("statistics")) enrich.statistics = stat_task.?.out;
        }
        self.metrics.observeQuery(outcome.sufficient);
        const latency_ms = timex.latencyMsF64(query_start_ns, timex.nowNanos(self.io));
        const resp = query_json.buildQueryResponse(alloc, req_id, query_text, p, outcome, enabled.len, timex.nowSeconds(self.io), decision.path.name(), latency_ms, decision.reason, enrich) catch {
            if (fo) |*f| f.joinAll();
            return error.ResponseFailed;
        };
        self.metrics.observePath(decision.path.name(), latency_ms);
        self.maybeAutotune();
        // Store a copy rendered with empty markers so a later hit
        // can splice in its own id, serving path, and latency.
        const storable = query_json.buildQueryResponse(alloc, "", query_text, p, outcome, enabled.len, timex.nowSeconds(self.io), "", 0, "", enrich) catch null;
        var tags: std.ArrayList([]const u8) = .empty;
        for (p.topics) |t| tags.append(alloc, t) catch {};
        for (p.counties) |t| tags.append(alloc, t) catch {};
        for (p.cities) |t| tags.append(alloc, t) catch {};
        return .{
            .resp = resp,
            .storable = storable,
            .path = decision.path.name(),
            .reason = decision.reason,
            .latency_ms = latency_ms,
            .sufficient = outcome.sufficient,
            .tags = tags.items,
            .fo = fo,
        };
    }

    /// Cache warming (Roadmap 6.4): at boot, run the most popular
    /// queries through the same pipeline a cache miss uses and store
    /// the answers in L1 (and L2 when Redis is present). Each query
    /// runs in its own arena; the L1 dupes the stored body into its
    /// own allocator, so the arena can be freed right after. Warming
    /// never fails the boot: every failure is logged and skipped.
    pub fn warmCache(self: *Server) void {
        const n = self.cfg.popular_warm_n;
        if (n == 0) return;
        const top_list = self.popular.top(self.alloc, n) catch {
            logging.warn("cache warming skipped: could not list popular queries", &.{});
            return;
        };
        if (top_list.len == 0) {
            logging.info("cache warming: no popular queries yet", &.{});
            return;
        }
        var enabled: std.ArrayList([]const u8) = .empty;
        defer enabled.deinit(self.alloc);
        for (sources.sources) |s| {
            if (s.enabled) enabled.append(self.alloc, s.id) catch {};
        }
        const epoch: i64 = if (self.redis) |rc| cache.currentEpoch(rc, self.alloc) else 0;
        var warmed: usize = 0;
        const start_ms = timex.nowMillis(self.io);
        for (top_list) |row| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const alloc = arena.allocator();
            var c = self.computeQuery(alloc, row.query, enabled.items, "", timex.nowNanos(self.io)) catch {
                logging.warn("cache warming: query failed, skipped", &.{.{ .key = "query", .value = row.query }});
                continue;
            };
            if (c.storable) |s| {
                if (s.len <= cache.max_response_bytes) {
                    if (self.cfg.l1_ttl_s > 0) {
                        const lk = l1cache.L1Cache.queryKey(alloc, usage.default_consumer_name, row.query, 10) catch null;
                        if (lk) |key| {
                            const before = self.l1.snapshot();
                            self.l1.put(key, s, c.tags, timex.nowMillis(self.io)) catch {};
                            const after = self.l1.snapshot();
                            self.metrics.observeL1Evictions(after.evictions - before.evictions);
                            self.metrics.setL1Stats(after.entries, after.bytes);
                        }
                    }
                    // Breaker (Roadmap 6.11): no writes to a dead
                    // Redis either; a successful put proves it alive.
                    // A dead client is reconnected first (same reason
                    // as the lookup: without it the breaker could
                    // never observe a success after Redis recovers).
                    if (self.redis) |_| {
                        const put_now_ms = timex.nowMillis(self.io);
                        if (self.redis_breaker.allow(put_now_ms)) {
                            const k = cache.cacheKey(alloc, row.query, 10) catch null;
                            if (k) |ck| {
                                if (self.redis_dead and !self.reconnectRedis()) {
                                    self.redis_breaker.recordFailure(put_now_ms);
                                } else if (self.redis) |rc| {
                                    if (cache.put(rc, alloc, ck, epoch, s, self.cfg.query_cache_ttl_s)) {
                                        self.redis_breaker.recordSuccess(put_now_ms);
                                    } else |_| {
                                        self.redis_dead = true;
                                        self.redis_breaker.recordFailure(put_now_ms);
                                    }
                                }
                            }
                        }
                    }
                    warmed += 1;
                }
            }
            if (c.fo) |*f| f.joinAll();
        }
        var qbuf: [16]u8 = undefined;
        const qstr = std.fmt.bufPrint(&qbuf, "{d}", .{warmed}) catch "?";
        var dbuf: [16]u8 = undefined;
        const dstr = std.fmt.bufPrint(&dbuf, "{d}", .{@max(0, timex.nowMillis(self.io) - start_ms)}) catch "?";
        logging.info("cache warmed", &.{ .{ .key = "queries", .value = qstr }, .{ .key = "duration_ms", .value = dstr } });
    }

    fn handleRequest(self: *Server, req: *std.http.Server.Request) !void {
        const start_ms = timex.nowMillis(self.io);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const req_id = try newRequestId(alloc, self.io);
        // Capture the head BEFORE any readBody call: std.http.Server
        // invalidates head/head_buffer pointers once the body stream is
        // initialized. Everything below uses `head`, never req.head.*.
        const head = try captureHead(req, alloc);
        const method = head.method;
        const path = head.path;

        if (method == .GET and std.mem.eql(u8, path, "/v1/health")) {
            const body = try query_json.buildHealthResponse(alloc, req_id, self.repo.countDocuments(), sources.enabledCount(), self.store_name, self.cfg.country);
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/v1/autotune")) {
            // Auto-tuning state (Roadmap 6.10): public, like /v1/health
            // — it names no secret, only the live knob values, the
            // adjustment count, and the last adjustment + reason.
            const t = &self.autotuner;
            const last = if (t.last_adjustment) |a| try std.fmt.allocPrint(alloc, "{{\"knob\":\"{s}\",\"old\":{d},\"new\":{d},\"reason\":\"{s}\"}}", .{ @tagName(a.knob), a.old_value, a.new_value, a.reason }) else "null";
            const body = try std.fmt.allocPrint(alloc, "{{\"request_id\":\"{s}\",\"enabled\":{},\"l1_ttl_s\":{d},\"fanout_timeout_ms\":{d},\"max_concurrent_sources\":{d},\"precompute_ttl_s\":{d},\"adjustments_total\":{d},\"last_adjustment\":{s}}}", .{
                req_id, t.enabled, t.l1_ttl_s, t.fanout_timeout_ms, t.max_concurrent_sources, self.cfg.precompute_ttl_s, t.adjustments_total, last,
            });
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .POST and std.mem.eql(u8, path, "/v1/admin/autotune/reset")) {
            // Manual override (Roadmap 6.10): API-key auth, no usage
            // accounting (kind null, the admin pattern). Restores the
            // configured defaults and applies them to the live knobs.
            if (!self.checkAuthAndRate(req, head, alloc, req_id, null)) return;
            var changed: std.ArrayList(autotune.Adjustment) = .empty;
            defer changed.deinit(alloc);
            self.autotuner.reset(&changed, alloc) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "reset_failed", "Failed to reset auto-tuning");
                return;
            };
            for (changed.items) |a| {
                switch (a.knob) {
                    .l1_ttl_s => self.l1.ttl_s = a.new_value,
                    .fanout_timeout_ms => self.fanout_timeout_ms = a.new_value,
                    .max_concurrent_sources => {}, // worker-side; the next worker run picks up the default.
                }
            }
            self.metrics.setAutotuneValues(self.autotuner.l1_ttl_s, self.autotuner.fanout_timeout_ms, self.autotuner.max_concurrent_sources);
            logging.info("autotune reset to configured defaults", &.{.{ .key = "changed", .value = std.fmt.allocPrint(alloc, "{d}", .{changed.items.len}) catch "?" }});
            var items: std.ArrayList(u8) = .empty;
            defer items.deinit(alloc);
            for (changed.items, 0..) |a, i| {
                if (i > 0) try items.appendSlice(alloc, ",");
                try items.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"knob\":\"{s}\",\"old\":{d},\"new\":{d}}}", .{ @tagName(a.knob), a.old_value, a.new_value }));
            }
            const body = try std.fmt.allocPrint(alloc, "{{\"request_id\":\"{s}\",\"reset\":true,\"changed\":[{s}]}}", .{ req_id, items.items });
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .POST and std.mem.eql(u8, path, "/v1/admin/config")) {
            // Hot reload for SAFE settings only (Roadmap 6.11): L1 TTL,
            // fan-out timeout, reindex interval. Secrets, auth, rate
            // limits, and retention are never accepted here — they need
            // a restart. API-key auth, no usage accounting (kind null,
            // the admin pattern). A manual value becomes the tuner's
            // new baseline, so the next auto-tuning adjustment moves
            // from it; to hold a manual value, disable autotune
            // (PULSE_AUTOTUNE=0). The reindex interval is not tuned,
            // so it holds until the next restart.
            if (!self.checkAuthAndRate(req, head, alloc, req_id, null)) return;
            const raw = readBody(req, alloc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "bad_body", "Request body required");
                return;
            };
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
                self.respondError(req, alloc, req_id, .bad_request, "bad_json", "Request body is not valid JSON");
                return;
            };
            defer parsed.deinit();
            if (parsed.value != .object) {
                self.respondError(req, alloc, req_id, .bad_request, "bad_json", "Request body must be a JSON object");
                return;
            }
            var applied: std.ArrayList(u8) = .empty;
            defer applied.deinit(alloc);
            var n_applied: usize = 0;
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                // Name the problem precisely: an unknown key is
                // unknown_setting even when its value is also the
                // wrong type — the operator's mistake is the key.
                const known = std.mem.eql(u8, key, "l1_ttl_s") or std.mem.eql(u8, key, "fanout_timeout_ms") or std.mem.eql(u8, key, "reindex_interval_s");
                if (!known) {
                    const msg = std.fmt.allocPrint(alloc, "unknown setting: {s}", .{key}) catch "unknown setting";
                    self.respondError(req, alloc, req_id, .bad_request, "unknown_setting", msg);
                    return;
                }
                if (val != .integer) {
                    self.respondError(req, alloc, req_id, .bad_request, "bad_value", "All config values must be integers");
                    return;
                }
                const v = val.integer;
                if (std.mem.eql(u8, key, "l1_ttl_s")) {
                    if (v < 60 or v > 900) {
                        self.respondError(req, alloc, req_id, .bad_request, "out_of_range", "l1_ttl_s must be 60..900");
                        return;
                    }
                    self.l1.ttl_s = @intCast(v);
                    self.autotuner.l1_ttl_s = @intCast(v);
                } else if (std.mem.eql(u8, key, "fanout_timeout_ms")) {
                    if (v < 50 or v > 500) {
                        self.respondError(req, alloc, req_id, .bad_request, "out_of_range", "fanout_timeout_ms must be 50..500");
                        return;
                    }
                    self.fanout_timeout_ms = @intCast(v);
                    self.autotuner.fanout_timeout_ms = @intCast(v);
                } else if (std.mem.eql(u8, key, "reindex_interval_s")) {
                    if (v < 60 or v > 86400) {
                        self.respondError(req, alloc, req_id, .bad_request, "out_of_range", "reindex_interval_s must be 60..86400");
                        return;
                    }
                    self.reindex_interval_s = @intCast(v);
                } else {
                    const msg = std.fmt.allocPrint(alloc, "unknown setting: {s}", .{key}) catch "unknown setting";
                    self.respondError(req, alloc, req_id, .bad_request, "unknown_setting", msg);
                    return;
                }
                if (n_applied > 0) try applied.appendSlice(alloc, ",");
                try applied.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\\"{s}\\\":{d}", .{ key, v }));
                n_applied += 1;
            }
            if (n_applied == 0) {
                self.respondError(req, alloc, req_id, .bad_request, "no_settings", "No recognised settings in body (l1_ttl_s, fanout_timeout_ms, reindex_interval_s)");
                return;
            }
            self.metrics.setAutotuneValues(self.autotuner.l1_ttl_s, self.autotuner.fanout_timeout_ms, self.autotuner.max_concurrent_sources);
            logging.info("admin config reloaded", &.{.{ .key = "applied", .value = std.fmt.allocPrint(alloc, "{d}", .{n_applied}) catch "?" }});
            const body = try std.fmt.allocPrint(alloc, "{{\\\"request_id\\\":\\\"{s}\\\",\\\"applied\\\":{{{s}}}}}", .{ req_id, applied.items });
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
                if (queryParam(head.query, "id")) |ev_id| {
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
            const q = head.query;
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
            const body = try query_json.buildTrendsResponse(alloc, req_id, now, all_trends, geo_trends, snapshots.items);
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
            // Staleness (Roadmap 6.4): the payload carries computed_at;
            // stale is evaluated at SERVE time against the precompute
            // TTL, so a cached payload served hours later is honestly
            // marked. A payload whose age cannot be read is stale.
            const stale: bool = blk: {
                const Age = struct { computed_at: i64 };
                const parsed = std.json.parseFromSlice(Age, alloc, payload, .{ .ignore_unknown_fields = true }) catch break :blk true;
                defer parsed.deinit();
                break :blk now - parsed.value.computed_at > @as(i64, @intCast(self.cfg.precompute_ttl_s));
            };
            const body = try std.fmt.allocPrint(alloc, "{{\"briefing\":{s},\"cached\":{},\"stale\":{},\"request_id\":\"{s}\"}}", .{ payload, cached_payload != null, stale, req_id });
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
                const q = head.query;
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

        if (method == .GET and std.mem.eql(u8, path, "/v1/popular")) {
            var limit: usize = 10;
            if (queryParam(head.query, "limit")) |ls| {
                limit = std.fmt.parseInt(usize, ls, 10) catch 10;
                if (limit > 50) limit = 50;
            }
            const top_list = self.popular.top(alloc, limit) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "popular_failed", "Failed to list popular searches");
                return;
            };
            const body = try query_json.buildPopularResponse(alloc, req_id, top_list, self.popular.tracked());
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, body, req_id);
            return;
        }

        if (method == .GET and std.mem.eql(u8, path, "/metrics")) {
            // Refresh the point-in-time gauges (Roadmap 6.10/6.12):
            // process RSS, the tuner's live knob values, and the
            // circuit breakers' state (Roadmap 6.11).
            self.metrics.setProcessRss(self.processRssBytes());
            self.metrics.setAutotuneValues(self.autotuner.l1_ttl_s, self.autotuner.fanout_timeout_ms, self.autotuner.max_concurrent_sources);
            if (self.embed_breaker) |eb| {
                self.metrics.setBreakerStats(breaker.stateCode(self.redis_breaker.state), self.redis_breaker.trips, self.redis_breaker.skipped_total, breaker.stateCode(eb.state), eb.trips, eb.skipped_total);
            } else {
                self.metrics.setBreakerStats(breaker.stateCode(self.redis_breaker.state), self.redis_breaker.trips, self.redis_breaker.skipped_total, 0, 0, 0);
            }
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
            if (!self.checkAuthAndRate(req, head, alloc, req_id, .query)) return;
            const query_start_ns = timex.nowNanos(self.io);
            const body = readBody(req, alloc) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Request body too large or unreadable");
                return;
            };
            const qr = query_json.parseQueryRequest(alloc, body) catch {
                self.respondError(req, alloc, req_id, .bad_request, "invalid_request", "Body must be JSON with a non-empty \"query\" string (max 1000 chars)");
                return;
            };
            // Popular searches (Roadmap 6.4): every asked query is
            // counted (text + count only, no identity). The key is
            // owned by the server allocator, never the request arena.
            // Persisted every N records so the list survives restarts.
            self.popular.record(self.alloc, qr.query) catch {};
            if (self.popular.records_since_save >= self.cfg.popular_save_every) {
                self.popular.save(self.io, self.cfg.popular_path) catch {};
                self.popular.records_since_save = 0;
            }
            var enabled: std.ArrayList([]const u8) = .empty;
            for (sources.sources) |s| {
                if (s.enabled) try enabled.append(alloc, s.id);
            }
            // Epoch-triggered index rebuild (Roadmap 6.5): worker ingests
            // bump the Redis epoch; when it moved since the index was
            // built (and the rebuild interval elapsed), rebuild from the
            // store. Bounded by the index caps; a rebuild failure keeps
            // the old index rather than failing the query.
            self.maybeRebuildIndex(alloc);
            // L1 in-process cache (Roadmap 6.2): checked first, before
            // the Redis (L2) cache. The key is consumer-scoped so a
            // cached response can never leak across consumers. A hit
            // serves the stored body with the current request id, the
            // serving path (instant), and the measured latency spliced
            // in, exactly like the L2 hit below.
            var l1_key: ?[]u8 = null;
            const l1_now = timex.nowMillis(self.io);
            if (self.cfg.l1_ttl_s > 0) {
                l1_key = l1cache.L1Cache.queryKey(alloc, consumerOf(head), qr.query, qr.limit) catch null;
                if (l1_key) |lk| {
                    if (self.l1.get(lk, l1_now)) |stored| {
                        const latency_ms = timex.latencyMsF64(query_start_ns, timex.nowNanos(self.io));
                        if (cache.stampServed(alloc, stored, req_id, "instant", latency_ms, "l1_hit") catch null) |stamped_body| {
                            self.metrics.observeL1Hit();
                            self.metrics.observeQuery(cachedSufficient(stamped_body) orelse true);
                            self.metrics.observePath("instant", latency_ms);
                            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                            self.recordUsage(head, .query);
                            self.auditCall(head, alloc, req_id, 200);
                            try respondJsonCached(req, .ok, stamped_body, req_id, true);
                            return;
                        }
                    }
                    self.metrics.observeL1Miss();
                }
            }
            // Query cache (Roadmap 4.5): an identical query+limit within
            // the TTL and the same ingest epoch serves the stored body.
            // The stored body is rendered with an empty request id; the
            // current id is spliced in on the way out. A miss, a stale
            // epoch, or a malformed entry all fall through to planning.
            var cache_key: ?[]u8 = null;
            var cache_epoch: i64 = 0;
            if (self.redis) |_| {
                if (self.cfg.query_cache_ttl_s > 0) {
                    cache_key = cache.cacheKey(alloc, qr.query, qr.limit) catch null;
                    if (cache_key) |k| {
                        // Circuit breaker (Roadmap 6.11): while open,
                        // skip the L2 lookup entirely and compute fresh
                        // — the degraded path a miss already takes. A
                        // clean answer (hit or miss) is a success for
                        // the breaker; only a Redis error counts as a
                        // failure. When the client is known dead, a
                        // fresh connect is tried first — without it the
                        // breaker could never observe a successful
                        // trial call after Redis recovers.
                        const l2_now_ms = timex.nowMillis(self.io);
                        if (self.redis_breaker.allow(l2_now_ms)) {
                            if (self.redis_dead and !self.reconnectRedis()) {
                                self.redis_breaker.recordFailure(l2_now_ms);
                            } else if (self.redis) |rc| {
                                cache_epoch = cache.currentEpoch(rc, alloc);
                                var l2_failed = false;
                                const stored = cache.get(rc, alloc, k, cache_epoch) catch blk: {
                                    l2_failed = true;
                                    break :blk null;
                                };
                                if (l2_failed) {
                                    self.redis_dead = true;
                                    self.redis_breaker.recordFailure(l2_now_ms);
                                } else {
                                    self.redis_breaker.recordSuccess(l2_now_ms);
                                }
                                if (stored) |stored_body| {
                                const latency_ms = timex.latencyMsF64(query_start_ns, timex.nowNanos(self.io));
                                if (cache.stampServed(alloc, stored_body, req_id, "instant", latency_ms, "l2_hit") catch null) |stamped_body| {
                                    self.metrics.observeCacheHit();
                                    self.metrics.observeQuery(cachedSufficient(stamped_body) orelse true);
                                    self.metrics.observePath("instant", latency_ms);
                                    self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                                    self.recordUsage(head, .query);
                                    self.auditCall(head, alloc, req_id, 200);
                                    try respondJsonCached(req, .ok, stamped_body, req_id, true);
                                    return;
                                }
                            }
                            }
                        }
                        self.metrics.observeCacheMiss();
                    }
                }
            }
            // Full pipeline (Roadmap 6.4): plan, route, index
            // shortlist, fan-out, search, render — one shared path for
            // cache misses and cache warming, so a warmed answer is
            // byte-identical to a freshly computed one. The error code
            // is preserved so callers see the same failures as before.
            var c = self.computeQuery(alloc, qr.query, enabled.items, req_id, query_start_ns) catch |e| {
                const code: []const u8 = switch (e) {
                    error.PlannerFailed => "planner_failed",
                    error.SearchFailed => "search_failed",
                    error.ResponseFailed => "response_failed",
                    else => "search_failed",
                };
                const msg: []const u8 = switch (e) {
                    error.PlannerFailed => "Query planning failed",
                    error.SearchFailed => "Search failed",
                    error.ResponseFailed => "Failed to render response",
                    else => "Search failed",
                };
                self.respondError(req, alloc, req_id, .internal_server_error, code, msg);
                return;
            };
            // Store the storable copy in L1/L2 (Roadmap 6.2/4.5).
            // Oversized responses are served but never stored. The L1
            // entry is tagged with the plan's topics/counties/cities so
            // ingest can invalidate only the affected entries (6.2).
            if (l1_key != null or cache_key != null) {
                if (c.storable) |s| {
                    if (s.len <= cache.max_response_bytes) {
                        if (l1_key) |lk| {
                            const before = self.l1.snapshot();
                            self.l1.put(lk, s, c.tags, timex.nowMillis(self.io)) catch {};
                            const after = self.l1.snapshot();
                            self.metrics.observeL1Evictions(after.evictions - before.evictions);
                            self.metrics.setL1Stats(after.entries, after.bytes);
                        }
                        if (cache_key) |k| {
                            // Breaker (Roadmap 6.11): skip the write
                            // while the Redis breaker is open; a dead
                            // client is reconnected first.
                            if (self.redis) |_| {
                                const put_now_ms = timex.nowMillis(self.io);
                                if (self.redis_breaker.allow(put_now_ms)) {
                                    if (self.redis_dead and !self.reconnectRedis()) {
                                        self.redis_breaker.recordFailure(put_now_ms);
                                    } else if (self.redis) |rc| {
                                        if (cache.put(rc, alloc, k, cache_epoch, s, self.cfg.query_cache_ttl_s)) {
                                            self.redis_breaker.recordSuccess(put_now_ms);
                                        } else |_| {
                                            self.redis_dead = true;
                                            self.redis_breaker.recordFailure(put_now_ms);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            self.recordUsage(head, .query);
            self.auditCall(head, alloc, req_id, 200);
            try respondJsonCached(req, .ok, c.resp, req_id, false);
            // Post-response join (Roadmap 6.6): straggler fan-out threads
            // finish here, after the response is sent — never before.
            if (c.fo) |*f| f.joinAll();
            return;
        }

        if (method == .POST and std.mem.eql(u8, path, "/v1/ingest")) {
            if (!self.checkAuthAndRate(req, head, alloc, req_id, .ingest)) return;
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
            // L1 invalidation (Roadmap 6.2): only entries tagged with
            // this document's topics/places recompute; everything else
            // stays hot. Never a blind flush.
            {
                var tags: std.ArrayList([]const u8) = .empty;
                for (doc.topics) |t| tags.append(alloc, t) catch {};
                for (ent.topics) |t| tags.append(alloc, t) catch {};
                for (ent.cities) |t| tags.append(alloc, t) catch {};
                for (ent.counties) |t| tags.append(alloc, t) catch {};
                const evicted = self.l1.invalidateTags(tags.items);
                self.metrics.observeL1Evictions(evicted);
                const snap = self.l1.snapshot();
                self.metrics.setL1Stats(snap.entries, snap.bytes);
                tags.deinit(alloc);
            }
            // In-memory index update (Roadmap 6.5): the new document is
            // indexed in-process so the fast path can serve it at once.
            // A failure is a warning only — the store search still finds
            // it, and the next epoch-triggered rebuild re-indexes it.
            if (self.index) |idx| {
                idx.addDocument(doc, timex.nowMillis(self.io)) catch {
                    logging.warn("memindex addDocument failed on ingest", &.{.{ .key = "doc_id", .value = doc.id }});
                };
            }
            self.metrics.setDocumentsIndexed(@intCast(self.repo.countDocuments()));
            const resp = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"source_id\":\"{s}\",\"request_id\":\"{s}\"}}", .{ doc.id, doc.source_id, req_id });
            self.metrics.observeRequest(201, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            self.recordUsage(head, .ingest);
            self.auditCall(head, alloc, req_id, 201);
            try respondJson(req, .created, resp, req_id);
            return;
        }

        // GET /v1/usage — per-consumer daily usage, quotas and remaining
        // (Roadmap 5.3). Admin scope: consumers registered without the
        // admin scope cannot read anyone's usage, including their own.
        if (method == .GET and std.mem.eql(u8, path, "/v1/usage")) {
            if (!self.checkAuthAndRate(req, head, alloc, req_id, null)) return;
            const now = timex.nowSeconds(self.io);
            const day = usage.dayOf(alloc, now) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "usage_failed", "Failed to compute the current day");
                return;
            };
            const filter = queryParam(head.query, "consumer");
            var rows: std.ArrayList(usage.UsageRow) = .empty;
            if (self.cfg.consumers.len == 0) {
                const q = self.usage_tracker.count(alloc, usage.default_consumer_name, .query, day);
                const ig = self.usage_tracker.count(alloc, usage.default_consumer_name, .ingest, day);
                const total = q + ig;
                rows.append(alloc, .{
                    .consumer = usage.default_consumer_name,
                    .queries = q,
                    .ingests = ig,
                    .quota_per_day = self.cfg.rate_limit_per_day,
                    .remaining = self.cfg.rate_limit_per_day - @min(total, self.cfg.rate_limit_per_day),
                }) catch {
                    self.respondError(req, alloc, req_id, .internal_server_error, "usage_failed", "Failed to build usage response");
                    return;
                };
            } else {
                for (self.cfg.consumers) |c| {
                    if (filter) |f| if (!std.mem.eql(u8, f, c.name)) continue;
                    const q = self.usage_tracker.count(alloc, c.name, .query, day);
                    const ig = self.usage_tracker.count(alloc, c.name, .ingest, day);
                    const quota = if (c.quota_per_day > 0) c.quota_per_day else self.cfg.rate_limit_per_day;
                    const total = q + ig;
                    rows.append(alloc, .{
                        .consumer = c.name,
                        .queries = q,
                        .ingests = ig,
                        .quota_per_day = quota,
                        .remaining = quota - @min(total, quota),
                    }) catch {
                        self.respondError(req, alloc, req_id, .internal_server_error, "usage_failed", "Failed to build usage response");
                        return;
                    };
                }
            }
            const body = query_json.buildUsageResponse(alloc, req_id, day, rows.items) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "usage_failed", "Failed to render usage response");
                return;
            };
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            self.auditCall(head, alloc, req_id, 200);
            try respondJson(req, .ok, body, req_id);
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
            const challenge = fb.handleWebhookVerification(head.query) orelse {
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
            const sig = head.webhook_sig;
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
                std.mem.eql(u8, path, "/v1/usage") or
                std.mem.eql(u8, path, "/v1/autotune") or std.mem.eql(u8, path, "/v1/admin/autotune/reset") or
                std.mem.eql(u8, path, "/v1/admin/config") or
                std.mem.eql(u8, path, "/v1/ingest")))
        {
            self.respondError(req, alloc, req_id, .method_not_allowed, "method_not_allowed", "Method not allowed on this route");
            return;
        }
        self.respondError(req, alloc, req_id, .not_found, "not_found", "No such route");
    }
};

test "fanout locationMatches matches county name, place county, and city name" {
    const loc_county = knowledge.LocationRow{ .name = "Lofa", .kind = "county" };
    try std.testing.expect(locationMatches(loc_county, &.{"Lofa"}, &.{}));
    try std.testing.expect(!locationMatches(loc_county, &.{"Nimba"}, &.{}));
    const loc_city = knowledge.LocationRow{ .name = "Monrovia", .kind = "city", .county = "Montserrado" };
    try std.testing.expect(locationMatches(loc_city, &.{"Montserrado"}, &.{}));
    try std.testing.expect(locationMatches(loc_city, &.{}, &.{"Monrovia"}));
    try std.testing.expect(!locationMatches(loc_city, &.{"Lofa"}, &.{"Gbarnga"}));
    // Case-insensitive: the plan's entities are canonical-cased, the
    // store's names are not always.
    try std.testing.expect(locationMatches(loc_city, &.{}, &.{"monrovia"}));
}

test "queryParam parses kind and limit" {
    try std.testing.expectEqualStrings("city", Server.queryParam("kind=city&limit=20", "kind").?);
    try std.testing.expectEqualStrings("20", Server.queryParam("kind=city&limit=20", "limit").?);
    try std.testing.expect(Server.queryParam("kind=city", "limit") == null);
    try std.testing.expect(Server.queryParam(null, "kind") == null);
    try std.testing.expect(Server.queryParam("kind", "kind") == null);
    try std.testing.expectEqualStrings("district", Server.queryParam("limit=5&kind=district", "kind").?);
}

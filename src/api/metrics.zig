//! Prometheus-style counters, kept in memory. No /metrics route —
//! the server reports health and results only.

const std = @import("std");

pub const Metrics = struct {
    requests_total: u64 = 0,
    requests_2xx: u64 = 0,
    requests_3xx: u64 = 0,
    requests_4xx: u64 = 0,
    requests_5xx: u64 = 0,
    request_duration_ms_total: u64 = 0,
    queries_total: u64 = 0,
    queries_insufficient_total: u64 = 0,
    queries_cache_hits_total: u64 = 0,
    queries_cache_misses_total: u64 = 0,
    /// L1 in-process cache (Roadmap 6.2). L2 is the Redis layer counted
    /// above as queries_cache_hits/misses.
    l1_cache_hits_total: u64 = 0,
    l1_cache_misses_total: u64 = 0,
    l1_cache_evictions_total: u64 = 0,
    l1_cache_entries: u64 = 0,
    l1_cache_bytes: u64 = 0,
    /// Execution-path counts and latency totals (Roadmap 6.1/6.7).
    /// Averages are derived: total / count.
    queries_path_instant_total: u64 = 0,
    queries_path_fast_total: u64 = 0,
    queries_path_deep_total: u64 = 0,
    path_latency_ms_instant_total: u64 = 0,
    path_latency_ms_fast_total: u64 = 0,
    path_latency_ms_deep_total: u64 = 0,
    /// In-memory index (Roadmap 6.3): lookups and usable shortlists.
    memindex_lookups_total: u64 = 0,
    memindex_hits_total: u64 = 0,
    ingest_runs_total: u64 = 0,
    ingest_errors_total: u64 = 0,
    documents_indexed_total: u64 = 0,
    /// Enrichment fan-out outcomes (Roadmap 6.6/6.10): how often the
    /// knowledge tasks finished before the deadline.
    fanout_total: u64 = 0,
    fanout_incomplete_total: u64 = 0,
    /// Auto-tuning (Roadmap 6.10): adjustments applied + the live
    /// knob values the tuner currently holds.
    autotune_adjustments_total: u64 = 0,
    autotune_l1_ttl_s: u64 = 0,
    autotune_fanout_timeout_ms: u64 = 0,
    autotune_max_concurrent_sources: u64 = 0,
    /// Process resident set size in bytes (Roadmap 6.10/6.12): set
    /// by the server from /proc/self/statm before rendering; 0 when
    /// the platform cannot report it.
    process_rss_bytes: u64 = 0,
    /// Circuit breakers (Roadmap 6.11): state gauges (0 closed,
    /// 1 half-open, 2 open) + trips + calls refused while open. Set
    /// by the server from the live breakers before rendering.
    breaker_redis_state: u8 = 0,
    breaker_redis_trips: u64 = 0,
    breaker_redis_skipped: u64 = 0,
    breaker_embedding_state: u8 = 0,
    breaker_embedding_trips: u64 = 0,
    breaker_embedding_skipped: u64 = 0,

    pub fn setBreakerStats(
        self: *Metrics,
        redis_state: u8,
        redis_trips: u64,
        redis_skipped: u64,
        embedding_state: u8,
        embedding_trips: u64,
        embedding_skipped: u64,
    ) void {
        self.breaker_redis_state = redis_state;
        self.breaker_redis_trips = redis_trips;
        self.breaker_redis_skipped = redis_skipped;
        self.breaker_embedding_state = embedding_state;
        self.breaker_embedding_trips = embedding_trips;
        self.breaker_embedding_skipped = embedding_skipped;
    }

    pub fn observeFanout(self: *Metrics, complete: bool) void {
        self.fanout_total += 1;
        if (!complete) self.fanout_incomplete_total += 1;
    }

    pub fn observeAutotune(self: *Metrics) void {
        self.autotune_adjustments_total += 1;
    }

    pub fn setAutotuneValues(self: *Metrics, l1_ttl_s: u64, fanout_timeout_ms: u64, max_concurrent_sources: usize) void {
        self.autotune_l1_ttl_s = l1_ttl_s;
        self.autotune_fanout_timeout_ms = fanout_timeout_ms;
        self.autotune_max_concurrent_sources = @intCast(max_concurrent_sources);
    }

    pub fn setProcessRss(self: *Metrics, bytes: u64) void {
        self.process_rss_bytes = bytes;
    }

    pub fn observeRequest(self: *Metrics, status: u16, duration_ms: u64) void {
        self.requests_total += 1;
        self.request_duration_ms_total += duration_ms;
        switch (status / 100) {
            2 => self.requests_2xx += 1,
            3 => self.requests_3xx += 1,
            4 => self.requests_4xx += 1,
            5 => self.requests_5xx += 1,
            else => {},
        }
    }

    pub fn observeQuery(self: *Metrics, sufficient: bool) void {
        self.queries_total += 1;
        if (!sufficient) self.queries_insufficient_total += 1;
    }

    pub fn observeCacheHit(self: *Metrics) void {
        self.queries_cache_hits_total += 1;
    }

    pub fn observeCacheMiss(self: *Metrics) void {
        self.queries_cache_misses_total += 1;
    }

    pub fn observeL1Hit(self: *Metrics) void {
        self.l1_cache_hits_total += 1;
    }

    pub fn observeL1Miss(self: *Metrics) void {
        self.l1_cache_misses_total += 1;
    }

    pub fn observeL1Evictions(self: *Metrics, n: u64) void {
        self.l1_cache_evictions_total += n;
    }

    pub fn setL1Stats(self: *Metrics, entries: u64, bytes: u64) void {
        self.l1_cache_entries = entries;
        self.l1_cache_bytes = bytes;
    }

    /// Record a query served on an execution path (Roadmap 6.1/6.7).
    /// `latency_ms` is the measured server-side latency, truncated to
    /// whole milliseconds for the counter (the response carries the
    /// fractional value).
    pub fn observePath(self: *Metrics, path: []const u8, latency_ms: f64) void {
        const whole: u64 = @intFromFloat(@max(0, latency_ms));
        if (std.mem.eql(u8, path, "instant")) {
            self.queries_path_instant_total += 1;
            self.path_latency_ms_instant_total += whole;
        } else if (std.mem.eql(u8, path, "deep")) {
            self.queries_path_deep_total += 1;
            self.path_latency_ms_deep_total += whole;
        } else {
            self.queries_path_fast_total += 1;
            self.path_latency_ms_fast_total += whole;
        }
    }

    pub fn observeMemindexLookup(self: *Metrics) void {
        self.memindex_lookups_total += 1;
    }

    pub fn observeMemindexHit(self: *Metrics) void {
        self.memindex_hits_total += 1;
    }

    pub fn observeIngestRun(self: *Metrics, had_error: bool) void {
        self.ingest_runs_total += 1;
        if (had_error) self.ingest_errors_total += 1;
    }

    pub fn setDocumentsIndexed(self: *Metrics, n: u64) void {
        self.documents_indexed_total = n;
    }

    pub fn render(self: *const Metrics, alloc: std.mem.Allocator) ![]u8 {
        const base = try std.fmt.allocPrint(alloc,
            \\# HELP pulse_http_requests_total Total HTTP requests handled
            \\# TYPE pulse_http_requests_total counter
            \\pulse_http_requests_total {d}
            \\# HELP pulse_http_requests_2xx_total HTTP 2xx responses
            \\# TYPE pulse_http_requests_2xx_total counter
            \\pulse_http_requests_2xx_total {d}
            \\# HELP pulse_http_requests_3xx_total HTTP 3xx responses
            \\# TYPE pulse_http_requests_3xx_total counter
            \\pulse_http_requests_3xx_total {d}
            \\# HELP pulse_http_requests_4xx_total HTTP 4xx responses
            \\# TYPE pulse_http_requests_4xx_total counter
            \\pulse_http_requests_4xx_total {d}
            \\# HELP pulse_http_requests_5xx_total HTTP 5xx responses
            \\# TYPE pulse_http_requests_5xx_total counter
            \\pulse_http_requests_5xx_total {d}
            \\# HELP pulse_http_request_duration_ms_total Total request latency in milliseconds
            \\# TYPE pulse_http_request_duration_ms_total counter
            \\pulse_http_request_duration_ms_total {d}
            \\# HELP pulse_queries_total Total /v1/query requests
            \\# TYPE pulse_queries_total counter
            \\pulse_queries_total {d}
            \\# HELP pulse_queries_insufficient_evidence_total Queries answered with insufficient evidence
            \\# TYPE pulse_queries_insufficient_evidence_total counter
            \\pulse_queries_insufficient_evidence_total {d}
            \\# HELP pulse_queries_cache_hits_total /v1/query responses served from the Redis cache
            \\# TYPE pulse_queries_cache_hits_total counter
            \\pulse_queries_cache_hits_total {d}
            \\# HELP pulse_queries_cache_misses_total /v1/query cache lookups that recomputed
            \\# TYPE pulse_queries_cache_misses_total counter
            \\pulse_queries_cache_misses_total {d}
            \\# HELP pulse_l1_cache_hits_total /v1/query responses served from the in-process L1 cache
            \\# TYPE pulse_l1_cache_hits_total counter
            \\pulse_l1_cache_hits_total {d}
            \\# HELP pulse_l1_cache_misses_total L1 cache lookups that missed
            \\# TYPE pulse_l1_cache_misses_total counter
            \\pulse_l1_cache_misses_total {d}
            \\# HELP pulse_l1_cache_evictions_total L1 entries evicted (count or byte cap)
            \\# TYPE pulse_l1_cache_evictions_total counter
            \\pulse_l1_cache_evictions_total {d}
            \\# HELP pulse_l1_cache_entries L1 entries currently held
            \\# TYPE pulse_l1_cache_entries gauge
            \\pulse_l1_cache_entries {d}
            \\# HELP pulse_l1_cache_bytes L1 bytes currently held
            \\# TYPE pulse_l1_cache_bytes gauge
            \\pulse_l1_cache_bytes {d}
            \\# HELP pulse_queries_path_instant_total Queries served on the instant path (L1 / precomputed)
            \\# TYPE pulse_queries_path_instant_total counter
            \\pulse_queries_path_instant_total {d}
            \\# HELP pulse_queries_path_fast_total Queries served on the fast path (indexed search)
            \\# TYPE pulse_queries_path_fast_total counter
            \\pulse_queries_path_fast_total {d}
            \\# HELP pulse_queries_path_deep_total Queries served on the deep path (semantic / correlation)
            \\# TYPE pulse_queries_path_deep_total counter
            \\pulse_queries_path_deep_total {d}
            \\# HELP pulse_path_latency_ms_instant_total Total instant-path latency in milliseconds
            \\# TYPE pulse_path_latency_ms_instant_total counter
            \\pulse_path_latency_ms_instant_total {d}
            \\# HELP pulse_path_latency_ms_fast_total Total fast-path latency in milliseconds
            \\# TYPE pulse_path_latency_ms_fast_total counter
            \\pulse_path_latency_ms_fast_total {d}
            \\# HELP pulse_path_latency_ms_deep_total Total deep-path latency in milliseconds
            \\# TYPE pulse_path_latency_ms_deep_total counter
            \\pulse_path_latency_ms_deep_total {d}
            \\# HELP pulse_memindex_lookups_total In-memory index lookups on the fast path
            \\# TYPE pulse_memindex_lookups_total counter
            \\pulse_memindex_lookups_total {d}
            \\# HELP pulse_memindex_hits_total Index lookups that returned enough candidates to rank
            \\# TYPE pulse_memindex_hits_total counter
            \\pulse_memindex_hits_total {d}
            \\# HELP pulse_ingest_runs_total Ingestion runs completed
            \\# TYPE pulse_ingest_runs_total counter
            \\pulse_ingest_runs_total {d}
            \\# HELP pulse_ingest_errors_total Ingestion runs with at least one source error
            \\# TYPE pulse_ingest_errors_total counter
            \\pulse_ingest_errors_total {d}
            \\# HELP pulse_documents_indexed_total Documents currently indexed
            \\# TYPE pulse_documents_indexed_total gauge
            \\pulse_documents_indexed_total {d}
            \\
        , .{
            self.requests_total,
            self.requests_2xx,
            self.requests_3xx,
            self.requests_4xx,
            self.requests_5xx,
            self.request_duration_ms_total,
            self.queries_total,
            self.queries_insufficient_total,
            self.queries_cache_hits_total,
            self.queries_cache_misses_total,
            self.l1_cache_hits_total,
            self.l1_cache_misses_total,
            self.l1_cache_evictions_total,
            self.l1_cache_entries,
            self.l1_cache_bytes,
            self.queries_path_instant_total,
            self.queries_path_fast_total,
            self.queries_path_deep_total,
            self.path_latency_ms_instant_total,
            self.path_latency_ms_fast_total,
            self.path_latency_ms_deep_total,
            self.memindex_lookups_total,
            self.memindex_hits_total,
            self.ingest_runs_total,
            self.ingest_errors_total,
            self.documents_indexed_total,
        });
        // Second format call (Roadmap 6.10): std.fmt caps one call at
        // 32 arguments, and the base block already uses 27.
        const extra = try std.fmt.allocPrint(alloc,
            \\# HELP pulse_fanout_total Enrichment fan-outs run
            \\# TYPE pulse_fanout_total counter
            \\pulse_fanout_total {d}
            \\# HELP pulse_fanout_incomplete_total Fan-outs with a task still running at the deadline
            \\# TYPE pulse_fanout_incomplete_total counter
            \\pulse_fanout_incomplete_total {d}
            \\# HELP pulse_autotune_adjustments_total Auto-tuning adjustments applied
            \\# TYPE pulse_autotune_adjustments_total counter
            \\pulse_autotune_adjustments_total {d}
            \\# HELP pulse_autotune_l1_ttl_seconds L1 TTL currently held by the tuner
            \\# TYPE pulse_autotune_l1_ttl_seconds gauge
            \\pulse_autotune_l1_ttl_seconds {d}
            \\# HELP pulse_autotune_fanout_timeout_ms Fan-out deadline currently held by the tuner
            \\# TYPE pulse_autotune_fanout_timeout_ms gauge
            \\pulse_autotune_fanout_timeout_ms {d}
            \\# HELP pulse_autotune_max_concurrent_sources Max concurrent sources currently held by the tuner
            \\# TYPE pulse_autotune_max_concurrent_sources gauge
            \\pulse_autotune_max_concurrent_sources {d}
            \\# HELP pulse_process_rss_bytes Process resident set size in bytes (0 when unreported)
            \\# TYPE pulse_process_rss_bytes gauge
            \\pulse_process_rss_bytes {d}
            \\
        , .{
            self.fanout_total,
            self.fanout_incomplete_total,
            self.autotune_adjustments_total,
            self.autotune_l1_ttl_s,
            self.autotune_fanout_timeout_ms,
            self.autotune_max_concurrent_sources,
            self.process_rss_bytes,
        });
        defer alloc.free(extra);
        // Third format call (Roadmap 6.11): breaker state + trips +
        // skipped calls, same 32-argument cap reason as above.
        const breakers = try std.fmt.allocPrint(alloc,
            \\# HELP pulse_breaker_redis_state Circuit breaker state for the Redis L2 cache (0 closed, 1 half-open, 2 open)
            \\# TYPE pulse_breaker_redis_state gauge
            \\pulse_breaker_redis_state {d}
            \\# HELP pulse_breaker_redis_trips_total Times the Redis breaker tripped open
            \\# TYPE pulse_breaker_redis_trips_total counter
            \\pulse_breaker_redis_trips_total {d}
            \\# HELP pulse_breaker_redis_skipped_total L2 lookups refused while the Redis breaker was open
            \\# TYPE pulse_breaker_redis_skipped_total counter
            \\pulse_breaker_redis_skipped_total {d}
            \\# HELP pulse_breaker_embedding_state Circuit breaker state for the external embedder (0 closed, 1 half-open, 2 open)
            \\# TYPE pulse_breaker_embedding_state gauge
            \\pulse_breaker_embedding_state {d}
            \\# HELP pulse_breaker_embedding_trips_total Times the embedding breaker tripped open
            \\# TYPE pulse_breaker_embedding_trips_total counter
            \\pulse_breaker_embedding_trips_total {d}
            \\# HELP pulse_breaker_embedding_skipped_total Embed calls refused while the embedding breaker was open
            \\# TYPE pulse_breaker_embedding_skipped_total counter
            \\pulse_breaker_embedding_skipped_total {d}
            \\
        , .{
            self.breaker_redis_state,
            self.breaker_redis_trips,
            self.breaker_redis_skipped,
            self.breaker_embedding_state,
            self.breaker_embedding_trips,
            self.breaker_embedding_skipped,
        });
        defer alloc.free(breakers);
        defer alloc.free(base);
        return std.mem.concat(alloc, u8, &.{ base, extra, breakers });
    }
};

test "metrics render contains all series" {
    var m = Metrics{};
    m.observeRequest(200, 12);
    m.observeRequest(404, 3);
    m.observeRequest(500, 100);
    m.observeQuery(true);
    m.observeQuery(false);
    m.observeIngestRun(false);
    m.observeIngestRun(true);
    m.setDocumentsIndexed(50);
    const text = try m.render(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_http_requests_total 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_http_requests_2xx_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_http_requests_4xx_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_http_requests_5xx_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_http_request_duration_ms_total 115") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_queries_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_queries_insufficient_evidence_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_ingest_runs_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_ingest_errors_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pulse_documents_indexed_total 50") != null);
}

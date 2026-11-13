//! Prometheus metrics (Roadmap 1.5): counters rendered as exposition text
//! on GET /metrics. Single-threaded in Phase 1; no internal locking.

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
    ingest_runs_total: u64 = 0,
    ingest_errors_total: u64 = 0,
    documents_indexed_total: u64 = 0,

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

    pub fn observeIngestRun(self: *Metrics, had_error: bool) void {
        self.ingest_runs_total += 1;
        if (had_error) self.ingest_errors_total += 1;
    }

    pub fn setDocumentsIndexed(self: *Metrics, n: u64) void {
        self.documents_indexed_total = n;
    }

    pub fn render(self: *const Metrics, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc,
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
            self.ingest_runs_total,
            self.ingest_errors_total,
            self.documents_indexed_total,
        });
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

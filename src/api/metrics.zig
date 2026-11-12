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

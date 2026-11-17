//! SearXNG web-search client (web search for Pulse).
//!
//! Pulse's own search only covers the documents its worker ingested from
//! the registered RSS feeds. This client asks a self-hosted SearXNG
//! instance for real web search: one GET to
//! `{base}/search?q=<query>&format=json&language=en`, which returns the
//! upstream engines' results as JSON (`title`, `url`, `content`,
//! `engine` per result, plus `unresponsive_engines`). Results are
//! returned as-is — no ranking, no verdict, no invented fields. An
//! empty result list is a valid answer, never an error.
//!
//! Transport: std.http.Client only (same pattern as the Sando reference
//! client in src/sando/client.zig). The client is constructed WITHOUT
//! proxy env vars, so an internal base URL (searxng:8080 on the compose
//! network, 127.0.0.1:8080 on a dev host) is reached directly. No
//! `Connection: close` header is sent. Honest limits, shared with the
//! Sando client: Zig 0.17.1's `std.http.Client.fetch` exposes NO
//! per-request timeout and NO max-response-size option, so a dead or
//! runaway SearXNG can stall one call — the endpoint measures `took_ms`
//! so a stuck upstream is visible in the response and the logs.
//!
//! Configuration: `PULSE_SEARXNG_URL` (e.g. http://searxng:8080).
//! Unset = web search unavailable (the endpoint answers 503
//! `websearch_unavailable`; the CLI refuses to run). SearXNG itself
//! needs `json` in `search.formats` in its settings.yml — without it
//! the JSON request answers 403, which this client reports as
//! `error.BadResponse` with a log line naming the setting.

const std = @import("std");
const timex = @import("../common/time.zig");
const logging = @import("../common/logging.zig");

/// Default results per call (mirrors /v1/query's default limit).
pub const default_count: usize = 10;
/// Hard cap, same range as /v1/query's limit (1..20).
pub const max_count: usize = 20;
/// SearXNG answers one page at a time; the default page is 10 results.
/// Asking for more than a page still returns at most one page.
pub const page_size: usize = 10;

/// One web result, exactly as SearXNG reported it. All strings are
/// owned by the allocator passed to `search`.
pub const WebResult = struct {
    title: []const u8,
    url: []const u8,
    content: []const u8,
    engine: []const u8,
};

/// The typed answer. `unresponsive_engines` names the upstream engines
/// that failed for this query (SearXNG reports them; empty is normal).
pub const WebSearchResponse = struct {
    query: []const u8,
    results: []WebResult,
    unresponsive_engines: [][]const u8,
    took_ms: u64,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    /// Attempts per query: 1 initial + retries on transport errors and
    /// 5xx only. 4xx (our request is wrong) is never retried.
    max_attempts: u8 = 2,

    /// Search the web through SearXNG. Returns typed results, or:
    /// - `InvalidQuery`: empty query or longer than 1000 chars.
    /// - `Unavailable`: transport failure or 5xx after all retries.
    /// - `BadResponse`: non-200 status that is not a 5xx (e.g. 403
    ///   when `json` is missing from SearXNG's `search.formats`), or
    ///   a 200 body that does not parse as SearXNG JSON.
    pub fn search(self: *Client, alloc: std.mem.Allocator, query: []const u8, count: usize) error{ InvalidQuery, Unavailable, BadResponse, OutOfMemory }!WebSearchResponse {
        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (trimmed.len == 0 or trimmed.len > 1000) return error.InvalidQuery;
        const want = @min(@max(count, 1), max_count);

        const enc = urlEncode(alloc, trimmed) catch return error.OutOfMemory;
        defer alloc.free(enc);
        const url = std.fmt.allocPrint(alloc, "{s}/search?q={s}&format=json&language=en", .{ std.mem.trimEnd(u8, self.base_url, "/"), enc }) catch return error.OutOfMemory;
        defer alloc.free(url);

        const start_ms = timex.nowMillis(self.io);
        var attempt: u8 = 0;
        while (true) {
            attempt += 1;
            const res = self.getOnce(alloc, url) catch |e| {
                logging.warn("searxng client: request failed", &.{ .{ .key = "error", .value = @errorName(e) } });
                if (attempt >= self.max_attempts) return error.Unavailable;
                std.Io.sleep(self.io, .{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            };
            switch (res.status) {
                .ok => {
                    defer alloc.free(res.body);
                    return parseResponse(alloc, res.body, trimmed, want, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
                },
                .forbidden => {
                    alloc.free(res.body);
                    logging.warn("searxng client: 403 — is `json` in search.formats in the SearXNG settings.yml?", &.{});
                    return error.BadResponse;
                },
                .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => {
                    alloc.free(res.body);
                    if (attempt >= self.max_attempts) return error.Unavailable;
                    std.Io.sleep(self.io, .{ .nanoseconds = @intCast(@as(u64, attempt) * 250 * std.time.ns_per_ms) }, .awake) catch {};
                    continue;
                },
                else => {
                    logging.warn("searxng client: unexpected status", &.{ .{ .key = "status", .value = @tagName(res.status) } });
                    alloc.free(res.body);
                    return error.BadResponse;
                },
            }
        }
    }

    const GetResult = struct {
        status: std.http.Status,
        body: []u8,
    };

    fn getOnce(self: *Client, alloc: std.mem.Allocator, url: []const u8) !GetResult {
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        var resp_body: std.Io.Writer.Allocating = .init(alloc);
        errdefer resp_body.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "user-agent", .value = "SandoPulse/0.1 (websearch)" },
            },
            .response_writer = &resp_body.writer,
        });
        return .{ .status = result.status, .body = try resp_body.toOwnedSlice() };
    }
};

/// Percent-encode a query value. Unreserved [A-Za-z0-9-_.~] pass
/// through; everything else becomes %XX. (Same rules as the Facebook
/// connector's urlEncode.)
pub fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (ok) {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[c >> 4]);
            try out.append(alloc, hex[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(alloc);
}

const RawResult = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    content: []const u8 = "",
    engine: []const u8 = "",
};

const RawResponse = struct {
    results: []RawResult = &.{},
    unresponsive_engines: [][]const u8 = &.{},
};

/// Parse one SearXNG JSON page into owned results, truncated to
/// `count`. Entries with no URL are dropped (a result that cannot be
/// cited is not a result); everything else is kept verbatim.
fn parseResponse(alloc: std.mem.Allocator, body: []const u8, query: []const u8, count: usize, took_ms: u64) !WebSearchResponse {
    // Non-leaky parse: its internal arena (freed by the defer) owns the
    // raw slices, so a malformed body cannot leak the partial
    // allocations parseFromSliceLeaky would leave behind. The returned
    // strings are duped into `alloc` below, so they outlive the arena.
    var parsed = std.json.parseFromSlice(RawResponse, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    defer parsed.deinit();
    const doc = parsed.value;
    var out: std.ArrayList(WebResult) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.title);
            alloc.free(r.url);
            alloc.free(r.content);
            alloc.free(r.engine);
        }
        out.deinit(alloc);
    }
    for (doc.results) |r| {
        if (out.items.len >= count) break;
        if (r.url.len == 0) continue;
        try out.append(alloc, .{
            .title = try alloc.dupe(u8, r.title),
            .url = try alloc.dupe(u8, r.url),
            .content = try alloc.dupe(u8, r.content),
            .engine = try alloc.dupe(u8, r.engine),
        });
    }
    var engines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (engines.items) |e| alloc.free(e);
        engines.deinit(alloc);
    }
    for (doc.unresponsive_engines) |e| {
        try engines.append(alloc, try alloc.dupe(u8, e));
    }
    const owned_query = try alloc.dupe(u8, query);
    errdefer alloc.free(owned_query);
    return .{
        .query = owned_query,
        .results = try out.toOwnedSlice(alloc),
        .unresponsive_engines = try engines.toOwnedSlice(alloc),
        .took_ms = took_ms,
    };
}

/// Free a response previously returned by `Client.search`.
pub fn freeResponse(alloc: std.mem.Allocator, res: WebSearchResponse) void {
    alloc.free(res.query);
    for (res.results) |r| {
        alloc.free(r.title);
        alloc.free(r.url);
        alloc.free(r.content);
        alloc.free(r.engine);
    }
    alloc.free(res.results);
    for (res.unresponsive_engines) |e| alloc.free(e);
    alloc.free(res.unresponsive_engines);
}

test "searxng: urlEncode leaves unreserved chars and escapes the rest" {
    const alloc = std.testing.allocator;
    const enc = try urlEncode(alloc, "Liberia news today!");
    defer alloc.free(enc);
    try std.testing.expectEqualStrings("Liberia%20news%20today%21", enc);
    const plain = try urlEncode(alloc, "abc-XYZ_012.~");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("abc-XYZ_012.~", plain);
    const empty = try urlEncode(alloc, "");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "searxng: parseResponse keeps results verbatim and reports dead engines" {
    const alloc = std.testing.allocator;
    const body =
        \\{"query":"Liberia news","number_of_results":2,"results":[{"url":"https://example.com/a","title":"Liberia elects","content":"Monrovia votes.","engine":"bing","score":1.0},{"url":"https://example.com/b","title":"Fuel queues","content":"","engine":"duckduckgo"}],"unresponsive_engines":["google"],"answers":{}}
    ;
    const res = try parseResponse(alloc, body, "Liberia news", 10, 42);
    defer freeResponse(alloc, res);
    try std.testing.expectEqual(@as(usize, 2), res.results.len);
    try std.testing.expectEqualStrings("Liberia elects", res.results[0].title);
    try std.testing.expectEqualStrings("https://example.com/a", res.results[0].url);
    try std.testing.expectEqualStrings("Monrovia votes.", res.results[0].content);
    try std.testing.expectEqualStrings("bing", res.results[0].engine);
    try std.testing.expectEqualStrings("Liberia news", res.query);
    try std.testing.expectEqual(@as(u64, 42), res.took_ms);
    try std.testing.expectEqualStrings("", res.results[1].content);
    try std.testing.expectEqual(@as(usize, 1), res.unresponsive_engines.len);
    try std.testing.expectEqualStrings("google", res.unresponsive_engines[0]);
}

test "searxng: parseResponse truncates to count and drops URL-less entries" {
    const alloc = std.testing.allocator;
    const body =
        \\{"query":"x","results":[{"url":"https://a.example","title":"A","content":"","engine":"e1"},{"url":"","title":"no link","content":"","engine":"e2"},{"url":"https://b.example","title":"B","content":"","engine":"e3"},{"url":"https://c.example","title":"C","content":"","engine":"e4"}],"unresponsive_engines":[]}
    ;
    const res = try parseResponse(alloc, body, "x", 2, 7);
    defer freeResponse(alloc, res);
    try std.testing.expectEqual(@as(usize, 2), res.results.len);
    try std.testing.expectEqualStrings("https://a.example", res.results[0].url);
    try std.testing.expectEqualStrings("https://b.example", res.results[1].url);
}

test "searxng: parseResponse accepts an empty result list" {
    const alloc = std.testing.allocator;
    const body = \\{"query":"qqqzzz","number_of_results":0,"results":[],"unresponsive_engines":[]}
    ;
    const res = try parseResponse(alloc, body, "Liberia news", 10, 42);
    defer freeResponse(alloc, res);
    try std.testing.expectEqual(@as(usize, 0), res.results.len);
    try std.testing.expectEqual(@as(usize, 0), res.unresponsive_engines.len);
}

test "searxng: parseResponse rejects malformed JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BadResponse, parseResponse(alloc, "not json", "q", 10, 0));
    try std.testing.expectError(error.BadResponse, parseResponse(alloc, "{\"results\": \"nope\"}", "q", 10, 0));
    try std.testing.expectError(error.BadResponse, parseResponse(alloc, "{\"results\": [{\"url\": 42}]}", "q", 10, 0));
}

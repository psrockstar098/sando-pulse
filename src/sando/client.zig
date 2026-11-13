//! Reference Pulse client for Sando (Roadmap 5.2, Pulse side only).
//!
//! Sando calls Pulse's POST /v1/query and gets back a typed answer with
//! citations and a confidence score. The client never invents content:
//! when Pulse is unreachable, returns 5xx, or the response cannot be
//! parsed, `ask` returns a typed error (`error.PulseUnavailable` and
//! friends) — Sando must show "I couldn't reach the news service" and
//! never a fabricated answer. An insufficient answer
//! (`sufficient == false`) is a VALID response, not an error: it means
//! Pulse has no evidence, and Sando should say so.
//!
//! Context: a county is folded into the query text
//! ("<question> (in Montserrado county)") because the planner extracts
//! counties from the query text; the raw `context` object is also sent
//! for forward compatibility (the server ignores unknown fields today).
//! `language` (e.g. "koloqua") is informational only — it travels in
//! `context` so a future server version can use it.
//!
//! Timeout: Zig 0.17.1's `std.http.Client.fetch` exposes NO per-request
//! timeout, so this client cannot enforce one. If Sando needs a hard
//! bound, run `ask` on a worker thread with a watchdog. Retries cover
//! transport errors, 5xx and 429 with linear backoff (250ms x attempt).
//! 4xx responses (bad key, unknown consumer, bad question) are not
//! retried — retrying them would only burn quota.

const std = @import("std");
const logging = @import("../common/logging.zig");

pub const default_base_url = "http://127.0.0.1:9000";
pub const default_consumer = "sando";

pub const SandoContext = struct {
    county: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

pub const Citation = struct {
    title: []const u8,
    url: []const u8,
    source_name: []const u8,
};

/// The typed answer Sando renders. All strings are owned by the
/// allocator passed to `ask`.
pub const SandoAnswer = struct {
    query: []const u8,
    sufficient: bool,
    answer: ?[]const u8,
    confidence: f64,
    citations: []Citation,
    insufficient_reason: ?[]const u8,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8 = default_base_url,
    /// Null in open dev mode (no PULSE_API_KEY) — the Authorization
    /// header is then omitted entirely.
    api_key: ?[]const u8 = null,
    consumer: []const u8 = default_consumer,
    /// Query results requested per call (1..20, server-enforced).
    limit: usize = 5,
    /// Attempts per question: 1 initial + retries on transport/5xx/429.
    max_attempts: u8 = 3,

    /// Ask Pulse one question. Returns a typed answer, or a typed error:
    /// - `PulseUnavailable`: transport failure or 5xx after all retries.
    /// - `Unauthorized`: 401 (bad or missing API key).
    /// - `QuotaExceeded`: 429 after all retries (daily quota spent).
    /// - `InvalidQuestion`: empty question or longer than 1000 chars.
    /// - `BadResponse`: 200 with a body that does not parse.
    pub fn ask(self: *Client, alloc: std.mem.Allocator, question: []const u8, ctx: SandoContext) error{ PulseUnavailable, Unauthorized, QuotaExceeded, InvalidQuestion, BadResponse, OutOfMemory }!SandoAnswer {
        const trimmed = std.mem.trim(u8, question, " \t\n\r");
        if (trimmed.len == 0 or trimmed.len > 1000) return error.InvalidQuestion;

        // Fold county context into the query text so the planner sees it.
        const folded = if (ctx.county) |county|
            std.fmt.allocPrint(alloc, "{s} (in {s} county)", .{ trimmed, county }) catch return error.OutOfMemory
        else
            alloc.dupe(u8, trimmed) catch return error.OutOfMemory;
        defer alloc.free(folded);

        const body = self.renderRequest(alloc, folded, ctx) catch return error.OutOfMemory;
        defer alloc.free(body);

        const url = std.fmt.allocPrint(alloc, "{s}/v1/query", .{std.mem.trimEnd(u8, self.base_url, "/")}) catch return error.OutOfMemory;
        defer alloc.free(url);

        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(alloc);
        if (self.api_key) |k| {
            const auth_header = std.fmt.allocPrint(alloc, "Bearer {s}", .{k}) catch return error.OutOfMemory;
            headers.append(alloc, .{ .name = "authorization", .value = auth_header }) catch return error.OutOfMemory;
        }
        headers.append(alloc, .{ .name = "x-pulse-consumer", .value = self.consumer }) catch return error.OutOfMemory;
        headers.append(alloc, .{ .name = "content-type", .value = "application/json" }) catch return error.OutOfMemory;
        headers.append(alloc, .{ .name = "accept", .value = "application/json" }) catch return error.OutOfMemory;

        var attempt: u8 = 0;
        while (true) {
            attempt += 1;
            const res = self.postOnce(alloc, url, body, headers.items) catch |e| {
                logging.warn("sando client: request failed", &.{ .{ .key = "error", .value = @errorName(e) } });
                if (attempt >= self.max_attempts) return error.PulseUnavailable;
                std.Io.sleep(self.io, .{ .nanoseconds = @intCast(@as(u64, attempt) * 250 * std.time.ns_per_ms) }, .awake) catch {};
                continue;
            };
            switch (res.status) {
                .ok => {
                    defer alloc.free(res.body);
                    return parseAnswer(alloc, res.body) catch return error.BadResponse;
                },
                .unauthorized => {
                    alloc.free(res.body);
                    return error.Unauthorized;
                },
                .too_many_requests => {
                    alloc.free(res.body);
                    if (attempt >= self.max_attempts) return error.QuotaExceeded;
                    std.Io.sleep(self.io, .{ .nanoseconds = @intCast(@as(u64, attempt) * 250 * std.time.ns_per_ms) }, .awake) catch {};
                    continue;
                },
                .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => {
                    alloc.free(res.body);
                    if (attempt >= self.max_attempts) return error.PulseUnavailable;
                    std.Io.sleep(self.io, .{ .nanoseconds = @intCast(@as(u64, attempt) * 250 * std.time.ns_per_ms) }, .awake) catch {};
                    continue;
                },
                else => {
                    // 400/403/404/405: our request is wrong; retrying
                    // only burns quota. Surface as unavailable with the
                    // status in the log — Sando shows its fallback text.
                    logging.warn("sando client: unexpected status", &.{ .{ .key = "status", .value = @tagName(res.status) } });
                    alloc.free(res.body);
                    return error.PulseUnavailable;
                },
            }
        }
    }

    const PostResult = struct {
        status: std.http.Status,
        body: []u8,
    };

    fn postOnce(self: *Client, alloc: std.mem.Allocator, url: []const u8, body: []const u8, headers: []const std.http.Header) !PostResult {
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        var resp_body: std.Io.Writer.Allocating = .init(alloc);
        errdefer resp_body.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = headers,
            .response_writer = &resp_body.writer,
        });
        return .{ .status = result.status, .body = try resp_body.toOwnedSlice() };
    }

    fn renderRequest(self: *Client, alloc: std.mem.Allocator, folded: []const u8, ctx: SandoContext) ![]u8 {
        return std.json.Stringify.valueAlloc(alloc, .{
            .query = folded,
            .options = .{ .limit = self.limit },
            .context = .{
                .county = ctx.county,
                .language = ctx.language,
            },
        }, .{});
    }
};

const ResponseResult = struct {
    title: []const u8,
    url: []const u8,
    source: struct {
        name: []const u8,
        url: []const u8,
    },
};

const ResponseBody = struct {
    query: []const u8 = "",
    answer: ?[]const u8 = null,
    sufficient: bool = false,
    insufficient_reason: ?[]const u8 = null,
    confidence: f64 = 0,
    results: []ResponseResult = &.{},
};

fn parseAnswer(alloc: std.mem.Allocator, body: []const u8) !SandoAnswer {
    const parsed = std.json.parseFromSliceLeaky(ResponseBody, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    // The results array is heap-owned by the parser (its strings point
    // into `body`); free it once the citations are duped below.
    defer alloc.free(parsed.results);
    var citations: std.ArrayList(Citation) = .empty;
    for (parsed.results) |r| {
        try citations.append(alloc, .{
            .title = try alloc.dupe(u8, r.title),
            .url = try alloc.dupe(u8, r.url),
            .source_name = try alloc.dupe(u8, r.source.name),
        });
    }
    return .{
        .query = try alloc.dupe(u8, parsed.query),
        .sufficient = parsed.sufficient,
        .answer = if (parsed.answer) |a| try alloc.dupe(u8, a) else null,
        .confidence = parsed.confidence,
        .citations = try citations.toOwnedSlice(alloc),
        .insufficient_reason = if (parsed.insufficient_reason) |r| try alloc.dupe(u8, r) else null,
    };
}

test "sando client: parseAnswer keeps citations and refusal" {
    const alloc = std.testing.allocator;
    const body =
        \\{"query":"fuel shortage in Monrovia","answer":"Fuel is short.","sufficient":true,"confidence":0.65,"results":[{"title":"Fuel queues grow","url":"https://example.com/a","source":{"name":"Daily Observer","url":"https://example.com"}}],"events":[],"timeline":[],"query_plan":{},"meta":{}}
    ;
    const ans = try parseAnswer(alloc, body);
    defer {
        alloc.free(ans.query);
        if (ans.answer) |a| alloc.free(a);
        for (ans.citations) |c| {
            alloc.free(c.title);
            alloc.free(c.url);
            alloc.free(c.source_name);
        }
        alloc.free(ans.citations);
    }
    try std.testing.expect(ans.sufficient);
    try std.testing.expectEqualStrings("Fuel is short.", ans.answer.?);
    try std.testing.expectEqual(@as(usize, 1), ans.citations.len);
    try std.testing.expectEqualStrings("Daily Observer", ans.citations[0].source_name);

    const refused =
        \\{"query":"quantum computing in Lofa","answer":null,"sufficient":false,"insufficient_reason":"no_documents_matched","confidence":0,"results":[],"events":[],"timeline":[],"query_plan":{},"meta":{}}
    ;
    const ans2 = try parseAnswer(alloc, refused);
    defer {
        alloc.free(ans2.query);
        alloc.free(ans2.citations);
        if (ans2.insufficient_reason) |r| alloc.free(r);
    }
    try std.testing.expect(!ans2.sufficient);
    try std.testing.expectEqualStrings("no_documents_matched", ans2.insufficient_reason.?);
    try std.testing.expectEqual(@as(usize, 0), ans2.citations.len);
}

test "sando client: parseAnswer rejects garbage" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BadResponse, parseAnswer(alloc, "not json"));
    try std.testing.expectError(error.BadResponse, parseAnswer(alloc, "{\"sufficient\": \"yes\"}"));
}

//! HTTP server (Roadmap 1.2): std.http.Server ONLY — no external framework.
//! Single-threaded accept loop; one arena allocator per request.
//! Routes:
//!   GET  /v1/health   public — liveness + index size
//!   GET  /v1/sources  public — source registry + per-source doc counts
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
const planner = @import("../engine/planner.zig");
const search = @import("../engine/search.zig");
const entities = @import("../engine/entities.zig");
const sources = @import("../ingestion/sources.zig");
const pipeline = @import("../ingestion/pipeline.zig");
const auth = @import("auth.zig");
const ratelimit = @import("ratelimit.zig");
const metrics = @import("metrics.zig");
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
            const now = timex.nowSeconds(self.io);
            const p = planner.plan(alloc, qr.query, enabled.items, now, self.cfg.tz_offset_minutes) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "planner_failed", "Query planning failed");
                return;
            };
            const outcome = search.searchAndRank(alloc, self.repo, p, now) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "search_failed", "Search failed");
                return;
            };
            self.metrics.observeQuery(outcome.sufficient);
            const resp = query_json.buildQueryResponse(alloc, req_id, qr.query, p, outcome, enabled.items.len, timex.nowSeconds(self.io)) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "response_failed", "Failed to render response");
                return;
            };
            self.metrics.observeRequest(200, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .ok, resp, req_id);
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
            const doc = types.Document{
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
            };
            self.repo.insertDocument(doc) catch {
                self.respondError(req, alloc, req_id, .internal_server_error, "ingest_failed", "Failed to store document");
                return;
            };
            if (self.sink) |s| {
                s.publish(s.ptr, alloc, doc.id, doc.source_id) catch {};
            }
            self.metrics.setDocumentsIndexed(@intCast(self.repo.countDocuments()));
            const resp = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"source_id\":\"{s}\",\"request_id\":\"{s}\"}}", .{ doc.id, doc.source_id, req_id });
            self.metrics.observeRequest(201, @intCast(@max(0, timex.nowMillis(self.io) - start_ms)));
            try respondJson(req, .created, resp, req_id);
            return;
        }

        if ((method == .GET or method == .POST) and
            (std.mem.eql(u8, path, "/v1/health") or std.mem.eql(u8, path, "/v1/sources") or
                std.mem.eql(u8, path, "/metrics") or std.mem.eql(u8, path, "/v1/query") or
                std.mem.eql(u8, path, "/v1/ingest")))
        {
            self.respondError(req, alloc, req_id, .method_not_allowed, "method_not_allowed", "Method not allowed on this route");
            return;
        }
        self.respondError(req, alloc, req_id, .not_found, "not_found", "No such route");
    }
};

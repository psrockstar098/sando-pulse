//! `pulse loadtest`: hammer a running Pulse server (default
//! http://127.0.0.1:9000) with N threads x M requests and report
//! latency percentiles for GET /v1/health and POST /v1/query.
//!
//! Each worker thread owns its own `std.Io.Threaded` instance (the
//! same rule as the concurrent fetcher: a Threaded io is only reliable
//! from the thread that owns it). The host must be a literal IP — the
//! tester targets a local server, so 127.0.0.1 is always available and
//! no DNS path is needed. HTTP only; https:// is refused honestly
//! (no TLS in the tester). One fresh connection per request, so the
//! numbers include connection setup — the honest cost for a client
//! that does not reuse connections.

const std = @import("std");

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,
    threads: usize = 4,
    requests: usize = 100,
    query: []const u8 = "fuel shortage in Monrovia",
};

/// Parse `pulse loadtest [--url http://host:port] [--threads N]
/// [--requests N] [--query "..."]`.
pub fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const uri = std.Uri.parse(args[i]) catch return error.BadUrl;
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.HttpsNotSupported;
            const host = uri.host orelse return error.BadUrl;
            opts.host = try host.toRawMaybeAlloc(alloc);
            opts.port = uri.port orelse 80;
        } else if (std.mem.eql(u8, a, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.threads = try std.fmt.parseInt(usize, args[i], 10);
            if (opts.threads == 0) return error.BadThreads;
        } else if (std.mem.eql(u8, a, "--requests")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.requests = try std.fmt.parseInt(usize, args[i], 10);
            if (opts.requests == 0) return error.BadRequests;
        } else if (std.mem.eql(u8, a, "--query")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.query = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return opts;
}

/// Monotonic nanosecond clock for latency measurement (raw syscall,
/// logging.zig precedent — std.time.nanoTimestamp does not exist in
/// 0.17.1, and no Io instance is available on worker threads).
fn nanoNow() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

/// Percentile of a SORTED latency array (nanoseconds). p is 0..100.
pub fn percentile(sorted: []const i64, p: u64) i64 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, sorted.len * p / 100);
    return sorted[idx];
}

fn formatMs(alloc: std.mem.Allocator, ns: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}.{d}ms", .{ @divTrunc(ns, 1_000_000), @divTrunc(@mod(ns, 1_000_000), 100_000) });
}

/// Escape a query string for the JSON request body.
fn escapeJson(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

const max_response_bytes = 1024 * 1024;

/// True when the buffered response is complete: headers end at the
/// blank line, and either Content-Length bytes of body are present or
/// there is no Content-Length (read until close).
/// Case-insensitive "content-length:" search; returns the index just
/// past the key, or null. (std.ascii has no indexOfIgnoreCase in 0.17.1.)
fn findContentLength(head: []const u8) ?usize {
    const key = "content-length:";
    if (head.len < key.len) return null;
    for (0..head.len - key.len + 1) |i| {
        var ok = true;
        for (key, 0..) |k, j| {
            if (std.ascii.toLower(head[i + j]) != k) {
                ok = false;
                break;
            }
        }
        if (ok) return i + key.len;
    }
    return null;
}

fn responseComplete(buf: []const u8) bool {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return false;
    const head = buf[0..head_end];
    var i = findContentLength(head) orelse return false;
    while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
    var j = i;
    while (j < head.len and head[j] >= '0' and head[j] <= '9') j += 1;
    const len = std.fmt.parseInt(usize, head[i..j], 10) catch return false;
    return buf.len >= head_end + 4 + len;
}

fn parseStatus(buf: []const u8) !u16 {
    const line_end = std.mem.indexOfScalar(u8, buf, '\r') orelse return error.BadResponse;
    const line = buf[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next() orelse return error.BadResponse;
    const code = it.next() orelse return error.BadResponse;
    return std.fmt.parseInt(u16, code, 10) catch return error.BadResponse;
}

/// One HTTP request over a fresh connection. Returns the status code.
/// Uses the caller's own Threaded io (never shared across threads).
fn doRequest(alloc: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, method: []const u8, path: []const u8, body: ?[]const u8) !u16 {
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    // Receive timeout so a hung server cannot hang a worker forever.
    const tv = std.posix.timeval{ .sec = 10, .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    // ArrayList has no .writer in 0.17.1; build with allocPrint.
    const head = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {f}\r\nConnection: close\r\n", .{ method, path, addr });
    defer alloc.free(head);
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(alloc);
    try req.appendSlice(alloc, head);
    if (body) |b| {
        const cl = try std.fmt.allocPrint(alloc, "Content-Type: application/json\r\nContent-Length: {d}\r\n", .{b.len});
        defer alloc.free(cl);
        try req.appendSlice(alloc, cl);
    }
    try req.appendSlice(alloc, "\r\n");
    if (body) |b| try req.appendSlice(alloc, b);

    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(req.items);
    try w.interface.flush();

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(alloc);
    var chunk: [8192]u8 = undefined;
    var bufs: [1][]u8 = .{chunk[0..]};
    while (resp.items.len < max_response_bytes) {
        const n = try stream.read(io, &bufs);
        if (n == 0) break; // server closed the connection
        try resp.appendSlice(alloc, chunk[0..n]);
        if (responseComplete(resp.items)) break;
    }
    return parseStatus(resp.items);
}

const WorkerCtx = struct {
    opts: Options,
    alloc: std.mem.Allocator,
    addr: std.Io.net.IpAddress,
    health_lat: []i64,
    query_lat: []i64,
    health_ok: usize = 0,
    query_ok: usize = 0,
    errors: usize = 0,

    fn run(self: *WorkerCtx) void {
        var threaded = std.Io.Threaded.init(self.alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        for (0..self.opts.requests) |i| {
            const t0 = nanoNow();
            if (doRequest(self.alloc, io, self.addr, "GET", "/v1/health", null)) |status| {
                self.health_lat[i] = nanoNow() - t0;
                if (status == 200) self.health_ok += 1 else self.errors += 1;
            } else |_| {
                self.health_lat[i] = nanoNow() - t0;
                self.errors += 1;
            }
            const q0 = nanoNow();
            const escaped = escapeJson(self.alloc, self.opts.query) catch {
                self.errors += 1;
                continue;
            };
            defer self.alloc.free(escaped);
            const body = std.fmt.allocPrint(self.alloc, "{{\"query\":\"{s}\",\"limit\":5}}", .{escaped}) catch {
                self.errors += 1;
                continue;
            };
            defer self.alloc.free(body);
            if (doRequest(self.alloc, io, self.addr, "POST", "/v1/query", body)) |status| {
                self.query_lat[i] = nanoNow() - q0;
                if (status == 200) self.query_ok += 1 else self.errors += 1;
            } else |_| {
                self.query_lat[i] = nanoNow() - q0;
                self.errors += 1;
            }
        }
    }
};

/// Run the load test and print the report to stderr. The workers
/// each build their own Threaded io; nothing here uses the caller's io
/// (host resolution is literal-IP only, so no DNS is needed).
pub fn run(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const opts = try parseArgs(alloc, args);
    const addr = std.Io.net.IpAddress.parse(opts.host, opts.port) catch {
        std.debug.print("loadtest: --url host must be a literal IP (use 127.0.0.1), got '{s}'\n", .{opts.host});
        return error.BadHost;
    };
    const total = opts.threads * opts.requests;
    const health_lat = try alloc.alloc(i64, total);
    defer alloc.free(health_lat);
    const query_lat = try alloc.alloc(i64, total);
    defer alloc.free(query_lat);
    const ctxs = try alloc.alloc(WorkerCtx, opts.threads);
    defer alloc.free(ctxs);
    const threads = try alloc.alloc(std.Thread, opts.threads);
    defer alloc.free(threads);

    const t0 = nanoNow();
    for (0..opts.threads) |t| {
        ctxs[t] = .{
            .opts = opts,
            .alloc = alloc,
            .addr = addr,
            .health_lat = health_lat[t * opts.requests .. (t + 1) * opts.requests],
            .query_lat = query_lat[t * opts.requests .. (t + 1) * opts.requests],
        };
        threads[t] = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctxs[t]});
    }
    for (threads) |th| th.join();
    const elapsed_ns = nanoNow() - t0;

    var health_ok: usize = 0;
    var query_ok: usize = 0;
    var errors: usize = 0;
    for (ctxs) |c| {
        health_ok += c.health_ok;
        query_ok += c.query_ok;
        errors += c.errors;
    }
    std.mem.sort(i64, health_lat, {}, std.sort.asc(i64));
    std.mem.sort(i64, query_lat, {}, std.sort.asc(i64));
    const health_mean = if (total > 0) blk: {
        var sum: i64 = 0;
        for (health_lat) |v| sum += v;
        break :blk @divTrunc(sum, @as(i64, @intCast(total)));
    } else 0;
    const query_mean = if (total > 0) blk: {
        var sum: i64 = 0;
        for (query_lat) |v| sum += v;
        break :blk @divTrunc(sum, @as(i64, @intCast(total)));
    } else 0;

    std.debug.print("loadtest: http://{s}:{d} threads={d} requests={d} query='{s}'\n", .{ opts.host, opts.port, opts.threads, opts.requests, opts.query });
    std.debug.print("health: ok={d} errors={d} p50={s} p95={s} max={s} mean={s}\n", .{
        health_ok, errors,
        try formatMs(alloc, percentile(health_lat, 50)),
        try formatMs(alloc, percentile(health_lat, 95)),
        try formatMs(alloc, health_lat[health_lat.len - 1]),
        try formatMs(alloc, health_mean),
    });
    std.debug.print("query:  ok={d} errors={d} p50={s} p95={s} max={s} mean={s}\n", .{
        query_ok, errors,
        try formatMs(alloc, percentile(query_lat, 50)),
        try formatMs(alloc, percentile(query_lat, 95)),
        try formatMs(alloc, query_lat[query_lat.len - 1]),
        try formatMs(alloc, query_mean),
    });
    const calls: f64 = @floatFromInt(total * 2);
    const secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    std.debug.print("total: {d} calls in {d:.2}s, {d:.1} calls/s\n", .{ total * 2, secs, calls / secs });
}

test "parseArgs: defaults, url, threads, requests, query" {
    const alloc = std.testing.allocator;
    const d = try parseArgs(alloc, &.{});
    try std.testing.expectEqualStrings("127.0.0.1", d.host);
    try std.testing.expectEqual(@as(u16, 9000), d.port);
    try std.testing.expectEqual(@as(usize, 4), d.threads);
    try std.testing.expectEqual(@as(usize, 100), d.requests);
    const u = try parseArgs(alloc, &.{ "--url", "http://127.0.0.1:9010", "--threads", "2", "--requests", "5", "--query", "boakai" });
    try std.testing.expectEqualStrings("127.0.0.1", u.host);
    try std.testing.expectEqual(@as(u16, 9010), u.port);
    try std.testing.expectEqual(@as(usize, 2), u.threads);
    try std.testing.expectEqual(@as(usize, 5), u.requests);
    try std.testing.expectEqualStrings("boakai", u.query);
    try std.testing.expectError(error.HttpsNotSupported, parseArgs(alloc, &.{"--url", "https://127.0.0.1:9000"}));
    try std.testing.expectError(error.UnknownFlag, parseArgs(alloc, &.{"--nope"}));
    try std.testing.expectError(error.MissingValue, parseArgs(alloc, &.{"--threads"}));
}

test "percentile: sorted array, edge cases" {
    try std.testing.expectEqual(@as(i64, 0), percentile(&.{}, 50));
    try std.testing.expectEqual(@as(i64, 10), percentile(&.{10}, 95));
    const s = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(i64, 6), percentile(&s, 50));
    try std.testing.expectEqual(@as(i64, 10), percentile(&s, 95));
    try std.testing.expectEqual(@as(i64, 1), percentile(&s, 0));
}

test "responseComplete: headers only, partial body, full body" {
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"));
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel"));
    try std.testing.expect(responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"));
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"));
    // No Content-Length: not complete until close (never true here).
    try std.testing.expect(!responseComplete("HTTP/1.1 200 OK\r\n\r\nhello"));
}

test "parseStatus: 200, 404, malformed" {
    try std.testing.expectEqual(@as(u16, 200), try parseStatus("HTTP/1.1 200 OK\r\n\r\n{}"));
    try std.testing.expectEqual(@as(u16, 404), try parseStatus("HTTP/1.1 404 Not Found\r\n\r\n"));
    try std.testing.expectError(error.BadResponse, parseStatus("garbage"));
}

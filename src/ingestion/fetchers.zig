//! HTTP fetching for ingestion, implemented directly on TCP + TLS.
//!
//! Why not std.http.Client: in Zig 0.17.1 the client's proxied-HTTPS path
//! sends the GET in PLAINTEXT through the CONNECT tunnel — proven 2026-11-12
//! with a fake-proxy capture (after `200 Connection Established` the client
//! writes `GET /feed/ HTTP/1.1` with no TLS handshake). The origin then
//! 301-redirects the plaintext request to its own https URL forever, so
//! every https feed fails with TooManyHttpRedirects through this VM's egress
//! proxy. This fetcher does CONNECT + TLS itself. It works via a proxy
//! (CONNECT for https, absolute-URI GET for http) and direct (no proxy env).
//!
//! No request timeout exists in this std (connect timeouts panic), so a dead
//! peer can stall one fetch — same limitation the std client has. The worker
//! logs per-source duration so a stuck source is visible.

const std = @import("std");
const logging = @import("../common/logging.zig");
const ssrf = @import("ssrf.zig");

pub const user_agent = "SandoPulse/0.1 (Liberia intelligence engine; research use)";

/// HTTP method for a single exchange. GET is the ingestion path; POST is
/// used by external AI provider adapters (embeddings / chat completions).
pub const Method = enum { get, post };

/// POST body options. `bearer` is sent as an Authorization header when set;
/// the key itself never appears in logs.
pub const PostBody = struct {
    body: []const u8,
    content_type: []const u8 = "application/json",
    bearer: ?[]const u8 = null,
};

/// POST a JSON body and return the raw response (status + body). No redirect
/// following: API endpoints answer directly, and a redirect of a POST must
/// be the caller's explicit decision. Returns error.SourceUnavailable on
/// transport failure; the caller checks `status` itself.
pub fn postJson(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    bearer: ?[]const u8,
    environ: ?*const std.process.Environ.Map,
) !FetchResult {
    const res = try fetchOnce(alloc, io, url, environ, .post, .{ .body = body, .bearer = bearer });
    return res;
}

/// A single fetch result, shared by GET and POST. Public so provider
/// adapters can read status + body.
pub const FetchResult = struct {
    status: u16,
    location: ?[]u8, // owned, duped from the Location header (if any)
    body: []u8, // owned

    pub fn deinit(self: FetchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        if (self.location) |loc| alloc.free(loc);
    }
};

const max_redirects = 5;
const max_response_bytes = 9 * 1024 * 1024; // head + body cap per fetch
const max_head_bytes = 64 * 1024;

/// Fetch a URL body, following up to 5 redirects. Returns owned bytes, or
/// error.SourceUnavailable on any non-200 status / transport failure.
/// `environ` is the process environment map (may be null in tests): proxy
/// settings are read from http_proxy / https_proxy / all_proxy (lowercase
/// first, then uppercase, as std does). With no proxy variables the client
/// connects directly.
pub fn fetchFeed(alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) ![]u8 {
    var cur = try alloc.dupe(u8, url);
    var hops: u8 = 0;
    while (true) {
        const res = try fetchOnce(alloc, io, cur, environ, .get, null);
        if (res.status == 200) {
            if (res.location) |loc| alloc.free(loc);
            alloc.free(cur);
            return res.body;
        }
        const is_redir = res.status == 301 or res.status == 302 or res.status == 303 or res.status == 307 or res.status == 308;
        if (is_redir) {
            if (res.location) |loc| {
                hops += 1;
                if (hops > max_redirects) {
                    alloc.free(res.body);
                    alloc.free(loc);
                    alloc.free(cur);
                    return error.TooManyHttpRedirects;
                }
                const next = try resolveUrl(alloc, cur, loc);
                alloc.free(res.body);
                alloc.free(loc);
                alloc.free(cur);
                cur = next;
                continue;
            }
        }
        alloc.free(res.body);
        if (res.location) |loc| alloc.free(loc);
        alloc.free(cur);
        return error.SourceUnavailable;
    }
}

const ProxyCfg = struct {
    uri: std.Uri, // parsed proxy URL; borrows the environ string
    auth: ?[]u8, // owned "Basic <base64(user:password)>" or null

    fn deinit(self: ProxyCfg, alloc: std.mem.Allocator) void {
        if (self.auth) |a| alloc.free(a);
    }
};

fn proxyFor(alloc: std.mem.Allocator, environ: ?*const std.process.Environ.Map, is_https: bool) !?ProxyCfg {
    const env = environ orelse return null;
    const names: []const []const u8 = if (is_https)
        &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }
    else
        &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" };
    const raw = for (names) |n| {
        if (env.get(n)) |v| {
            if (v.len > 0) break v;
        }
    } else return null;
    const uri = std.Uri.parse(raw) catch return null;
    var auth: ?[]u8 = null;
    if (uri.user) |user| {
        const user_raw = try user.toRawMaybeAlloc(alloc);
        const pass_raw: []const u8 = if (uri.password) |p| try p.toRawMaybeAlloc(alloc) else "";
        const creds = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ user_raw, pass_raw });
        defer alloc.free(creds);
        const b64_len = std.base64.standard.Encoder.calcSize(creds.len);
        const out = try alloc.alloc(u8, "Basic ".len + b64_len);
        @memcpy(out[0.."Basic ".len], "Basic ");
        _ = std.base64.standard.Encoder.encode(out["Basic ".len..], creds);
        auth = out;
    }
    return .{ .uri = uri, .auth = auth };
}

/// Resolve a Location header against the URL it came from. Absolute URLs
/// pass through; root-relative paths keep the current scheme+host;
/// path-relative values resolve against the current directory.
fn resolveUrl(alloc: std.mem.Allocator, base: []const u8, loc: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, loc, "http://") or std.mem.startsWith(u8, loc, "https://")) {
        return alloc.dupe(u8, loc);
    }
    const uri = std.Uri.parse(base) catch return alloc.dupe(u8, loc);
    if (std.mem.startsWith(u8, loc, "/")) {
        return std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ uri.scheme, try uri.host.?.toRawMaybeAlloc(alloc), loc });
    }
    // Path-relative: current directory + loc.
    const path = try uri.path.toRawMaybeAlloc(alloc);
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    return std.fmt.allocPrint(alloc, "{s}://{s}{s}/{s}", .{ uri.scheme, try uri.host.?.toRawMaybeAlloc(alloc), path[0..dir_end], loc });
}

/// One request, no redirect following. Returns the parsed status, Location and body.
fn fetchOnce(alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map, method: Method, post: ?PostBody) !FetchResult {
    const uri = std.Uri.parse(url) catch return error.SourceUnavailable;
    const is_https = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        true
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        false
    else
        return error.SourceUnavailable;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.SourceUnavailable;
    // SSRF guard (Roadmap 5.1): ingestion GETs never connect to loopback,
    // private, link-local or otherwise non-public targets — a feed redirect
    // to 169.254.169.254 or 127.0.0.1 is refused before any socket opens.
    // POSTs are operator-configured provider endpoints (a local Ollama is
    // legitimate) and are not checked.
    if (method == .get) {
        ssrf.checkHost(alloc, io, host.bytes) catch |e| {
            logging.warn("ssrf: refused fetch target", &.{ .{ .key = "host", .value = host.bytes }, .{ .key = "error", .value = @errorName(e) } });
            return error.SourceUnavailable;
        };
    }
    const port: u16 = uri.port orelse if (is_https) 443 else 80;
    const target = try requestTarget(alloc, uri);
    defer alloc.free(target);
    const proxy = try proxyFor(alloc, environ, is_https);
    defer if (proxy) |p| p.deinit(alloc);

    // TCP connect: to the proxy, or directly to the origin.
    var stream: std.Io.net.Stream = undefined;
    if (proxy) |p| {
        var pbuf: [std.Io.net.HostName.max_len]u8 = undefined;
        const phost = std.Io.net.HostName.fromUri(p.uri, &pbuf) catch return error.SourceUnavailable;
        const pport: u16 = p.uri.port orelse 8080;
        stream = phost.connect(io, pport, .{ .mode = .stream }) catch return error.SourceUnavailable;
    } else {
        stream = host.connect(io, port, .{ .mode = .stream }) catch return error.SourceUnavailable;
    }
    defer stream.close(io);

    // Socket buffers must be at least tls.Client.min_buffer_len: the TLS
    // client asserts the underlying reader/writer buffers are that large.
    var sock_read_buf: [std.crypto.tls.Client.min_buffer_len + 8192]u8 = undefined;
    var sock_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sreader = stream.reader(io, &sock_read_buf);
    var swriter = stream.writer(io, &sock_write_buf);

    // HTTPS via proxy: CONNECT tunnel. No Proxy-Authorization: this proxy
    // accepts unauthenticated CONNECT, and its credentials rotate, so sending
    // a stale one would 407 and kill the tunnel.
    if (proxy != null and is_https) {
        const req = try std.fmt.allocPrint(alloc, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host.bytes, port, host.bytes, port });
        defer alloc.free(req);
        swriter.interface.writeAll(req) catch return error.SourceUnavailable;
        swriter.interface.flush() catch return error.SourceUnavailable;
        const head = try readHead(alloc, &sreader.interface);
        defer alloc.free(head);
        const status = parseStatus(head) orelse return error.SourceUnavailable;
        if (status != 200) {
            logging.warn("proxy CONNECT rejected", &.{ .{ .key = "host", .value = host.bytes }, .{ .key = "status", .value = try std.fmt.allocPrint(alloc, "{d}", .{status}) } });
            return error.SourceUnavailable;
        }
    }

    if (is_https) {
        return fetchTls(alloc, io, &sreader, &swriter, host.bytes, target, method, post);
    }
    // Plain HTTP: absolute-URI form via proxy (with auth when configured),
    // origin-form direct.
    const absolute: ?[]const u8 = if (proxy != null) url else null;
    const auth: ?[]const u8 = if (proxy) |p| p.auth else null;
    return exchange(alloc, &sreader.interface, &swriter.interface, target, host.bytes, port, absolute, auth, null, method, post);
}

/// HTTPS exchange over an already-connected (and CONNECT-tunneled, if proxied)
/// stream. The TLS client lives in this frame and is never moved after init.
fn fetchTls(
    alloc: std.mem.Allocator,
    io: std.Io,
    sreader: *std.Io.net.Stream.Reader,
    swriter: *std.Io.net.Stream.Writer,
    host: []const u8,
    target: []const u8,
    method: Method,
    post: ?PostBody,
) !FetchResult {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(alloc);
    bundle.rescan(alloc, io, std.Io.Timestamp.now(io, .real)) catch return error.SourceUnavailable;
    var lock: std.Io.RwLock = .init;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len + 8192]u8 = undefined;
    var tls = std.crypto.tls.Client.init(&sreader.interface, &swriter.interface, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = alloc, .io = io, .lock = &lock, .bundle = &bundle } },
        .read_buffer = &tls_read_buf,
        .write_buffer = &tls_write_buf,
        .entropy = &entropy,
        .realtime_now = std.Io.Timestamp.now(io, .real),
        .allow_truncation_attacks = true,
    }) catch |e| {
        logging.warn("TLS handshake failed", &.{ .{ .key = "host", .value = host }, .{ .key = "error", .value = @errorName(e) } });
        return error.SourceUnavailable;
    };
    return exchange(alloc, &tls.reader, &tls.writer, target, host, 443, null, null, swriter, method, post);
}

/// Send one request and read the whole response (Connection: close, so EOF ends
/// the body). `absolute` is the full URL for proxy absolute-URI form, or
/// null for origin-form. Returns status, Location and body.
fn exchange(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    target: []const u8,
    host: []const u8,
    port: u16,
    absolute: ?[]const u8,
    proxy_auth: ?[]const u8,
    // For TLS: the socket writer under the TLS writer. tls.Client's flush
    // encrypts into the socket writer's buffer but does NOT flush it, so
    // the GET sits unsent until the socket writer is flushed too. Without
    // this the server waits for a request that never arrives and answers
    // 408 (Daily Observer) or nothing at all (New Dawn).
    flush_underlying: ?*std.Io.net.Stream.Writer,
    method: Method,
    post: ?PostBody,
) !FetchResult {
    var req: std.Io.Writer.Allocating = .init(alloc);
    defer req.deinit();
    const req_target = absolute orelse target;
    switch (method) {
        .get => try req.writer.print("GET {s} HTTP/1.1\r\n", .{req_target}),
        .post => try req.writer.print("POST {s} HTTP/1.1\r\n", .{req_target}),
    }
    if (port == 443 or port == 80) {
        try req.writer.print("Host: {s}\r\n", .{host});
    } else {
        try req.writer.print("Host: {s}:{d}\r\n", .{ host, port });
    }
    try req.writer.print("User-Agent: {s}\r\nAccept: */*\r\nConnection: close\r\n", .{user_agent});
    if (method == .post) {
        const body = if (post) |p| p.body else "";
        const ctype = if (post) |p| p.content_type else "application/json";
        try req.writer.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ ctype, body.len });
        if (post) |p| {
            if (p.bearer) |b| try req.writer.print("Authorization: Bearer {s}\r\n", .{b});
        }
    }
    if (proxy_auth) |a| try req.writer.print("Proxy-Authorization: {s}\r\n", .{a});
    try req.writer.writeAll("\r\n");
    if (method == .post) {
        const body = if (post) |p| p.body else "";
        try req.writer.writeAll(body);
    }
    if (proxy_auth) |a| try req.writer.print("Proxy-Authorization: {s}\r\n", .{a});
    try req.writer.writeAll("\r\n");
    writer.writeAll(req.written()) catch return error.SourceUnavailable;
    writer.flush() catch return error.SourceUnavailable;
    if (flush_underlying) |uw| uw.interface.flush() catch return error.SourceUnavailable;
    const raw = try readResponse(reader, alloc);
    defer alloc.free(raw);
    return parseResponse(alloc, raw);
}

/// Read one complete HTTP response, bounded by its own framing — never by
/// waiting for the peer to close the connection. The peer may keep the
/// connection alive after the response (e.g. a 301 with Content-Length: 0),
/// so read-until-EOF hangs. Framing: Content-Length bytes, chunked until
/// the terminal 0-chunk, or close-delimited (no length, no chunked) as the
/// only EOF case.
fn readResponse(reader: *std.Io.Reader, alloc: std.mem.Allocator) ![]u8 {
    const head_raw = try readHead(alloc, reader);
    defer alloc.free(head_raw);
    const parsed = parseHead(head_raw) orelse return error.SourceUnavailable;
    const info = parsed.info;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(head_raw);
    // Any body bytes already read past the headers are in `out` already.
    if (info.chunked) {
        // Read until dechunk succeeds (terminal 0-chunk present).
        while (true) {
            const body = out.written()[parsed.body_off..];
            if (dechunk(alloc, body) catch null) |b| {
                alloc.free(b);
                break;
            }
            if (out.written().len >= max_response_bytes) return error.BodyTooLarge;
            try readMore(reader, &out);
        }
    } else if (info.content_length) |len| {
        const need: usize = @intCast(len);
        while (out.written().len - parsed.body_off < need) {
            if (out.written().len >= max_response_bytes) return error.BodyTooLarge;
            try readMore(reader, &out);
        }
    } else {
        // Close-delimited: the only case where EOF ends the body.
        while (true) {
            if (out.written().len >= max_response_bytes) return error.BodyTooLarge;
            const before = out.written().len;
            const done = readMoreEof(reader, &out);
            if (done) break;
            if (out.written().len == before) break; // no progress
        }
    }
    return out.toOwnedSlice();
}

/// One underlying read appended to `out`. Returns true on EOF/error.
fn readMoreEof(reader: *std.Io.Reader, out: *std.Io.Writer.Allocating) bool {
    var tmp: [8192]u8 = undefined;
    var bufs: [1][]u8 = .{&tmp};
    const n = reader.readVec(&bufs) catch return true;
    // n==0 is NOT EOF for the TLS reader (partially-buffered record): retry.
    if (n == 0) return false;
    out.writer.writeAll(tmp[0..n]) catch return true;
    return false;
}

/// One underlying read appended to `out`; errors end the read (caller checks
/// completeness against the framing). Blocks until data arrives: the TLS
/// reader returns 0 for a partially-buffered record, so a single readVec
/// is not enough — loop inside here instead of letting the caller spin
/// (each spin re-runs dechunk over the whole body).
fn readMore(reader: *std.Io.Reader, out: *std.Io.Writer.Allocating) !void {
    var tmp: [8192]u8 = undefined;
    while (true) {
        var bufs: [1][]u8 = .{&tmp};
        const n = reader.readVec(&bufs) catch return error.SourceUnavailable;
        if (n == 0) continue; // partial TLS record: retry (blocking recv)
        try out.writer.writeAll(tmp[0..n]);
        return;
    }
}

/// Read bytes until the end of the HTTP head (\r\n\r\n), capped.
fn readHead(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var tmp: [1024]u8 = undefined;
    while (true) {
        if (out.written().len >= max_head_bytes) return error.HeadTooLarge;
        // readVec, not readSliceShort: readSliceShort loops until the buffer is FULL or EOF.
        var bufs: [1][]u8 = .{&tmp};
        const n = reader.readVec(&bufs) catch break;
        if (n == 0) continue;
        try out.writer.writeAll(tmp[0..n]);
        if (std.mem.indexOf(u8, out.written(), "\r\n\r\n") != null) break;
    }
    return out.toOwnedSlice();
}

fn parseStatus(head: []const u8) ?u16 {
    // "HTTP/1.1 200 OK"
    if (head.len < 12) return null;
    if (!std.mem.startsWith(u8, head, "HTTP/")) return null;
    const code = std.fmt.parseInt(u16, head[9..12], 10) catch return null;
    return code;
}

/// Origin-form request target: "/path?query", default "/".
/// Uses the percent-ENCODED form (formatEscaped): toRawMaybeAlloc
/// decodes %20 back to a raw space, which puts a literal space in the
/// request line — strict servers (Nominatim/Varnish) close the
/// connection without responding. Found live 2026-11-12 via the OSM
/// connector: head_raw len 0 on every Nominatim fetch until this fix.
fn requestTarget(alloc: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(uri.path, .formatEscaped)});
    if (uri.query) |q| {
        defer alloc.free(path);
        const qs = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(q, .formatEscaped)});
        defer alloc.free(qs);
        const p = if (path.len == 0) "/" else path;
        return std.fmt.allocPrint(alloc, "{s}?{s}", .{ p, qs });
    }
    if (path.len == 0) {
        alloc.free(path);
        return alloc.dupe(u8, "/");
    }
    return path;
}

const HeadInfo = struct {
    status: u16,
    location: ?[]const u8, // slices into raw
    content_length: ?u64,
    chunked: bool,
    content_encoding: ?[]const u8, // slices into raw
};

/// Case-insensitive substring search (haystacks here are short header values).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn parseHead(raw: []const u8) ?struct { info: HeadInfo, body_off: usize } {
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const head = raw[0..end];
    const status = parseStatus(head) orelse return null;
    var info = HeadInfo{ .status = status, .location = null, .content_length = null, .chunked = false, .content_encoding = null };
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.first(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "location")) {
            info.location = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            info.content_length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (containsIgnoreCase(value, "chunked")) info.chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
            info.content_encoding = value;
        }
    }
    return .{ .info = info, .body_off = end + 4 };
}

/// Parse a complete raw HTTP response into status, Location and body.
/// Handles chunked transfer encoding and Content-Length; anything else is
/// close-delimited. A gzip/deflate body is an error (we never advertise it).
fn parseResponse(alloc: std.mem.Allocator, raw: []const u8) !FetchResult {
    const parsed = parseHead(raw) orelse return error.SourceUnavailable;
    const info = parsed.info;
    const raw_body = raw[parsed.body_off..];
    if (info.content_encoding) |enc| {
        if (!std.ascii.eqlIgnoreCase(enc, "identity")) {
            logging.warn("unexpected content-encoding", &.{.{ .key = "encoding", .value = enc }});
            return error.SourceUnavailable;
        }
    }
    var body: []u8 = undefined;
    if (info.chunked) {
        body = try dechunk(alloc, raw_body);
    } else if (info.content_length) |len| {
        if (raw_body.len < len) return error.SourceUnavailable; // truncated
        body = try alloc.dupe(u8, raw_body[0..@intCast(len)]);
    } else {
        body = try alloc.dupe(u8, raw_body);
    }
    return .{
        .status = info.status,
        .location = if (info.location) |l| try alloc.dupe(u8, l) else null,
        .body = body,
    };
}

/// Decode HTTP chunked transfer encoding. Stops at the 0-chunk; trailers
/// after it are ignored.
fn dechunk(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var pos: usize = 0;
    while (true) {
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse return error.SourceUnavailable;
        const size_line = raw[pos .. pos + line_end];
        const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_line[0..semi], " \t"), 16) catch return error.SourceUnavailable;
        pos += line_end + 2;
        if (size == 0) break;
        if (pos + size + 2 > raw.len) return error.SourceUnavailable; // truncated chunk
        try out.writer.writeAll(raw[pos .. pos + size]);
        pos += size + 2; // chunk + trailing CRLF
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests (in-memory; the live leg is the worker --once smoke run).
// ---------------------------------------------------------------------------

test "fetchers: parseStatus" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatus("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 301), parseStatus("HTTP/1.1 301 Moved Permanently\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatus("garbage"));
    try std.testing.expectEqual(@as(?u16, null), parseStatus("HTTP/1.1"));
}

test "fetchers: parseResponse content-length" {
    const alloc = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhelloEXTRA";
    const res = try parseResponse(alloc, raw);
    defer alloc.free(res.body);
    defer if (res.location) |l| alloc.free(l);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("hello", res.body);
    try std.testing.expect(res.location == null);
}

test "fetchers: parseResponse chunked" {
    const alloc = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    const res = try parseResponse(alloc, raw);
    defer alloc.free(res.body);
    defer if (res.location) |l| alloc.free(l);
    try std.testing.expectEqualStrings("hello world", res.body);
}

test "fetchers: parseResponse chunked with extension and truncated" {
    const alloc = std.testing.allocator;
    const raw_ok = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n0\r\n\r\n";
    const res = try parseResponse(alloc, raw_ok);
    defer alloc.free(res.body);
    defer if (res.location) |l| alloc.free(l);
    try std.testing.expectEqualStrings("hello", res.body);
    const raw_trunc = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nshort\r\n0\r\n\r\n";
    try std.testing.expectError(error.SourceUnavailable, parseResponse(alloc, raw_trunc));
}

test "fetchers: parseResponse redirect + gzip refused" {
    const alloc = std.testing.allocator;
    const raw = "HTTP/1.1 301 Moved Permanently\r\nLocation: https://example.com/feed/\r\nContent-Length: 0\r\n\r\n";
    const res = try parseResponse(alloc, raw);
    defer alloc.free(res.body);
    defer if (res.location) |l| alloc.free(l);
    try std.testing.expectEqual(@as(u16, 301), res.status);
    try std.testing.expectEqualStrings("https://example.com/feed/", res.location.?);
    const raw_gz = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nabc";
    try std.testing.expectError(error.SourceUnavailable, parseResponse(alloc, raw_gz));
}

test "fetchers: parseResponse truncated content-length" {
    const alloc = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort";
    try std.testing.expectError(error.SourceUnavailable, parseResponse(alloc, raw));
}

test "fetchers: resolveUrl" {
    const alloc = std.testing.allocator;
    const abs = try resolveUrl(alloc, "https://a.com/x/y", "https://b.com/feed/");
    defer alloc.free(abs);
    try std.testing.expectEqualStrings("https://b.com/feed/", abs);
    const root = try resolveUrl(alloc, "https://a.com/x/y", "/feed/");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("https://a.com/feed/", root);
    const rel = try resolveUrl(alloc, "https://a.com/x/y", "z.xml");
    defer alloc.free(rel);
    try std.testing.expectEqualStrings("https://a.com/x/z.xml", rel);
}

test "fetchers: requestTarget" {
    const alloc = std.testing.allocator;
    const uri1 = try std.Uri.parse("http://www.liberianobserver.com/search/?f=rss&t=article&l=50");
    const t1 = try requestTarget(alloc, uri1);
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("/search/?f=rss&t=article&l=50", t1);
    const uri2 = try std.Uri.parse("https://thenewdawnliberia.com/feed/");
    const t2 = try requestTarget(alloc, uri2);
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("/feed/", t2);
    const uri3 = try std.Uri.parse("https://example.com");
    const t3 = try requestTarget(alloc, uri3);
    defer alloc.free(t3);
    try std.testing.expectEqualStrings("/", t3);
}

test "fetchers: proxyFor parses auth" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("https_proxy", "http://user:pass123@proxy.local:3128");
    const p = (try proxyFor(alloc, &env, true)).?;
    defer p.deinit(alloc);
    try std.testing.expectEqualStrings("proxy.local", try p.uri.host.?.toRawMaybeAlloc(alloc));
    try std.testing.expectEqual(@as(?u16, 3128), p.uri.port);
    // "Basic " + base64("user:pass123")
    try std.testing.expectEqualStrings("Basic dXNlcjpwYXNzMTIz", p.auth.?);
    const none = try proxyFor(alloc, &env, false);
    try std.testing.expect(none == null);
}

//! Redis client (RESP2) for Sando Pulse — std lib only, TCP via std.Io.net.
//!
//! Timeouts (so a dead peer can never hang the server forever):
//!   * TCP connect: this Zig's `std.Io.Threaded` backend PANICS
//!     ("TODO implement netConnectIpPosix with timeout") if a connect
//!     timeout is supplied, so the connect call passes `.timeout = .none`
//!     and relies on the OS TCP connect timeout. `Options.connect_timeout_s`
//!     is kept for forward compatibility — wire it back in once the std
//!     implements it. Everything after connect IS deadline-bounded (below),
//!     so a peer that accepts and then goes silent cannot hang a caller.
//!   * Each command: 10 s from send to complete reply
//!     (Options.command_timeout_s). Every socket read/write is issued
//!     through `Io.operateTimeout` against a per-command deadline, so a
//!     peer that accepts and then goes silent surfaces `error.Timeout`
//!     instead of blocking.
//!   * XREADGROUP with BLOCK: the deadline is `block_ms` + the command
//!     timeout, because the server legitimately holds the connection open
//!     for up to `block_ms` waiting for new entries.
//!   * The RESP parser also caps a single reply at 16 MiB and nested
//!     arrays at 64 levels, so a misbehaving peer cannot grow memory or
//!     the stack without bound.
//!
//! No secrets are logged: connect/auth failures log `host:port` only, and
//! AUTH only records that a password was used, never the password itself.
//!
//! NOTE: this file deliberately does NOT import `../common/logging.zig`:
//! that module calls `std.time.milliTimestamp()`, which does not exist in
//! the installed Zig 0.17.1 std lib, so importing it would break this
//! module's compilation. Logging here is a two-line `std.debug.print`
//! helper with the same host:port-only rule; switch to the shared logger
//! once it compiles against this toolchain.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Minimal stderr logging (see header note). Never pass secrets here.
fn logMsg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[redis] " ++ fmt ++ "\n", args);
}

/// Log `host:port` only — never the URL, which may carry a password.
fn logHostPort(msg: []const u8, host: []const u8, port: u16) void {
    logMsg("{s} addr={s}:{d}", .{ msg, host, port });
}

/// Unix time in milliseconds from the realtime clock.
fn unixMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub const default_port: u16 = 6379;
pub const default_connect_timeout_s: u64 = 5;
pub const default_command_timeout_s: u64 = 10;
/// Largest single RESP reply accepted from the server (16 MiB).
pub const max_reply_bytes: usize = 16 * 1024 * 1024;
/// Deepest nested RESP array the decoder will accept.
pub const max_array_depth: usize = 64;

/// Stream the event bus publishes to (docs/INTERFACES.md).
pub const events_stream: []const u8 = "pulse:events";

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const StreamEntry = struct {
    id: []const u8,
    fields: []Field,
};

/// One RESP2 value. Strings and nested values decoded by this module are
/// owned by the allocator passed to the decoding call.
pub const RespValue = union(enum) {
    simple: []const u8,
    err: []const u8,
    integer: i64,
    bulk: ?[]const u8,
    array: ?[]RespValue,
};

pub const ParseError = error{
    /// More bytes are needed before the value is complete.
    Incomplete,
    /// Bytes do not form valid RESP2 (bad type byte, bad length, bad CRLF...).
    InvalidResp,
    OutOfMemory,
};

/// Incremental RESP2 decoder over an in-memory byte slice. When a parse
/// returns `error.Incomplete`, the caller appends more bytes and retries
/// the parse from the start (fresh parser over the longer slice): the
/// parser has no restart position, so partial reads from the stream are
/// handled by re-parsing the accumulated buffer once more bytes arrive.
pub const RespParser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn parseValue(self: *RespParser, alloc: Allocator) ParseError!RespValue {
        return self.parseValueDepth(alloc, 0);
    }

    fn parseValueDepth(self: *RespParser, alloc: Allocator, depth: usize) ParseError!RespValue {
        if (depth > max_array_depth) return error.InvalidResp;
        const tag = try self.takeByte();
        switch (tag) {
            '+' => return .{ .simple = try alloc.dupe(u8, try self.takeLine()) },
            '-' => return .{ .err = try alloc.dupe(u8, try self.takeLine()) },
            ':' => return .{ .integer = try parseInt(try self.takeLine()) },
            '$' => {
                const len = try parseInt(try self.takeLine());
                if (len == -1) return .{ .bulk = null };
                if (len < -1) return error.InvalidResp;
                const n: usize = @intCast(len);
                const bytes = try self.takeBytes(n);
                try self.takeCrlf();
                return .{ .bulk = try alloc.dupe(u8, bytes) };
            },
            '*' => {
                const count = try parseInt(try self.takeLine());
                if (count == -1) return .{ .array = null };
                if (count < -1) return error.InvalidResp;
                const n: usize = @intCast(count);
                const items = try alloc.alloc(RespValue, n);
                errdefer alloc.free(items);
                for (items) |*item| {
                    item.* = try self.parseValueDepth(alloc, depth + 1);
                }
                return .{ .array = items };
            },
            else => return error.InvalidResp,
        }
    }

    fn takeByte(self: *RespParser) ParseError!u8 {
        if (self.pos >= self.data.len) return error.Incomplete;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// One line without its trailing CRLF. `error.Incomplete` if no full
    /// line is buffered yet.
    fn takeLine(self: *RespParser) ParseError![]const u8 {
        const start = self.pos;
        const lf = std.mem.indexOfScalarPos(u8, self.data, start, '\n') orelse
            return error.Incomplete;
        if (lf == start or self.data[lf - 1] != '\r') return error.InvalidResp;
        self.pos = lf + 1;
        return self.data[start .. lf - 1];
    }

    fn takeBytes(self: *RespParser, n: usize) ParseError![]const u8 {
        if (self.data.len - self.pos < n) return error.Incomplete;
        const bytes = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return bytes;
    }

    fn takeCrlf(self: *RespParser) ParseError!void {
        const bytes = try self.takeBytes(2);
        if (!std.mem.eql(u8, bytes, "\r\n")) return error.InvalidResp;
    }
};

fn parseInt(line: []const u8) ParseError!i64 {
    return std.fmt.parseInt(i64, line, 10) catch error.InvalidResp;
}

/// Encode one value as RESP2 bytes, owned by `alloc`.
pub fn encodeValue(alloc: Allocator, value: RespValue) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try encodeValueInto(alloc, &list, value, 0);
    return list.toOwnedSlice(alloc);
}

fn encodeValueInto(alloc: Allocator, list: *std.ArrayList(u8), value: RespValue, depth: usize) !void {
    if (depth > max_array_depth) return error.InvalidResp;
    switch (value) {
        .simple => |s| {
            try list.append(alloc, '+');
            try list.appendSlice(alloc, s);
            try list.appendSlice(alloc, "\r\n");
        },
        .err => |s| {
            try list.append(alloc, '-');
            try list.appendSlice(alloc, s);
            try list.appendSlice(alloc, "\r\n");
        },
        .integer => |n| {
            try list.print(alloc, ":{d}\r\n", .{n});
        },
        .bulk => |b| {
            if (b) |bytes| {
                try list.print(alloc, "${d}\r\n", .{bytes.len});
                try list.appendSlice(alloc, bytes);
                try list.appendSlice(alloc, "\r\n");
            } else {
                try list.appendSlice(alloc, "$-1\r\n");
            }
        },
        .array => |a| {
            if (a) |items| {
                try list.print(alloc, "*{d}\r\n", .{items.len});
                for (items) |item| try encodeValueInto(alloc, list, item, depth + 1);
            } else {
                try list.appendSlice(alloc, "*-1\r\n");
            }
        },
    }
}

/// Encode a command as a RESP2 array of bulk strings, owned by `alloc`.
pub fn encodeCommand(alloc: Allocator, args: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.print(alloc, "*{d}\r\n", .{args.len});
    for (args) |arg| {
        try list.print(alloc, "${d}\r\n", .{arg.len});
        try list.appendSlice(alloc, arg);
        try list.appendSlice(alloc, "\r\n");
    }
    return list.toOwnedSlice(alloc);
}

/// Parsed `redis://` URL. Password is never logged.
const RedisUrl = struct {
    host: []const u8,
    port: u16,
    password: ?[]const u8,
};

fn parseRedisUrl(url: []const u8) !RedisUrl {
    const scheme = "redis://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.InvalidUrl;
    const rest = url[scheme.len..];

    var hostport = rest;
    var password: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const userinfo = rest[0..at];
        hostport = rest[at + 1 ..];
        if (userinfo.len > 0) {
            // redis://:password@host or redis://user:password@host.
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                password = userinfo[colon + 1 ..];
            } else {
                password = userinfo;
            }
            if (password.?.len == 0) password = null;
        }
    }
    if (hostport.len == 0) return error.InvalidUrl;

    var host: []const u8 = hostport;
    var port: u16 = default_port;
    if (hostport[0] == '[') {
        // IPv6 literal: [::1]:6379
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse
            return error.InvalidUrl;
        host = hostport[1..close];
        const tail = hostport[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return error.InvalidUrl;
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        const port_text = hostport[colon + 1 ..];
        if (port_text.len > 0 and isAllDigits(port_text)) {
            host = hostport[0..colon];
            port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidUrl;
        } else {
            // A colon that is not followed by a numeric port is not a
            // valid host (bare IPv6 literals must use [::1] brackets).
            return error.InvalidUrl;
        }
    }
    if (host.len == 0) return error.InvalidUrl;
    return .{ .host = host, .port = port, .password = password };
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return s.len > 0;
}

pub const Options = struct {
    /// Accepted but currently UNUSED: std.Io.Threaded panics (TODO) if a
    /// connect timeout is supplied (see header comment). Kept so callers
    /// keep passing it and it can be wired in when the std implements it.
    connect_timeout_s: u64 = default_connect_timeout_s,
    command_timeout_s: u64 = default_command_timeout_s,
};

pub const RedisClient = struct {
    alloc: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    options: Options,
    closed: bool = false,

    /// `redis://host:port`, default port 6379. Also accepts
    /// `redis://:password@host:port` and issues AUTH when a password is
    /// present. Host may be a hostname or an IP literal.
    pub fn connect(alloc: Allocator, io: std.Io, url: []const u8) !RedisClient {
        return connectOptions(alloc, io, url, .{});
    }

    pub fn connectOptions(alloc: Allocator, io: std.Io, url: []const u8, options: Options) !RedisClient {
        const parsed = try parseRedisUrl(url);
        const address = std.Io.net.IpAddress.resolve(io, parsed.host, parsed.port) catch |err| {
            logHostPort("redis resolve failed", parsed.host, parsed.port);
            return err;
        };
        // NOTE: no connect timeout here — std.Io.Threaded panics (TODO) if
        // one is supplied; see the header comment. OS TCP timeout applies.
        const stream = std.Io.net.IpAddress.connect(&address, io, .{
            .mode = .stream,
            .timeout = .none,
        }) catch |err| {
            logHostPort("redis connect failed", parsed.host, parsed.port);
            return err;
        };
        var client = RedisClient{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .options = options,
        };
        errdefer client.close();
        logHostPort("redis connected", parsed.host, parsed.port);
        if (parsed.password) |password| {
            // Log only that auth was used, never the password.
            const reply = try client.command(alloc, &.{ "AUTH", password });
            switch (reply) {
                .simple => |s| {
                    if (!std.mem.eql(u8, s, "OK")) return error.RedisAuthFailed;
                },
                .err => {
                    logHostPort("redis auth failed", parsed.host, parsed.port);
                    return error.RedisAuthFailed;
                },
                else => return error.UnexpectedReply,
            }
            logMsg("redis auth used", .{});
        }
        return client;
    }

    pub fn close(self: *RedisClient) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
    }

    fn deadlineFromNow(self: *RedisClient, extra_ms: u64) std.Io.Clock.Timestamp {
        const total_ms = extra_ms + self.options.command_timeout_s * 1000;
        const duration = std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(total_ms)),
            .clock = .awake,
        };
        return std.Io.Clock.Timestamp.fromNow(self.io, duration);
    }

    fn remainingTimeout(self: *RedisClient, deadline: std.Io.Clock.Timestamp) !std.Io.Timeout {
        const remaining = deadline.durationFromNow(self.io);
        if (remaining.raw.nanoseconds <= 0) return error.Timeout;
        return .{ .duration = remaining };
    }

    fn writeAll(self: *RedisClient, bytes: []const u8, deadline: std.Io.Clock.Timestamp) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const timeout = try self.remainingTimeout(deadline);
            // NOTE: net_write requires data.len >= 1 (the last element is
            // the splat pattern; an empty data slice panics inside std's
            // netWritePosix), so the chunk goes in data, not header.
            const chunk: [1][]const u8 = .{bytes[off..]};
            const result = try self.io.operateTimeout(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .header = &.{},
                .data = &chunk,
                .splat = 1,
            } }, timeout);
            const n = try result.net_write;
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }

    fn readChunk(self: *RedisClient, buf: []u8, deadline: std.Io.Clock.Timestamp) !usize {
        const timeout = try self.remainingTimeout(deadline);
        var data: [1][]u8 = .{buf};
        const result = try self.io.operateTimeout(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &data,
        } }, timeout);
        const read = try result.net_read;
        return read.data_len;
    }

    /// Read one complete RESP reply, waiting at most until `deadline`.
    /// Handles replies split across many TCP segments: bytes accumulate
    /// until the parser has a whole value.
    fn readReply(self: *RedisClient, alloc: Allocator, deadline: std.Io.Clock.Timestamp) !RespValue {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(alloc);
        var chunk: [8192]u8 = undefined;
        while (true) {
            var parser = RespParser{ .data = raw.items };
            const value = parser.parseValue(alloc) catch |err| switch (err) {
                error.Incomplete => {
                    if (raw.items.len >= max_reply_bytes) return error.ReplyTooLarge;
                    const n = try self.readChunk(&chunk, deadline);
                    if (n == 0) return error.EndOfStream;
                    try raw.appendSlice(alloc, chunk[0..n]);
                    continue;
                },
                else => |e| return e,
            };
            return value;
        }
    }

    /// Send one command and return the raw reply (including `.err`
    /// replies — callers decide whether an error reply is fatal).
    pub fn command(self: *RedisClient, alloc: Allocator, args: []const []const u8) !RespValue {
        const deadline = self.deadlineFromNow(0);
        return self.commandDeadline(alloc, args, deadline);
    }

    fn commandDeadline(self: *RedisClient, alloc: Allocator, args: []const []const u8, deadline: std.Io.Clock.Timestamp) !RespValue {
        const encoded = try encodeCommand(alloc, args);
        defer alloc.free(encoded);
        try self.writeAll(encoded, deadline);
        return self.readReply(alloc, deadline);
    }

    pub fn ping(self: *RedisClient) !void {
        const reply = try self.command(self.alloc, &.{"PING"});
        switch (reply) {
            .simple => |s| {
                if (!std.mem.eql(u8, s, "PONG")) return error.UnexpectedReply;
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// Returns the value owned by `alloc`, or null when the key is missing.
    pub fn get(self: *RedisClient, alloc: Allocator, key: []const u8) !?[]u8 {
        const reply = try self.command(alloc, &.{ "GET", key });
        switch (reply) {
            .bulk => |b| {
                if (b) |bytes| return @constCast(bytes);
                return null;
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    pub fn setex(self: *RedisClient, key: []const u8, seconds: u64, value: []const u8) !void {
        var secs_buf: [32]u8 = undefined;
        const secs = std.fmt.bufPrint(&secs_buf, "{d}", .{seconds}) catch return error.InvalidArgument;
        const reply = try self.command(self.alloc, &.{ "SETEX", key, secs, value });
        switch (reply) {
            .simple => |s| {
                if (!std.mem.eql(u8, s, "OK")) return error.UnexpectedReply;
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// Returns the new entry id, owned by `alloc`.
    pub fn xadd(self: *RedisClient, alloc: Allocator, stream: []const u8, fields: []const Field) ![]u8 {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(alloc);
        try args.appendSlice(alloc, &.{ "XADD", stream, "*" });
        for (fields) |f| {
            try args.append(alloc, f.name);
            try args.append(alloc, f.value);
        }
        const reply = try self.command(alloc, args.items);
        switch (reply) {
            .bulk => |b| {
                if (b) |id| return @constCast(id);
                return error.UnexpectedReply;
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// XGROUP CREATE with MKSTREAM. A group that already exists
    /// (BUSYGROUP) is not an error.
    pub fn xgroupCreate(self: *RedisClient, stream: []const u8, group: []const u8) !void {
        const reply = try self.command(self.alloc, &.{ "XGROUP", "CREATE", stream, group, "$", "MKSTREAM" });
        switch (reply) {
            .simple => return,
            .err => |e| {
                if (std.mem.indexOf(u8, e, "BUSYGROUP") != null) return;
                return error.RedisError;
            },
            else => return error.UnexpectedReply,
        }
    }

    /// XREADGROUP GROUP <group> <consumer> COUNT <count> BLOCK <block_ms>
    /// STREAMS <stream> >. Returns the entries delivered to this consumer
    /// (empty when the block expires with nothing new). All strings are
    /// owned by `alloc`.
    pub fn xreadgroup(
        self: *RedisClient,
        alloc: Allocator,
        group: []const u8,
        consumer: []const u8,
        stream: []const u8,
        count: usize,
        block_ms: u64,
    ) ![]StreamEntry {
        return self.xreadgroupId(alloc, group, consumer, stream, count, block_ms, ">");
    }

    /// XREADGROUP with an explicit stream id: ">" for new entries,
    /// "0" for pending entries this consumer (or the group) has not
    /// acked yet — the worker-recovery path (Roadmap 4.3). Shares the
    /// reply parsing with xreadgroup.
    pub fn xreadPending(
        self: *RedisClient,
        alloc: Allocator,
        group: []const u8,
        consumer: []const u8,
        stream: []const u8,
        count: usize,
    ) ![]StreamEntry {
        return self.xreadgroupId(alloc, group, consumer, stream, count, 0, "0");
    }

    fn xreadgroupId(
        self: *RedisClient,
        alloc: Allocator,
        group: []const u8,
        consumer: []const u8,
        stream: []const u8,
        count: usize,
        block_ms: u64,
        stream_id: []const u8,
    ) ![]StreamEntry {
        var count_buf: [32]u8 = undefined;
        const count_s = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return error.InvalidArgument;
        var block_buf: [32]u8 = undefined;
        const block_s = std.fmt.bufPrint(&block_buf, "{d}", .{block_ms}) catch return error.InvalidArgument;
        const args = &[_][]const u8{
            "XREADGROUP", "GROUP", group, consumer,
            "COUNT",      count_s, "BLOCK", block_s,
            "STREAMS",    stream,  stream_id,
        };
        // The server may legitimately hold this call for block_ms.
        const deadline = self.deadlineFromNow(block_ms);
        const reply = try self.commandDeadline(alloc, args, deadline);
        switch (reply) {
            .array => |a| {
                if (a) |streams| {
                    var out: std.ArrayList(StreamEntry) = .empty;
                    errdefer out.deinit(alloc);
                    for (streams) |s| {
                        // [stream-name, [entries...]]
                        const pair = asArray(s) orelse return error.UnexpectedReply;
                        if (pair.len != 2) return error.UnexpectedReply;
                        switch (pair[1]) {
                            .array => |maybe_entries| if (maybe_entries) |entries| {
                                try out.appendSlice(alloc, try parseEntries(alloc, entries));
                            },
                            else => return error.UnexpectedReply,
                        }
                    }
                    return out.toOwnedSlice(alloc);
                }
                return &.{};
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// XRANGE <stream> - + COUNT <count>. All strings owned by `alloc`.
    pub fn xrange(self: *RedisClient, alloc: Allocator, stream: []const u8, count: usize) ![]StreamEntry {
        var count_buf: [32]u8 = undefined;
        const count_s = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return error.InvalidArgument;
        const reply = try self.command(alloc, &.{ "XRANGE", stream, "-", "+", "COUNT", count_s });
        switch (reply) {
            .array => |a| {
                if (a) |entries| return parseEntries(alloc, entries);
                return &.{};
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// XREVRANGE <stream> + - COUNT <count>: newest entries first. All
    /// strings owned by `alloc`. Use this to find a just-published entry
    /// without depending on how many entries the stream already holds.
    pub fn xrevrange(self: *RedisClient, alloc: Allocator, stream: []const u8, count: usize) ![]StreamEntry {
        var count_buf: [32]u8 = undefined;
        const count_s = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return error.InvalidArgument;
        const reply = try self.command(alloc, &.{ "XREVRANGE", stream, "+", "-", "COUNT", count_s });
        switch (reply) {
            .array => |a| {
                if (a) |entries| return parseEntries(alloc, entries);
                return &.{};
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// XACK <stream> <group> <ids...>. Returns how many entries were acked.
    pub fn xack(self: *RedisClient, alloc: Allocator, stream: []const u8, group: []const u8, ids: []const []const u8) !i64 {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(alloc);
        try args.appendSlice(alloc, &.{ "XACK", stream, group });
        try args.appendSlice(alloc, ids);
        const reply = try self.command(alloc, args.items);
        return switch (reply) {
            .integer => |n| n,
            .err => error.RedisError,
            else => error.UnexpectedReply,
        };
    }

    /// XPENDING <stream> <group>: total number of unacked entries in the
    /// group (the first element of the summary reply). Used by the worker
    /// to decide whether recovery work is pending (Roadmap 4.3).
    pub fn xpendingCount(self: *RedisClient, alloc: Allocator, stream: []const u8, group: []const u8) !i64 {
        const reply = try self.command(alloc, &.{ "XPENDING", stream, group });
        switch (reply) {
            .array => |a| {
                const items = a orelse return error.UnexpectedReply;
                if (items.len < 1) return error.UnexpectedReply;
                return switch (items[0]) {
                    .integer => |n| n,
                    else => error.UnexpectedReply,
                };
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// DEL <keys...>. Returns how many keys were deleted.
    pub fn del(self: *RedisClient, alloc: Allocator, keys: []const []const u8) !i64 {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(alloc);
        try args.append(alloc, "DEL");
        try args.appendSlice(alloc, keys);
        const reply = try self.command(alloc, args.items);
        return switch (reply) {
            .integer => |n| n,
            .err => error.RedisError,
            else => error.UnexpectedReply,
        };
    }

    /// INCR <key>. Returns the new value. Used for the query-cache epoch
    /// (Roadmap 4.5) and per-consumer usage counters (Roadmap 5.3).
    pub fn incr(self: *RedisClient, alloc: Allocator, key: []const u8) !i64 {
        const reply = try self.command(alloc, &.{ "INCR", key });
        return switch (reply) {
            .integer => |n| n,
            .err => error.RedisError,
            else => error.UnexpectedReply,
        };
    }

    /// EXPIRE <key> <seconds>. Returns true when the timeout was set.
    pub fn expire(self: *RedisClient, alloc: Allocator, key: []const u8, seconds: u64) !bool {
        var secs_buf: [32]u8 = undefined;
        const secs = std.fmt.bufPrint(&secs_buf, "{d}", .{seconds}) catch return error.InvalidArgument;
        const reply = try self.command(alloc, &.{ "EXPIRE", key, secs });
        return switch (reply) {
            .integer => |n| n == 1,
            .err => error.RedisError,
            else => error.UnexpectedReply,
        };
    }

    /// LPUSH <key> <values...>. Returns the list length after the push.
    pub fn lpush(self: *RedisClient, alloc: Allocator, key: []const u8, values: []const []const u8) !i64 {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(alloc);
        try args.appendSlice(alloc, &.{ "LPUSH", key });
        try args.appendSlice(alloc, values);
        const reply = try self.command(alloc, args.items);
        return switch (reply) {
            .integer => |n| n,
            .err => error.RedisError,
            else => error.UnexpectedReply,
        };
    }

    /// LTRIM <key> <start> <stop>. Keeps only that slice of the list.
    pub fn ltrim(self: *RedisClient, alloc: Allocator, key: []const u8, start: i64, stop: i64) !void {
        var start_buf: [32]u8 = undefined;
        var stop_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch return error.InvalidArgument;
        const e = std.fmt.bufPrint(&stop_buf, "{d}", .{stop}) catch return error.InvalidArgument;
        const reply = try self.command(alloc, &.{ "LTRIM", key, s, e });
        switch (reply) {
            .simple => return,
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }

    /// LRANGE <key> <start> <stop>. All strings owned by `alloc`.
    pub fn lrange(self: *RedisClient, alloc: Allocator, key: []const u8, start: i64, stop: i64) ![][]const u8 {
        var start_buf: [32]u8 = undefined;
        var stop_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch return error.InvalidArgument;
        const e = std.fmt.bufPrint(&stop_buf, "{d}", .{stop}) catch return error.InvalidArgument;
        const reply = try self.command(alloc, &.{ "LRANGE", key, s, e });
        switch (reply) {
            .array => |a| {
                const items = a orelse return &.{};
                var out: std.ArrayList([]const u8) = .empty;
                errdefer out.deinit(alloc);
                for (items) |item| {
                    const b = asBulk(item) orelse return error.UnexpectedReply;
                    try out.append(alloc, b);
                }
                return out.toOwnedSlice(alloc);
            },
            .err => return error.RedisError,
            else => return error.UnexpectedReply,
        }
    }
};

/// Parse XRANGE-style entries: each item is [id, [name, value, ...]].
fn parseEntries(alloc: Allocator, items: []RespValue) ![]StreamEntry {
    var out: std.ArrayList(StreamEntry) = .empty;
    errdefer out.deinit(alloc);
    for (items) |item| {
        const pair = asArray(item) orelse return error.UnexpectedReply;
        if (pair.len != 2) return error.UnexpectedReply;
        const id = asBulk(pair[0]) orelse return error.UnexpectedReply;
        const flat = asArray(pair[1]) orelse return error.UnexpectedReply;
        if (flat.len % 2 != 0) return error.UnexpectedReply;
        const fields = try alloc.alloc(Field, flat.len / 2);
        for (fields, 0..) |*f, i| {
            const name = asBulk(flat[i * 2]) orelse return error.UnexpectedReply;
            const value = asBulk(flat[i * 2 + 1]) orelse return error.UnexpectedReply;
            f.* = .{ .name = name, .value = value };
        }
        try out.append(alloc, .{ .id = id, .fields = fields });
    }
    return out.toOwnedSlice(alloc);
}

/// Safe union accessors: return null when the value is not that type
/// (direct `.bulk` access on the wrong tag would panic instead).
fn asBulk(v: RespValue) ?[]const u8 {
    return switch (v) {
        .bulk => |b| b,
        else => null,
    };
}

fn asArray(v: RespValue) ?[]RespValue {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

/// Build the fields for a `document.collected` event. Exposed (and unit
/// tested) separately from publish so the field construction can be
/// verified without a live server. `ts_millis` is unix millis, rendered
/// as decimal; the caller (publishDocumentCollected) takes it from the
/// realtime clock, which keeps this helper pure and deterministic in tests.
pub fn documentCollectedFields(alloc: Allocator, doc_id: []const u8, source_id: []const u8, ts_millis: i64) ![]Field {
    const ts = std.fmt.allocPrint(alloc, "{d}", .{ts_millis}) catch return error.OutOfMemory;
    const fields = try alloc.alloc(Field, 4);
    fields[0] = .{ .name = "type", .value = "document.collected" };
    fields[1] = .{ .name = "document_id", .value = doc_id };
    fields[2] = .{ .name = "source_id", .value = source_id };
    fields[3] = .{ .name = "ts", .value = ts };
    return fields;
}

pub const EventBus = struct {
    client: *RedisClient,

    pub fn init(client: *RedisClient) EventBus {
        return .{ .client = client };
    }

    /// Publish a document.collected event to `pulse:events`. Returns the
    /// stream entry id, owned by `alloc`.
    pub fn publishDocumentCollected(self: *EventBus, alloc: Allocator, doc_id: []const u8, source_id: []const u8) ![]u8 {
        const fields = try documentCollectedFields(alloc, doc_id, source_id, unixMillis(self.client.io));
        return self.client.xadd(alloc, events_stream, fields);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "RESP encode: all five types" {
    const alloc = testing.allocator;
    const simple = try encodeValue(alloc, .{ .simple = "OK" });
    defer alloc.free(simple);
    try testing.expectEqualStrings("+OK\r\n", simple);

    const err = try encodeValue(alloc, .{ .err = "ERR bad" });
    defer alloc.free(err);
    try testing.expectEqualStrings("-ERR bad\r\n", err);

    const integer = try encodeValue(alloc, .{ .integer = -42 });
    defer alloc.free(integer);
    try testing.expectEqualStrings(":-42\r\n", integer);

    const bulk = try encodeValue(alloc, .{ .bulk = "hello" });
    defer alloc.free(bulk);
    try testing.expectEqualStrings("$5\r\nhello\r\n", bulk);

    const nil_bulk = try encodeValue(alloc, .{ .bulk = null });
    defer alloc.free(nil_bulk);
    try testing.expectEqualStrings("$-1\r\n", nil_bulk);

    const nil_array = try encodeValue(alloc, .{ .array = null });
    defer alloc.free(nil_array);
    try testing.expectEqualStrings("*-1\r\n", nil_array);

    const empty_bulk = try encodeValue(alloc, .{ .bulk = "" });
    defer alloc.free(empty_bulk);
    try testing.expectEqualStrings("$0\r\n\r\n", empty_bulk);
}

test "RESP encode: nested arrays" {
    const alloc = testing.allocator;
    const inner = [_]RespValue{ .{ .bulk = "a" }, .{ .integer = 7 } };
    const outer = [_]RespValue{
        .{ .simple = "OK" },
        .{ .array = @constCast(&inner) },
        .{ .bulk = null },
    };
    const encoded = try encodeValue(alloc, .{ .array = @constCast(&outer) });
    defer alloc.free(encoded);
    try testing.expectEqualStrings("*3\r\n+OK\r\n*2\r\n$1\r\na\r\n:7\r\n$-1\r\n", encoded);
}

test "RESP decode: all five types" {
    const alloc = testing.allocator;

    var p1 = RespParser{ .data = "+OK\r\n" };
    const s = try p1.parseValue(alloc);
    defer freeValue(alloc, s);
    try testing.expectEqualStrings("OK", s.simple);

    var p2 = RespParser{ .data = "-ERR bad thing\r\n" };
    const e = try p2.parseValue(alloc);
    defer freeValue(alloc, e);
    try testing.expectEqualStrings("ERR bad thing", e.err);

    var p3 = RespParser{ .data = ":-42\r\n" };
    const i = try p3.parseValue(alloc);
    try testing.expectEqual(@as(i64, -42), i.integer);

    var p4 = RespParser{ .data = "$5\r\nhello\r\n" };
    const b = try p4.parseValue(alloc);
    defer freeValue(alloc, b);
    try testing.expectEqualStrings("hello", b.bulk.?);

    var p5 = RespParser{ .data = "$-1\r\n" };
    const nb = try p5.parseValue(alloc);
    try testing.expect(nb.bulk == null);

    var p6 = RespParser{ .data = "*-1\r\n" };
    const na = try p6.parseValue(alloc);
    try testing.expect(na.array == null);

    var p7 = RespParser{ .data = "*0\r\n" };
    const ea = try p7.parseValue(alloc);
    defer freeValue(alloc, ea);
    try testing.expectEqual(@as(usize, 0), ea.array.?.len);
}

test "RESP decode: nested arrays" {
    const alloc = testing.allocator;
    var p = RespParser{ .data = "*3\r\n+OK\r\n*2\r\n$1\r\na\r\n:7\r\n$-1\r\n" };
    const v = try p.parseValue(alloc);
    defer freeValue(alloc, v);
    const arr = v.array.?;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqualStrings("OK", arr[0].simple);
    try testing.expectEqual(@as(usize, 2), arr[1].array.?.len);
    try testing.expectEqualStrings("a", arr[1].array.?[0].bulk.?);
    try testing.expectEqual(@as(i64, 7), arr[1].array.?[1].integer);
    try testing.expect(arr[2].bulk == null);
    try testing.expectEqual(@as(usize, p.data.len), p.pos); // fully consumed
}

test "RESP decode: split buffer (partial reads)" {
    const alloc = testing.allocator;
    // First chunk ends mid-value: not enough bytes for the bulk body.
    var p = RespParser{ .data = "*2\r\n$5\r\nhel" };
    try testing.expectError(error.Incomplete, p.parseValue(alloc));
    // Feed the rest and retry from the start over the longer slice.
    p.pos = 0;
    p.data = "*2\r\n$5\r\nhello\r\n:99\r\n";
    const v = try p.parseValue(alloc);
    defer freeValue(alloc, v);
    try testing.expectEqual(@as(usize, 2), v.array.?.len);
    try testing.expectEqualStrings("hello", v.array.?[0].bulk.?);
    try testing.expectEqual(@as(i64, 99), v.array.?[1].integer);

    // A bare type byte with nothing after it is also incomplete.
    var q = RespParser{ .data = "+" };
    try testing.expectError(error.Incomplete, q.parseValue(alloc));
    q.pos = 0;
    q.data = "+PONG\r\n";
    const pong = try q.parseValue(alloc);
    defer freeValue(alloc, pong);
    try testing.expectEqualStrings("PONG", pong.simple);

    // Truncated CRLF / bad type byte are hard errors, not Incomplete.
    var r = RespParser{ .data = "?x\r\n" };
    try testing.expectError(error.InvalidResp, r.parseValue(alloc));
    var s = RespParser{ .data = "$3\r\nabcXX" };
    try testing.expectError(error.InvalidResp, s.parseValue(alloc));
}

test "RESP encode/decode round-trip" {
    const alloc = testing.allocator;
    const inner = [_]RespValue{ .{ .bulk = "field" }, .{ .bulk = "value with spaces" } };
    const outer = [_]RespValue{
        .{ .simple = "OK" },
        .{ .integer = 123456789 },
        .{ .array = @constCast(&inner) },
    };
    const encoded = try encodeValue(alloc, .{ .array = @constCast(&outer) });
    defer alloc.free(encoded);
    var p = RespParser{ .data = encoded };
    const decoded = try p.parseValue(alloc);
    defer freeValue(alloc, decoded);
    try testing.expectEqualStrings("OK", decoded.array.?[0].simple);
    try testing.expectEqual(@as(i64, 123456789), decoded.array.?[1].integer);
    try testing.expectEqualStrings("value with spaces", decoded.array.?[2].array.?[1].bulk.?);
}

test "command encoding: XADD and XGROUP" {
    const alloc = testing.allocator;
    const xadd = try encodeCommand(alloc, &.{ "XADD", "pulse:events", "*", "type", "document.collected" });
    defer alloc.free(xadd);
    try testing.expectEqualStrings(
        "*5\r\n$4\r\nXADD\r\n$12\r\npulse:events\r\n$1\r\n*\r\n$4\r\ntype\r\n$18\r\ndocument.collected\r\n",
        xadd,
    );
    const xgroup = try encodeCommand(alloc, &.{ "XGROUP", "CREATE", "pulse:events", "workers", "$", "MKSTREAM" });
    defer alloc.free(xgroup);
    try testing.expectEqualStrings(
        "*6\r\n$6\r\nXGROUP\r\n$6\r\nCREATE\r\n$12\r\npulse:events\r\n$7\r\nworkers\r\n$1\r\n$\r\n$8\r\nMKSTREAM\r\n",
        xgroup,
    );
}

test "EventBus field construction (no server)" {
    const alloc = testing.allocator;
    const fields = try documentCollectedFields(alloc, "doc-abc-123", "new-dawn", 1792000123456);
    const ts_str = fields[3].value;
    defer alloc.free(ts_str);
    defer alloc.free(fields);
    try testing.expectEqual(@as(usize, 4), fields.len);
    try testing.expectEqualStrings("type", fields[0].name);
    try testing.expectEqualStrings("document.collected", fields[0].value);
    try testing.expectEqualStrings("document_id", fields[1].name);
    try testing.expectEqualStrings("doc-abc-123", fields[1].value);
    try testing.expectEqualStrings("source_id", fields[2].name);
    try testing.expectEqualStrings("new-dawn", fields[2].value);
    try testing.expectEqualStrings("ts", fields[3].name);
    try testing.expectEqualStrings("1792000123456", fields[3].value);
}

test "parseRedisUrl: defaults, ports, passwords, errors" {
    const a = try parseRedisUrl("redis://localhost");
    try testing.expectEqualStrings("localhost", a.host);
    try testing.expectEqual(@as(u16, 6379), a.port);
    try testing.expect(a.password == null);

    const b = try parseRedisUrl("redis://127.0.0.1:6380");
    try testing.expectEqualStrings("127.0.0.1", b.host);
    try testing.expectEqual(@as(u16, 6380), b.port);

    const c = try parseRedisUrl("redis://:s3cret@redis.example.com:6379");
    try testing.expectEqualStrings("redis.example.com", c.host);
    try testing.expectEqualStrings("s3cret", c.password.?);

    const d = try parseRedisUrl("redis://user:pw@10.0.0.5");
    try testing.expectEqualStrings("pw", d.password.?);

    const e = try parseRedisUrl("redis://[::1]:6381");
    try testing.expectEqualStrings("::1", e.host);
    try testing.expectEqual(@as(u16, 6381), e.port);

    try testing.expectError(error.InvalidUrl, parseRedisUrl("http://localhost:6379"));
    try testing.expectError(error.InvalidUrl, parseRedisUrl("redis://"));
    try testing.expectError(error.InvalidUrl, parseRedisUrl("redis://:badport"));
    try testing.expectError(error.InvalidUrl, parseRedisUrl("redis://host:notaport"));
}

/// Recursively free a decoded value (test helper only).
fn freeValue(alloc: Allocator, v: RespValue) void {
    switch (v) {
        .simple => |s| alloc.free(s),
        .err => |s| alloc.free(s),
        .integer => {},
        .bulk => |b| if (b) |bytes| alloc.free(bytes),
        .array => |a| {
            if (a) |items| {
                for (items) |item| freeValue(alloc, item);
                alloc.free(items);
            }
        },
    }
}

/// Local black-hole server: accepts one connection and never replies.
/// Proves a dead peer surfaces error.Timeout instead of hanging.
const BlackHole = struct {
    io: std.Io,
    server: std.Io.net.Server,

    fn run(self: *BlackHole) void {
        var stream = self.server.accept(self.io) catch return;
        // Hold the connection open, send nothing, for up to 3 s.
        std.Io.sleep(self.io, .fromSeconds(3), .awake) catch {};
        stream.close(self.io);
    }
};

test "command times out against a silent peer" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind a loopback listener on an ephemeral-ish fixed port.
    var server: std.Io.net.Server = undefined;
    var port: u16 = 0;
    var p: u16 = 16379;
    while (p < 16399) : (p += 1) {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", p);
        server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch continue;
        port = p;
        break;
    }
    if (port == 0) {
        std.debug.print("skip: could not bind a loopback port for the timeout test\n", .{});
        return;
    }
    defer server.deinit(io);

    var hole = BlackHole{ .io = io, .server = server };
    const thread = try std.Thread.spawn(.{}, BlackHole.run, .{&hole});
    defer thread.join();

    const url = try std.fmt.allocPrint(alloc, "redis://127.0.0.1:{d}", .{port});
    defer alloc.free(url);
    var client = try RedisClient.connectOptions(alloc, io, url, .{
        .connect_timeout_s = 5,
        .command_timeout_s = 1,
    });
    defer client.close();

    const start = unixMillis(io);
    const result = client.ping();
    const elapsed = unixMillis(io) - start;
    try testing.expectError(error.Timeout, result);
    // 1 s deadline (plus scheduling slack), well under the 3 s hold.
    try testing.expect(elapsed < 10_000);
}

/// Test-only gate: read PULSE_TEST_REDIS_URL from /proc/self/environ.
/// This Zig's std has no getEnvVarOwned / posix.getenv, and the libc
/// getenv needs `-lc`, which the plain test command does not pass — so the
/// gate reads the process environment file directly (Linux-only; any
/// failure to read it means "not set", i.e. skip).
fn testRedisUrl(io: std.Io, alloc: Allocator) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/self/environ", .{}) catch return null;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    while (true) {
        var chunk: [8192]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch return null;
        if (n == 0) break;
        try data.appendSlice(alloc, chunk[0..n]);
    }
    const key = "PULSE_TEST_REDIS_URL=";
    var it = std.mem.splitScalar(u8, data.items, 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, key)) {
            return try alloc.dupe(u8, entry[key.len..]);
        }
    }
    return null;
}

test "live redis round-trip (gated on PULSE_TEST_REDIS_URL)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const url = (try testRedisUrl(io, alloc)) orelse {
        std.debug.print("skip: PULSE_TEST_REDIS_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    // All client calls take an arena: decoded replies allocate internals
    // (nested array containers) that belong to the caller's allocator, so
    // a per-test arena owns them and is dropped at the end.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var client = RedisClient.connect(a, io, url) catch |err| {
        std.debug.print("live redis test: connect to PULSE_TEST_REDIS_URL failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.close();

    try client.ping();

    // SETEX / GET round-trip on a unique key.
    const suffix = unixMillis(io);
    const key = try std.fmt.allocPrint(alloc, "pulse:test:get:{d}", .{suffix});
    defer alloc.free(key);
    try client.setex(key, 60, "hello-redis");
    const got = try client.get(a, key);
    try testing.expect(got != null);
    try testing.expectEqualStrings("hello-redis", got.?);
    const missing = try client.get(a, "pulse:test:missing-key-that-does-not-exist");
    try testing.expect(missing == null);

    // XADD + XREVRANGE round-trip: publish via the bus to pulse:events.
    var bus = EventBus.init(&client);
    const entry_id = try bus.publishDocumentCollected(a, "doc-live-1", "test-source");
    try testing.expect(entry_id.len > 0);
    // The bus wrote to pulse:events; check it is there too. Newest-first,
    // so the check holds no matter how many entries the stream already has.
    const ranged = try client.xrevrange(a, events_stream, 10);
    var found = false;
    for (ranged) |entry| {
        if (std.mem.eql(u8, entry.id, entry_id)) {
            found = true;
            try testing.expectEqual(@as(usize, 4), entry.fields.len);
            try testing.expectEqualStrings("document.collected", entry.fields[0].value);
            try testing.expectEqualStrings("doc-live-1", entry.fields[1].value);
        }
    }
    try testing.expect(found);

    // XGROUP CREATE + XREADGROUP round-trip (BUSYGROUP ignored on re-run).
    const group_stream = try std.fmt.allocPrint(alloc, "pulse:test:group:{d}", .{suffix});
    defer alloc.free(group_stream);
    try client.xgroupCreate(group_stream, "workers");
    try client.xgroupCreate(group_stream, "workers"); // second create: BUSYGROUP
    const fields = [_]Field{
        .{ .name = "type", .value = "document.collected" },
        .{ .name = "document_id", .value = "doc-live-2" },
    };
    const added = try client.xadd(a, group_stream, &fields);
    const read = try client.xreadgroup(a, "workers", "consumer-1", group_stream, 10, 2000);
    try testing.expectEqual(@as(usize, 1), read.len);
    try testing.expectEqualStrings(added, read[0].id);
    try testing.expectEqual(@as(usize, 2), read[0].fields.len);
    try testing.expectEqualStrings("doc-live-2", read[0].fields[1].value);
}

test "live redis streams ack/pending + misc (gated on PULSE_TEST_REDIS_URL)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const url = (try testRedisUrl(io, alloc)) orelse {
        std.debug.print("skip: PULSE_TEST_REDIS_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var client = RedisClient.connect(a, io, url) catch |err| {
        std.debug.print("live redis test: connect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.close();

    const suffix = unixMillis(io);
    const stream = try std.fmt.allocPrint(alloc, "pulse:test:ack:{d}", .{suffix});
    defer alloc.free(stream);
    try client.xgroupCreate(stream, "workers");
    const fields = [_]Field{
        .{ .name = "type", .value = "document.collected" },
        .{ .name = "document_id", .value = "doc-ack-1" },
    };
    const id1 = try client.xadd(a, stream, &fields);
    const id2 = try client.xadd(a, stream, &fields);
    // One entry read + acked, one left pending.
    const read = try client.xreadgroup(a, "workers", "c1", stream, 10, 1000);
    try testing.expectEqual(@as(usize, 2), read.len);
    try testing.expectEqual(@as(i64, 1), try client.xack(a, stream, "workers", &.{id1}));
    try testing.expectEqual(@as(i64, 1), try client.xpendingCount(a, stream, "workers"));
    // Recovery path: pending entries are re-readable by id "0".
    const pending = try client.xreadPending(a, "workers", "c1", stream, 10);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings(id2, pending[0].id);
    try testing.expectEqual(@as(i64, 1), try client.xack(a, stream, "workers", &.{id2}));
    try testing.expectEqual(@as(i64, 0), try client.xpendingCount(a, stream, "workers"));

    // INCR / EXPIRE / DEL round-trip.
    const counter = try std.fmt.allocPrint(alloc, "pulse:test:counter:{d}", .{suffix});
    defer alloc.free(counter);
    try testing.expectEqual(@as(i64, 1), try client.incr(a, counter));
    try testing.expectEqual(@as(i64, 2), try client.incr(a, counter));
    try testing.expect(try client.expire(a, counter, 60));
    try testing.expectEqual(@as(i64, 1), try client.del(a, &.{counter}));
    try testing.expectEqual(@as(i64, 0), try client.del(a, &.{counter}));

    // LPUSH / LRANGE / LTRIM round-trip.
    const list = try std.fmt.allocPrint(alloc, "pulse:test:list:{d}", .{suffix});
    defer alloc.free(list);
    try testing.expectEqual(@as(i64, 2), try client.lpush(a, list, &.{ "b", "a" }));
    const items = try client.lrange(a, list, 0, -1);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", items[0]);
    try testing.expectEqualStrings("b", items[1]);
    try client.ltrim(a, list, 0, 0);
    const trimmed = try client.lrange(a, list, 0, -1);
    try testing.expectEqual(@as(usize, 1), trimmed.len);
    try testing.expectEqual(@as(i64, 1), try client.del(a, &.{list}));
}

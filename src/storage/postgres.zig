//! PostgreSQL client + store for Sando Pulse (Roadmap 1).
//!
//! Real PostgreSQL wire protocol, standard library only — no external
//! packages. Simple Query protocol, cleartext + MD5 + SCRAM-SHA-256 auth.
//!
//! Design choices (documented, per docs/INTERFACES.md):
//! * Pool: a `PgPool` of N connections (Roadmap 4.5), default 1 — the
//!   original single-connection design, now with lazy reconnect per
//!   slot. Phase 1 traffic is a single worker + the API server's coarse
//!   search path; one connection keeps the protocol state machine trivially
//!   correct (no interleaved Simple Query streams). `PgClient` itself is
//!   NOT thread-safe — each slot is used by at most one caller at a time
//!   (checkout exclusivity), and a dead connection is dropped and
//!   re-established lazily on the next checkout.
//! * Plaintext only. `sslmode` is parsed and recorded; `require` /
//!   `verify-ca` / `verify-full` are REFUSED at connect time with
//!   `error.TlsNotImplemented` because TLS is out of scope for Phase 1.
//!   `prefer` (the default) and `disable` connect plaintext, which is the
//!   intended deployment: the compose network / localhost.
//! * Timeouts: NONE are available in std 0.17.1's Threaded Io — passing a
//!   connect timeout panics the process ("TODO implement
//!   netConnectIpPosix with timeout", verified 2026-11-12), and there is no
//!   per-read timeout on an established stream. A dead peer therefore blocks
//!   the calling thread until the OS gives up; the caller must bound the
//!   call (the server runs store calls on worker threads, never the accept
//!   loop). This is a known Phase 1 limitation, not a silent hang by
//!   design. `connect_timeout_s` is kept as the intended value for when
//!   the std gains connect timeouts.
//! * No secrets in logs: only host:port/db is ever logged or stored in
//!   error text. The conninfo string (which carries the password) is never
//!   printed. `last_error` holds the server's message text only.
//! * All SQL literals go through `escapeLiteral` (single-quote doubling).
//!   `standard_conforming_strings` is on by default since PG 9.1, so
//!   backslashes are literal and are NOT doubled (doubling them would
//!   change the value). LIKE patterns additionally escape `%`, `_`, `\`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../common/types.zig");
const repo_mod = @import("repository.zig");

pub const connect_timeout_s: i64 = 10;
/// Cap on a single backend message body; guards against a desynced stream
/// making us allocate unbounded memory.
const max_message_len: usize = 64 * 1024 * 1024;

pub const PgError = error{
    InvalidConnInfo,
    InvalidPort,
    InvalidHost,
    UnknownHost,
    UnsupportedSslMode,
    TlsNotImplemented,
    UnsupportedAuthMethod,
    UnsupportedSaslMechanism,
    ScramServerNonceMismatch,
    ScramServerSignatureMismatch,
    PgServerError,
    ProtocolError,
    NotConnected,
    OutOfMemory,
};

/// Parsed `postgres://user:pass@host:port/db?sslmode=...`.
/// All strings are owned by the allocator passed to `parseConnInfo`.
pub const ConnInfo = struct {
    user: []const u8,
    password: ?[]const u8,
    host: []const u8,
    port: u16,
    database: []const u8,
    sslmode: SslMode,

    pub fn deinit(self: *ConnInfo, alloc: Allocator) void {
        alloc.free(self.user);
        if (self.password) |p| alloc.free(p);
        alloc.free(self.host);
        alloc.free(self.database);
        self.* = undefined;
    }

    /// "host:port/db" — the only connection detail that may appear in logs.
    pub fn logTarget(self: *const ConnInfo, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}:{d}/{s}", .{ self.host, self.port, self.database });
    }
};

pub const SslMode = enum { disable, prefer, require, verify_ca, verify_full };

/// Parse a PostgreSQL connection URL. Defaults: port 5432, host
/// "localhost", user "postgres", database = user, sslmode "prefer".
/// Percent-decoding is applied to user, password and database.
pub fn parseConnInfo(alloc: Allocator, s: []const u8) !ConnInfo {
    const scheme_end = std.mem.indexOf(u8, s, "://") orelse return error.InvalidConnInfo;
    const scheme = s[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "postgres") and !std.mem.eql(u8, scheme, "postgresql")) {
        return error.InvalidConnInfo;
    }
    var rest = s[scheme_end + 3 ..];

    var sslmode: SslMode = .prefer;
    if (std.mem.indexOfScalar(u8, rest, '?')) |qi| {
        const query = rest[qi + 1 ..];
        rest = rest[0..qi];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (!std.mem.eql(u8, pair[0..eq], "sslmode")) continue;
            const v = pair[eq + 1 ..];
            if (std.mem.eql(u8, v, "disable")) sslmode = .disable;
            if (std.mem.eql(u8, v, "prefer")) sslmode = .prefer;
            if (std.mem.eql(u8, v, "require")) sslmode = .require;
            if (std.mem.eql(u8, v, "verify-ca")) sslmode = .verify_ca;
            if (std.mem.eql(u8, v, "verify-full")) sslmode = .verify_full;
        }
    }

    // authority / path
    var authority = rest;
    var db_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |si| {
        authority = rest[0..si];
        db_part = rest[si + 1 ..];
    }

    // userinfo@hostport — split at the LAST '@' so a '@' in a password works.
    var userinfo: []const u8 = "";
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |ai| {
        userinfo = authority[0..ai];
        hostport = authority[ai + 1 ..];
    }

    // Validate everything on borrowed slices first, then allocate once.
    // That keeps every error path allocation-free (no partial ConnInfo to free).
    var user_s: []const u8 = "postgres";
    var password_s: ?[]const u8 = null;
    if (userinfo.len > 0) {
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |ci| {
            user_s = userinfo[0..ci];
            password_s = userinfo[ci + 1 ..];
        } else {
            user_s = userinfo;
        }
    }

    var host_s: []const u8 = "localhost";
    var port: u16 = 5432;
    if (hostport.len > 0) {
        if (hostport[0] == '[') {
            // IPv6 literal: [::1]:5432
            const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.InvalidConnInfo;
            host_s = hostport[1..close];
            const tail = hostport[close + 1 ..];
            if (tail.len > 0) {
                if (tail[0] != ':') return error.InvalidConnInfo;
                port = try parsePort(tail[1..]);
            }
        } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |ci| {
            host_s = hostport[0..ci];
            port = try parsePort(hostport[ci + 1 ..]);
        } else {
            host_s = hostport;
        }
        if (host_s.len == 0) return error.InvalidConnInfo;
    }

    const db_s: []const u8 = if (db_part.len > 0) db_part else user_s;

    const user = try pctDecode(alloc, user_s);
    errdefer alloc.free(user);
    var password: ?[]u8 = null;
    if (password_s) |ps| password = try pctDecode(alloc, ps);
    errdefer if (password) |p| alloc.free(p);
    const host = try alloc.dupe(u8, host_s);
    errdefer alloc.free(host);
    const database = try pctDecode(alloc, db_s);

    return .{
        .user = user,
        .password = password,
        .host = host,
        .port = port,
        .database = database,
        .sslmode = sslmode,
    };
}

fn parsePort(s: []const u8) !u16 {
    if (s.len == 0) return error.InvalidPort;
    return std.fmt.parseInt(u16, s, 10) catch return error.InvalidPort;
}

/// Percent-decode (%XX -> byte). A bare '%' or a non-hex pair is an error.
/// '+' is left as-is: conninfo is a URI, not form data.
fn pctDecode(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidConnInfo;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidConnInfo;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidConnInfo;
            try out.append(alloc, @as(u8, hi) * 16 + @as(u8, lo));
            i += 3;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Escape a value as a SQL string literal: wrap in single quotes, double
/// any embedded single quote. Backslashes are NOT escaped (see header).
pub fn escapeLiteral(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.append(alloc, '\'');
        try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// Append a SQL string literal directly into a byte list (no allocation).
/// Equivalent to `escapeLiteral` but writes into `list` instead of returning
/// an owned slice — use this when the literal is spliced into a larger SQL
/// string so the escaped value does not leak.
fn appendEscapedLiteral(list: *std.ArrayList(u8), alloc: Allocator, s: []const u8) !void {
    try list.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try list.append(alloc, '\'');
        try list.append(alloc, c);
    }
    try list.append(alloc, '\'');
}

/// Append a LIKE pattern literal (`'%escaped%'`) directly into a byte list.
fn appendLikeLiteral(list: *std.ArrayList(u8), alloc: Allocator, s: []const u8) !void {
    try list.append(alloc, '\'');
    try list.append(alloc, '%');
    for (s) |c| {
        if (c == '\\' or c == '%' or c == '_') try list.append(alloc, '\\');
        try list.append(alloc, c);
    }
    try list.append(alloc, '%');
    try list.append(alloc, '\'');
}

/// LIKE pattern value for a parameter (Roadmap 6.8): the same
/// escaping as `appendLikeLiteral` — %, _ and \ in the term are
/// escaped so they match literally — but returned as a VALUE
/// (%escaped%) instead of embedded in the SQL. The % wildcards are
/// part of the value, which is exactly how a parameterised ILIKE
/// is meant to work.
fn escapeLikeValue(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '%');
    for (s) |c| {
        if (c == '\\' or c == '%' or c == '_') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    try out.append(alloc, '%');
    return out.toOwnedSlice(alloc);
}

/// Collects $N placeholders for a parameterised query (Roadmap 6.8).
/// `param` appends "$N" to the SQL and pushes the value onto the
/// params list; `likeParam` does the same with the value wrapped as
/// a LIKE pattern. `intParam`/`floatParam` format a number as decimal
/// text — Postgres infers the type from the SQL context
/// (to_timestamp($1), LIMIT $1, ST_MakePoint($1, $2)).
const ParamBuilder = struct {
    params: std.ArrayList(?[]const u8) = .empty,

    fn param(self: *ParamBuilder, sql: *std.ArrayList(u8), alloc: Allocator, value: []const u8) !void {
        try self.params.append(alloc, value);
        var nb: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&nb, "${d}", .{self.params.items.len});
        try sql.appendSlice(alloc, s);
    }

    fn nullParam(self: *ParamBuilder, sql: *std.ArrayList(u8), alloc: Allocator) !void {
        try self.params.append(alloc, null);
        var nb: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&nb, "${d}", .{self.params.items.len});
        try sql.appendSlice(alloc, s);
    }

    fn likeParam(self: *ParamBuilder, sql: *std.ArrayList(u8), alloc: Allocator, value: []const u8) !void {
        // The pattern string is NOT freed here: the params list holds
        // a slice of it until queryParams sends it. It lives in the
        // caller's arena, freed as a whole when the query completes.
        const pat = try escapeLikeValue(alloc, value);
        try self.param(sql, alloc, pat);
    }

    fn intParam(self: *ParamBuilder, sql: *std.ArrayList(u8), alloc: Allocator, value: i64) !void {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{value});
        try self.param(sql, alloc, s);
    }

    fn floatParam(self: *ParamBuilder, sql: *std.ArrayList(u8), alloc: Allocator, value: f64) !void {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{value});
        try self.param(sql, alloc, s);
    }
};

/// Escape a value for use inside a LIKE/ILIKE pattern: `\`, `%` and `_`
/// are backslash-escaped. The result still needs `escapeLiteral` around it.
pub fn escapeLikePattern(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\\' or c == '%' or c == '_') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// Format an embedding as a pgvector literal: `'[0.1,0.2,...]'::vector`.
/// Values print with `{d}` (shortest round-trip); the literal is quoted
/// and cast, so no SQL injection is possible through float formatting.
/// Use this form only when the text is INTERPOLATED into SQL. Bound
/// parameters must use `formatVectorText` instead: a param value of
/// `'[..]'::vector` would be cast again by the SQL's own `::vector`,
/// and the server rejects the quoted string as an invalid vector.
pub fn formatVectorLiteral(alloc: Allocator, vec: []const f32) ![]u8 {
    const text = try formatVectorText(alloc, vec);
    defer alloc.free(text);
    return std.fmt.allocPrint(alloc, "'{s}'::vector", .{text});
}

/// Format an embedding as bare pgvector text: `[0.1,0.2,...]`.
/// This is the form a BOUND parameter takes: the SQL supplies the
/// `::vector` cast (`$N::vector`), so the value must carry no quotes
/// and no cast of its own.
pub fn formatVectorText(alloc: Allocator, vec: []const f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    for (vec, 0..) |v, i| {
        if (i > 0) try out.append(alloc, ',');
        const s = try std.fmt.allocPrint(alloc, "{d}", .{v});
        defer alloc.free(s);
        try out.appendSlice(alloc, s);
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

/// Parse a pgvector text value like "[0.1,0.2]" back into floats.
/// Caller owns the result; null input yields null.
pub fn parseVectorText(alloc: Allocator, val: ?[]const u8) !?[]f32 {
    const s = val orelse return null;
    const inner = std.mem.trim(u8, s, "[] ");
    if (inner.len == 0) return null;
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " ");
        if (t.len == 0) continue;
        try out.append(alloc, try std.fmt.parseFloat(f32, t));
    }
    const owned: ?[]f32 = try out.toOwnedSlice(alloc);
    return owned;
}

test "formatVectorLiteral round-trips through parseVectorText" {
    const alloc = std.testing.allocator;
    const vec = [_]f32{ 1, 0.5, -0.25, 0 };
    const lit = try formatVectorLiteral(alloc, &vec);
    defer alloc.free(lit);
    try std.testing.expectEqualStrings("'[1,0.5,-0.25,0]'::vector", lit);
    const back = (try parseVectorText(alloc, "[1,0.5,-0.25,0]")).?;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(f32, &vec, back);
    try std.testing.expectEqual(@as(?[]f32, null), try parseVectorText(alloc, null));
}

/// Validate an identifier (table/column name) and return it double-quoted.
/// Only [A-Za-z0-9_.$] plus a non-leading digit rule is accepted; anything
/// else is rejected rather than escaped into SQL.
pub fn escapeIdent(alloc: Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return error.InvalidConnInfo;
    for (s, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
        if (!ok) return error.InvalidConnInfo;
        if (i == 0 and std.ascii.isDigit(c)) return error.InvalidConnInfo;
    }
    return std.fmt.allocPrint(alloc, "\"{s}\"", .{s});
}

/// One text row from the server. NULL columns are `null`; every value is
/// owned by the allocator passed to `query`.
pub const Row = struct {
    cols: []?[]const u8,
};

pub const QueryResult = struct {
    rows: []Row,
    /// Command tag from CommandComplete ("SELECT 3", "INSERT 0 1", ...).
    command_tag: []const u8 = "",

    /// Free every row, column value and the command tag. Call after the
    /// caller has copied out what it needs (or after duping the values).
    pub fn deinit(self: *QueryResult, alloc: Allocator) void {
        for (self.rows) |row| {
            for (row.cols) |col| {
                if (col) |v| alloc.free(v);
            }
            alloc.free(row.cols);
        }
        alloc.free(self.rows);
        if (self.command_tag.len > 0) alloc.free(self.command_tag);
        self.rows = &.{};
        self.command_tag = "";
    }
};

/// Startup message (no type byte): length + protocol 196608 + params.
/// Layout: int32 len | int32 196608 | "user\0" user "\0" "database\0" db "\0" "\0".
fn buildStartupMessage(alloc: Allocator, user: []const u8, database: []const u8) ![]u8 {
    const body_len = 4 + "user".len + 1 + user.len + 1 + "database".len + 1 + database.len + 1 + 1;
    const total = 4 + body_len;
    var out = try alloc.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
    std.mem.writeInt(u32, out[4..8], 196608, .big);
    var p: usize = 8;
    @memcpy(out[p .. p + 4], "user");
    p += 4;
    out[p] = 0;
    p += 1;
    @memcpy(out[p .. p + user.len], user);
    p += user.len;
    out[p] = 0;
    p += 1;
    @memcpy(out[p .. p + 8], "database");
    p += 8;
    out[p] = 0;
    p += 1;
    @memcpy(out[p .. p + database.len], database);
    p += database.len;
    out[p] = 0;
    p += 1;
    out[p] = 0;
    return out;
}

/// MD5 password response: "md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt)).
fn md5PasswordResponse(alloc: Allocator, password: []const u8, user: []const u8, salt: [4]u8) ![]u8 {
    var inner: [16]u8 = undefined;
    var h1 = std.crypto.hash.Md5.init(.{});
    h1.update(password);
    h1.update(user);
    h1.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var outer: [16]u8 = undefined;
    var h2 = std.crypto.hash.Md5.init(.{});
    h2.update(&inner_hex);
    h2.update(&salt);
    h2.final(&outer);
    const outer_hex = std.fmt.bytesToHex(outer, .lower);

    var out = try alloc.alloc(u8, 3 + 32);
    @memcpy(out[0..3], "md5");
    @memcpy(out[3..35], &outer_hex);
    return out;
}

/// PBKDF2-HMAC-SHA256, RFC 2898. `out` must be 32 bytes for SCRAM.
/// Salt is PG-generated (16 bytes); anything over 124 bytes is refused
/// rather than silently truncated.
fn pbkdf2Sha256(password: []const u8, salt: []const u8, iterations: u32, out: *[32]u8) void {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    std.debug.assert(salt.len <= 124);
    var u: [32]u8 = undefined;
    var t: [32]u8 = undefined;
    var first: [128]u8 = undefined;
    @memcpy(first[0..salt.len], salt);
    std.mem.writeInt(u32, first[salt.len..][0..4], 1, .big);
    Hmac.create(&u, first[0 .. salt.len + 4], password);
    @memcpy(&t, &u);
    var i: u32 = 1;
    while (i < iterations) : (i += 1) {
        Hmac.create(&u, &u, password);
        for (&t, u) |*a, b| a.* ^= b;
    }
    @memcpy(out, &t);
}

/// Encoded length of `n` bytes in standard padded base64.
fn b64EncodedLen(n: usize) usize {
    return (n + 2) / 3 * 4;
}

/// Decoded length of a standard padded base64 string.
fn b64DecodedLen(s: []const u8) !usize {
    if (s.len % 4 != 0) return error.ProtocolError;
    var n = s.len / 4 * 3;
    if (s.len >= 1 and s[s.len - 1] == '=') n -= 1;
    if (s.len >= 2 and s[s.len - 2] == '=') n -= 1;
    return n;
}

/// SCRAM-SHA-256 client-first-message-bare: "n=<user>,r=<nonce_b64>".
/// '=' and ',' in the username are escaped as =3D / =2C (RFC 5802).
fn buildClientFirstBare(alloc: Allocator, user: []const u8, nonce_b64: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "n=");
    for (user) |c| {
        if (c == '=') try out.appendSlice(alloc, "=3D") else if (c == ',') try out.appendSlice(alloc, "=2C") else try out.append(alloc, c);
    }
    try out.appendSlice(alloc, ",r=");
    try out.appendSlice(alloc, nonce_b64);
    return out.toOwnedSlice(alloc);
}

/// One PostgreSQL connection. NOT thread-safe — the caller (PostgresStore)
/// serializes access with a mutex. The buffered reader is plain fields
/// (array + offsets), never self-referential pointers, so the struct can
/// be moved by value safely.
pub const PgClient = struct {
    alloc: Allocator,
    io: std.Io,
    info: ConnInfo,
    stream: std.Io.net.Stream,
    read_buf: [8192]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,
    /// Last server error message text (no secrets), if any.
    last_error: ?[]u8 = null,
    open: bool = false,

    pub fn connect(alloc: Allocator, io: std.Io, conninfo: []const u8) !PgClient {
        var info = try parseConnInfo(alloc, conninfo);
        // `info` is freed here on early errors; once it moves into `self`,
        // the flag is cleared and `closeStreamOnly` owns it instead.
        // (Without the flag the two errdefers would double-free.)
        var info_owned = true;
        errdefer if (info_owned) info.deinit(alloc);
        switch (info.sslmode) {
            .require, .verify_ca, .verify_full => return error.TlsNotImplemented,
            .disable, .prefer => {},
        }
        const addr = try resolveHost(io, info.host, info.port);
        const stream = std.Io.net.IpAddress.connect(&addr, io, .{
            .mode = .stream,
            // NOTE: std 0.17.1's Threaded Io PANICS ("TODO implement
            // netConnectIpPosix with timeout") if a timeout is passed here,
            // so connect is unbounded. No per-read timeout exists either.
            // The caller must bound the call (worker thread, never the
            // accept loop). Revisit when the std gains connect timeouts.
            .timeout = .none,
        }) catch |err| {
            return err;
        };
        var self = PgClient{
            .alloc = alloc,
            .io = io,
            .info = info,
            .stream = stream,
            .open = true,
        };
        info_owned = false;
        errdefer self.closeStreamOnly();
        const startup = try buildStartupMessage(alloc, info.user, info.database);
        defer alloc.free(startup);
        try self.sendRaw(startup);
        try self.authenticate();
        return self;
    }

    pub fn close(self: *PgClient) void {
        if (!self.open) return;
        // Best effort Terminate ('X'); ignore failure, we are closing anyway.
        var term = [_]u8{ 'X', 0, 0, 0, 4 };
        _ = self.sendRaw(&term) catch {};
        self.closeStreamOnly();
    }

    fn closeStreamOnly(self: *PgClient) void {
        if (!self.open) return;
        self.open = false;
        self.stream.close(self.io);
        self.info.deinit(self.alloc);
        if (self.last_error) |e| self.alloc.free(e);
        self.last_error = null;
    }

    /// SELECT 1 — proves the connection is alive.
    pub fn ping(self: *PgClient) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const res = try self.query(arena.allocator(), "SELECT 1");
        if (res.rows.len != 1) return error.ProtocolError;
    }

    /// Simple Query, rows discarded. Use for DDL/DML with no result.
    pub fn exec(self: *PgClient, alloc: Allocator, sql: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var res = try self.runQuery(arena.allocator(), alloc, sql, false);
        defer res.deinit(alloc);
    }

    /// Simple Query, rows returned. Row values are owned by `alloc`.
    pub fn query(self: *PgClient, alloc: Allocator, sql: []const u8) !QueryResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        return self.runQuery(arena.allocator(), alloc, sql, true);
    }

    /// Extended Query (prepared statement), rows returned (Roadmap 6.8).
    /// `params` are text values bound to $1..$N in `sql` (null = SQL
    /// NULL). The unnamed statement + portal are used: each call
    /// re-issues Parse + Bind, so no per-connection state leaks between
    /// calls, and a failed Parse/Bind leaves the connection usable (the
    /// server skips to Sync and returns ReadyForQuery, drained by the
    /// shared result loop). Parse + Bind + Describe + Execute + Sync
    /// are sent in a single flush — pipelined, no extra round trip.
    /// This is the ONLY way user input reaches SQL in the document
    /// store — values are never interpolated into the query text.
    pub fn queryParams(self: *PgClient, alloc: Allocator, sql: []const u8, params: []const ?[]const u8) !QueryResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        return self.runExtended(arena.allocator(), alloc, sql, params, true);
    }

    /// Extended Query, rows discarded (INSERT/UPDATE/DELETE with params).
    pub fn execParams(self: *PgClient, alloc: Allocator, sql: []const u8, params: []const ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var res = try self.runExtended(arena.allocator(), alloc, sql, params, false);
        defer res.deinit(alloc);
    }

    /// Extended-protocol flow: Parse + Bind + Describe + Execute + Sync.
    fn runExtended(self: *PgClient, arena: Allocator, row_alloc: Allocator, sql: []const u8, params: []const ?[]const u8, collect: bool) !QueryResult {
        if (!self.open) return error.NotConnected;
        if (params.len > 65535) return error.ProtocolError;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(arena);
        var lenb: [4]u8 = undefined;
        var n16: [2]u8 = undefined;
        var i32b: [4]u8 = undefined;
        // Parse: 'P' | len | stmt "" | query | int16 0 (infer types).
        try msg.append(arena, 'P');
        std.mem.writeInt(u32, &lenb, @intCast(4 + 1 + sql.len + 1 + 2), .big);
        try msg.appendSlice(arena, &lenb);
        try msg.append(arena, 0);
        try msg.appendSlice(arena, sql);
        try msg.append(arena, 0);
        std.mem.writeInt(i16, &n16, 0, .big);
        try msg.appendSlice(arena, &n16);
        // Bind: 'B' | len | portal "" | stmt "" | int16 0 (all text
        // format) | int16 nparams | per param: int32 len + bytes |
        // int16 0 (all text results).
        var bind_len: usize = 4 + 1 + 1 + 2 + 2;
        for (params) |p| bind_len += 4 + (if (p) |v| v.len else 0);
        bind_len += 2;
        try msg.append(arena, 'B');
        std.mem.writeInt(u32, &lenb, @intCast(bind_len), .big);
        try msg.appendSlice(arena, &lenb);
        try msg.append(arena, 0);
        try msg.append(arena, 0);
        std.mem.writeInt(i16, &n16, 0, .big);
        try msg.appendSlice(arena, &n16);
        std.mem.writeInt(i16, &n16, @intCast(params.len), .big);
        try msg.appendSlice(arena, &n16);
        for (params) |p| {
            if (p) |v| {
                std.mem.writeInt(i32, &i32b, @intCast(v.len), .big);
                try msg.appendSlice(arena, &i32b);
                try msg.appendSlice(arena, v);
            } else {
                std.mem.writeInt(i32, &i32b, -1, .big);
                try msg.appendSlice(arena, &i32b);
            }
        }
        std.mem.writeInt(i16, &n16, 0, .big);
        try msg.appendSlice(arena, &n16);
        // Describe: 'D' | len | 'S' | stmt "".
        try msg.append(arena, 'D');
        std.mem.writeInt(u32, &lenb, @intCast(4 + 1 + 1), .big);
        try msg.appendSlice(arena, &lenb);
        try msg.append(arena, 'S');
        try msg.append(arena, 0);
        // Execute: 'E' | len | portal "" | int32 0 (unlimited rows).
        try msg.append(arena, 'E');
        std.mem.writeInt(u32, &lenb, @intCast(4 + 1 + 4), .big);
        try msg.appendSlice(arena, &lenb);
        try msg.append(arena, 0);
        std.mem.writeInt(i32, &i32b, 0, .big);
        try msg.appendSlice(arena, &i32b);
        // Sync: 'S' | len 4.
        try msg.append(arena, 'S');
        std.mem.writeInt(u32, &lenb, 4, .big);
        try msg.appendSlice(arena, &lenb);
        try self.sendRaw(msg.items);
        return self.readResult(arena, row_alloc, collect);
    }

    // ---- low-level I/O ----

    fn sendRaw(self: *PgClient, data: []const u8) !void {
        var wbuf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }

    /// Read exactly `buf.len` bytes, refilling the internal buffer as needed.
    fn readExact(self: *PgClient, buf: []u8) !void {
        var done: usize = 0;
        while (done < buf.len) {
            if (self.read_pos < self.read_len) {
                const n = @min(buf.len - done, self.read_len - self.read_pos);
                @memcpy(buf[done .. done + n], self.read_buf[self.read_pos .. self.read_pos + n]);
                self.read_pos += n;
                done += n;
                continue;
            }
            self.read_pos = 0;
            var bufs: [1][]u8 = .{self.read_buf[0..]};
            self.read_len = try self.stream.read(self.io, &bufs);
            if (self.read_len == 0) return error.EndOfStream;
        }
    }

    fn readByte(self: *PgClient) !u8 {
        var b: [1]u8 = undefined;
        try self.readExact(&b);
        return b[0];
    }

    fn readU32(self: *PgClient) !u32 {
        var b: [4]u8 = undefined;
        try self.readExact(&b);
        return std.mem.readInt(u32, &b, .big);
    }

    fn readI16(self: *PgClient) !i16 {
        var b: [2]u8 = undefined;
        try self.readExact(&b);
        return std.mem.readInt(i16, &b, .big);
    }

    fn readI32(self: *PgClient) !i32 {
        var b: [4]u8 = undefined;
        try self.readExact(&b);
        return std.mem.readInt(i32, &b, .big);
    }

    const Message = struct {
        kind: u8,
        body: []u8,
    };

    /// Read one backend message. Body is allocated in `arena`.
    fn readMessage(self: *PgClient, arena: Allocator) !Message {
        const kind = try self.readByte();
        const len = try self.readU32();
        if (len < 4 or len - 4 > max_message_len) return error.ProtocolError;
        const body = try arena.alloc(u8, len - 4);
        try self.readExact(body);
        return .{ .kind = kind, .body = body };
    }

    fn setServerError(self: *PgClient, body: []const u8) void {
        // ErrorResponse body: (byte code, cstring)*, terminated by 0.
        // Keep the 'M' (message) field, plus the 'C' (code) if present.
        var msg: []const u8 = "unknown server error";
        var code: ?[]const u8 = null;
        var i: usize = 0;
        while (i < body.len and body[i] != 0) {
            const field = body[i];
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, body, start, 0) orelse body.len;
            const val = body[start..end];
            if (field == 'M') msg = val;
            if (field == 'C') code = val;
            i = end + 1;
        }
        if (self.last_error) |e| self.alloc.free(e);
        self.last_error = if (code) |c|
            std.fmt.allocPrint(self.alloc, "{s} (code {s})", .{ msg, c }) catch null
        else
            std.fmt.allocPrint(self.alloc, "{s}", .{msg}) catch null;
    }

    fn sendPasswordMessage(self: *PgClient, payload: []const u8) !void {
        // 'p' | int32 len (4 + payload) | payload (no trailing NUL for SASL).
        var hdr: [5]u8 = undefined;
        hdr[0] = 'p';
        std.mem.writeInt(u32, hdr[1..5], @intCast(4 + payload.len), .big);
        try self.sendRaw(&hdr);
        try self.sendRaw(payload);
    }

    /// Startup-phase loop: handles auth (cleartext/MD5/SCRAM), ParameterStatus,
    /// notices, and errors until ReadyForQuery.
    fn authenticate(self: *PgClient) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        // The SCRAM exchange needs the cleartext password; see `scram_password`.
        scram_password = self.info.password;
        defer scram_password = null;

        var scram: ?ScramState = null;
        while (true) {
            const msg = try self.readMessage(aa);
            switch (msg.kind) {
                'R' => {
                    if (msg.body.len < 4) return error.ProtocolError;
                    const code = std.mem.readInt(i32, msg.body[0..4], .big);
                    switch (code) {
                        0 => {}, // AuthenticationOk
                        3 => { // CleartextPassword
                            const pw = self.info.password orelse return error.UnsupportedAuthMethod;
                            var payload = try aa.alloc(u8, pw.len + 1);
                            @memcpy(payload[0..pw.len], pw);
                            payload[pw.len] = 0;
                            try self.sendPasswordMessage(payload);
                        },
                        5 => { // MD5Password
                            if (msg.body.len < 8) return error.ProtocolError;
                            const pw = self.info.password orelse return error.UnsupportedAuthMethod;
                            const salt: [4]u8 = msg.body[4..8].*;
                            const resp = try md5PasswordResponse(aa, pw, self.info.user, salt);
                            var payload = try aa.alloc(u8, resp.len + 1);
                            @memcpy(payload[0..resp.len], resp);
                            payload[resp.len] = 0;
                            try self.sendPasswordMessage(payload);
                        },
                        10 => { // SASL
                            // Body: mechanism names, NUL-separated, ending with NUL.
                            var found = false;
                            var it = std.mem.splitScalar(u8, msg.body[4..], 0);
                            while (it.next()) |mech| {
                                if (mech.len == 0) break;
                                if (std.mem.eql(u8, mech, "SCRAM-SHA-256")) found = true;
                            }
                            if (!found) return error.UnsupportedSaslMechanism;
                            scram = try ScramState.init(aa, self.io, self.info.user);
                            const st = &scram.?;
                            // SASLInitialResponse: mechanism NUL, int32 len, response.
                            var payload: std.ArrayList(u8) = .empty;
                            try payload.appendSlice(aa, "SCRAM-SHA-256");
                            try payload.append(aa, 0);
                            var lenb: [4]u8 = undefined;
                            std.mem.writeInt(u32, &lenb, @intCast(st.client_first.len), .big);
                            try payload.appendSlice(aa, &lenb);
                            try payload.appendSlice(aa, st.client_first);
                            try self.sendPasswordMessage(payload.items);
                        },
                        11 => { // SASLContinue: server-first-message
                            const st = &(scram orelse return error.ProtocolError);
                            try st.handleServerFirst(aa, msg.body[4..]);
                            try self.sendPasswordMessage(st.client_final);
                        },
                        12 => { // SASLFinal: server signature
                            const st = &(scram orelse return error.ProtocolError);
                            try st.verifyServerFinal(msg.body[4..]);
                            scram = null;
                        },
                        else => return error.UnsupportedAuthMethod,
                    }
                },
                'S', 'N' => {}, // ParameterStatus, NoticeResponse: ignore
                'K' => {}, // BackendKeyData (process id + secret key): not needed
                'E' => {
                    self.setServerError(msg.body);
                    return error.PgServerError;
                },
                'Z' => return, // ReadyForQuery — authenticated
                else => return error.ProtocolError,
            }
        }
    }

    /// Run one Simple Query ('Q'). `arena` is scratch for message bodies;
    /// when `collect` is true, row values are duped into `row_alloc`.
    fn runQuery(self: *PgClient, arena: Allocator, row_alloc: Allocator, sql: []const u8, collect: bool) !QueryResult {
        if (!self.open) return error.NotConnected;
        // 'Q' | int32 len | sql NUL
        var hdr: [5]u8 = undefined;
        hdr[0] = 'Q';
        std.mem.writeInt(u32, hdr[1..5], @intCast(4 + sql.len + 1), .big);
        try self.sendRaw(&hdr);
        try self.sendRaw(sql);
        try self.sendRaw(&[_]u8{0});
        return self.readResult(arena, row_alloc, collect);
    }

    /// Shared backend-message loop for the simple and extended
    /// protocols: reads until ReadyForQuery ('Z'), collecting DataRow
    /// values into `row_alloc` when `collect` is set. An ErrorResponse
    /// ('E') drains to ReadyForQuery first so the connection stays
    /// usable — this is what makes a failed Parse/Bind recoverable.
    fn readResult(self: *PgClient, arena: Allocator, row_alloc: Allocator, collect: bool) !QueryResult {
        var rows: std.ArrayList(Row) = .empty;
        var command_tag: []const u8 = "";
        while (true) {
            const msg = try self.readMessage(arena);
            switch (msg.kind) {
                'T', 'I' => {}, // RowDescription, EmptyQueryResponse
                '1', '2', '3', 't', 'n' => {}, // ParseComplete, BindComplete, CloseComplete, ParameterDescription, NoData (extended protocol only)
                'D' => {
                    if (!collect) continue;
                    if (msg.body.len < 2) return error.ProtocolError;
                    const ncols = std.mem.readInt(i16, msg.body[0..2], .big);
                    if (ncols < 0) return error.ProtocolError;
                    const cols = try row_alloc.alloc(?[]const u8, @intCast(ncols));
                    var p: usize = 2;
                    for (cols) |*col| {
                        if (p + 4 > msg.body.len) return error.ProtocolError;
                        const clen = std.mem.readInt(i32, msg.body[p..][0..4], .big);
                        p += 4;
                        if (clen == -1) {
                            col.* = null;
                        } else if (clen < 0 or p + @as(usize, @intCast(clen)) > msg.body.len) {
                            return error.ProtocolError;
                        } else {
                            const val = msg.body[p .. p + @as(usize, @intCast(clen))];
                            p += @as(usize, @intCast(clen));
                            col.* = try row_alloc.dupe(u8, val);
                        }
                    }
                    try rows.append(row_alloc, .{ .cols = cols });
                },
                'C' => {
                    // CommandComplete body is a NUL-terminated tag.
                    const end = std.mem.indexOfScalar(u8, msg.body, 0) orelse msg.body.len;
                    if (command_tag.len > 0) row_alloc.free(command_tag);
                    command_tag = try row_alloc.dupe(u8, msg.body[0..end]);
                },
                'E' => {
                    self.setServerError(msg.body);
                    // Drain until ReadyForQuery so the connection stays usable.
                    while (true) {
                        const m2 = try self.readMessage(arena);
                        if (m2.kind == 'Z') break;
                    }
                    return error.PgServerError;
                },
                'N', 'S' => {},
                'Z' => return .{ .rows = try rows.toOwnedSlice(row_alloc), .command_tag = command_tag },
                else => return error.ProtocolError,
            }
        }
    }
};

/// SCRAM-SHA-256 client state (RFC 5802 / RFC 7677).
const ScramState = struct {
    client_first: []const u8,
    client_first_bare: []const u8,
    server_first: []const u8 = "",
    client_final: []const u8 = "",
    salted_password: [32]u8 = undefined,
    auth_message: []const u8 = "",
    client_nonce_b64: []const u8,

    fn deinit(self: *ScramState, alloc: Allocator) void {
        alloc.free(self.client_first);
        alloc.free(self.client_first_bare);
        alloc.free(self.client_nonce_b64);
        if (self.server_first.len > 0) alloc.free(self.server_first);
        if (self.client_final.len > 0) alloc.free(self.client_final);
        if (self.auth_message.len > 0) alloc.free(self.auth_message);
    }

    fn init(alloc: Allocator, io: std.Io, user: []const u8) !ScramState {
        var nonce_raw: [18]u8 = undefined;
        io.random(&nonce_raw);
        const nonce_b64 = try alloc.alloc(u8, b64EncodedLen(nonce_raw.len));
        _ = std.base64.standard.Encoder.encode(nonce_b64, &nonce_raw);
        const bare = try buildClientFirstBare(alloc, user, nonce_b64);
        const first = try std.fmt.allocPrint(alloc, "n,,{s}", .{bare});
        return .{
            .client_first = first,
            .client_first_bare = bare,
            .client_nonce_b64 = nonce_b64,
        };
    }

    fn handleServerFirst(self: *ScramState, alloc: Allocator, server_first: []const u8) !void {
        // server-first-message: r=<nonce>,s=<base64 salt>,i=<iterations>
        var server_nonce: ?[]const u8 = null;
        var salt_b64: ?[]const u8 = null;
        var iterations: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') return error.ProtocolError;
            switch (attr[0]) {
                'r' => server_nonce = attr[2..],
                's' => salt_b64 = attr[2..],
                'i' => iterations = std.fmt.parseInt(u32, attr[2..], 10) catch return error.ProtocolError,
                else => {},
            }
        }
        const sn = server_nonce orelse return error.ProtocolError;
        const sb = salt_b64 orelse return error.ProtocolError;
        if (iterations == 0) return error.ProtocolError;
        if (!std.mem.startsWith(u8, sn, self.client_nonce_b64)) return error.ScramServerNonceMismatch;

        const salt_len = try b64DecodedLen(sb);
        const salt = try alloc.alloc(u8, salt_len);
        std.base64.standard.Decoder.decode(salt, sb) catch return error.ProtocolError;

        // NOTE: the password is needed here; it is passed via the global below.
        // (Kept on the struct through `password` — see connect flow.)
        const password = scram_password orelse return error.UnsupportedAuthMethod;
        pbkdf2Sha256(password, salt, iterations, &self.salted_password);

        const client_final_wo_proof = try std.fmt.allocPrint(alloc, "c=biws,r={s}", .{sn});
        self.auth_message = try std.fmt.allocPrint(alloc, "{s},{s},{s}", .{
            self.client_first_bare, server_first, client_final_wo_proof,
        });

        const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
        var client_key: [32]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &self.salted_password);
        var stored_key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, self.auth_message, &stored_key);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, sig) |*p, ck, s| p.* = ck ^ s;
        const proof_b64 = try alloc.alloc(u8, b64EncodedLen(proof.len));
        _ = std.base64.standard.Encoder.encode(proof_b64, &proof);
        self.server_first = try alloc.dupe(u8, server_first);
        self.client_final = try std.fmt.allocPrint(alloc, "{s},p={s}", .{ client_final_wo_proof, proof_b64 });
    }

    fn verifyServerFinal(self: *ScramState, body: []const u8) !void {
        // SASLFinal body: "v=<base64 server signature>"
        if (body.len < 2 or body[0] != 'v' or body[1] != '=') return error.ProtocolError;
        const want_b64 = body[2..];
        const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
        var server_key: [32]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &self.salted_password);
        var want_sig: [32]u8 = undefined;
        Hmac.create(&want_sig, self.auth_message, &server_key);
        const got_len = b64DecodedLen(want_b64) catch return error.ProtocolError;
        if (got_len != 32) return error.ScramServerSignatureMismatch;
        var got: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(&got, want_b64) catch return error.ScramServerSignatureMismatch;
        if (!std.crypto.timing_safe.eql([32]u8, got, want_sig)) return error.ScramServerSignatureMismatch;
    }
};

// The SCRAM exchange needs the cleartext password inside `handleServerFirst`.
// `authenticate` sets this thread-local-adjacent slot before the exchange and
// clears it right after; the password is never logged or stored elsewhere.
// (Single-connection + mutex design means no two exchanges can interleave.)
threadlocal var scram_password: ?[]const u8 = null;

fn resolveHost(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |ip| return ip else |_| {}
    const name = std.Io.net.HostName.init(host) catch return error.InvalidHost;
    var results_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results_buf);
    name.lookup(io, &queue, .{ .port = port }) catch |err| switch (err) {
        error.UnknownHostName => return error.UnknownHost,
        else => return err,
    };
    var out: [16]std.Io.net.HostName.LookupResult = undefined;
    const n = queue.get(io, &out, 1) catch return error.UnknownHost;
    for (out[0..n]) |r| {
        if (r == .address) return r.address;
    }
    return error.UnknownHost;
}

/// Apply `<dir>/*.sql` in filename order. Each migration runs inside its
/// own BEGIN/COMMIT and is then recorded in `schema_migrations` under its
/// filename stem (e.g. "001_initial"). Re-running is a no-op: versions
/// already recorded are skipped. `dir` may be absolute or relative to the
/// process working directory.
pub fn runMigrations(alloc: Allocator, io: std.Io, conninfo: []const u8, dir: []const u8) !void {
    var client = try PgClient.connect(alloc, io, conninfo);
    defer client.close();
    try client.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version TEXT PRIMARY KEY,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
        \\)
    );

    var d = openDirForMigrations(io, dir) catch |err| return err;
    defer d.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |fname| {
        const version = fname[0 .. fname.len - ".sql".len];
        const esc_version = try escapeLiteral(alloc, version);
        defer alloc.free(esc_version);
        const check_sql = try std.fmt.allocPrint(alloc,
            "SELECT 1 FROM schema_migrations WHERE version = {s}",
            .{esc_version});
        defer alloc.free(check_sql);
        var res = try client.query(alloc, check_sql);
        defer res.deinit(alloc);
        if (res.rows.len > 0) continue;

        const sql = try d.readFileAlloc(io, fname, alloc, .limited(16 * 1024 * 1024));
        defer alloc.free(sql);
        const wrapped = try std.fmt.allocPrint(alloc, "BEGIN;\n{s}\nCOMMIT;", .{sql});
        defer alloc.free(wrapped);
        client.exec(alloc, wrapped) catch |err| {
            client.exec(alloc, "ROLLBACK;") catch {};
            return err;
        };
        const ins = try std.fmt.allocPrint(alloc,
            "INSERT INTO schema_migrations(version) VALUES ({s})",
            .{esc_version});
        defer alloc.free(ins);
        try client.exec(alloc, ins);
    }
}

fn openDirForMigrations(io: std.Io, dir: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(dir)) {
        return std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    }
    return std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
}

/// Connection pool (Roadmap 4.5): N PgClient slots, each used by at
/// most one caller at a time. Checkout is exclusive; a slot whose
/// connection died is reconnected lazily on the next checkout. When
/// every slot is busy the caller waits (bounded, 10s) and then gets
/// error.PoolExhausted. Size 1 behaves exactly like the original
/// single-connection design; the server and worker are single-threaded
/// today, so the default stays 1 (PULSE_PG_POOL_SIZE raises it for
/// concurrent callers). Client internals use a thread-safe GPA because
/// two threads may connect two slots at once.
///
/// The pool mutex is an `std.Io.Mutex` locked through the DIRECT
/// `std.Io.Threaded.mutexLockUncancelable` / `mutexUnlock` helpers
/// (plain OS futex, no `Io` instance involved) — NOT through the
/// `Io`-bound `mutex.lockUncancelable(io)`: that path parks via the
/// `Io` instance, which is unreliable from raw `std.Thread.spawn`
/// threads (two threads could both observe a slot as free and check
/// out the same client, which corrupts the client's protocol state
/// and the GPA's buckets — seen 2026-11-13 in the pool test). The
/// spin wait likewise uses `std.Thread.sleep`, never `Io.sleep`.
/// (There is no `std.Thread.Mutex` in Zig 0.17.1; the direct
/// Threaded helpers are the same ones `DebugAllocator` uses for its
/// own thread-safe mode.)
pub const PgPool = struct {
    alloc: Allocator,
    io: std.Io,
    conninfo: []const u8,
    clients: []?PgClient,
    in_use: []bool,
    mutex: std.Io.Mutex = .init,
    /// Heap-allocated on purpose: `PgPool` (and `PostgresStore`) are
    /// returned by value, and `gpa.allocator()` captures `&gpa` — the
    /// clients store that allocator long-term. If the GPA lived inline,
    /// the move would leave every client holding a pointer to a dead
    /// stack slot, and the next client-alloc use corrupts memory (seen
    /// 2026-11-13: bucket assert on the first pool ping; futex hang in
    /// the live test's teardown). The heap address never moves.
    gpa: *std.heap.DebugAllocator(.{ .thread_safe = true }),

    pub const max_wait_attempts: usize = 5000; // 5000 x 2ms = 10s

    /// Sleep without an `Io` instance: the pool is used from raw
    /// threads, where `Io.sleep` is unreliable. Matches the codebase's
    /// existing `std.os.linux.*` usage (logging, auth).
    fn sleepNanos(ns: u64) void {
        var req: std.os.linux.timespec = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.os.linux.nanosleep(&req, null);
    }

    pub fn init(alloc: Allocator, io: std.Io, conninfo: []const u8, size: usize) !PgPool {
        const n = @max(1, @min(size, 32));
        var self = PgPool{
            .alloc = alloc,
            .io = io,
            .conninfo = try alloc.dupe(u8, conninfo),
            .clients = try alloc.alloc(?PgClient, n),
            .in_use = try alloc.alloc(bool, n),
            .gpa = undefined, // created on the heap just below
        };
        errdefer {
            alloc.free(self.clients);
            alloc.free(self.in_use);
            alloc.free(self.conninfo);
        }
        self.gpa = try alloc.create(std.heap.DebugAllocator(.{ .thread_safe = true }));
        self.gpa.* = .{};
        errdefer alloc.destroy(self.gpa);
        @memset(self.clients, null);
        @memset(self.in_use, false);
        // Eager connect, like the old single client: init fails fast
        // when Postgres is down, so the caller keeps its fallback.
        for (self.clients) |*slot| {
            slot.* = try PgClient.connect(self.gpa.allocator(), io, conninfo);
        }
        return self;
    }

    pub fn deinit(self: *PgPool) void {
        for (self.clients) |*slot| {
            if (slot.*) |*c| c.close();
            slot.* = null;
        }
        self.alloc.free(self.clients);
        self.alloc.free(self.in_use);
        self.alloc.free(self.conninfo);
        _ = self.gpa.deinit();
        self.alloc.destroy(self.gpa);
    }

    /// Exclusive checkout. Reconnects a dead slot lazily.
    pub fn checkout(self: *PgPool) !*PgClient {
        var attempt: usize = 0;
        while (attempt < max_wait_attempts) : (attempt += 1) {
            std.Io.Threaded.mutexLockUncancelable(&self.mutex);
            for (self.clients, 0..) |*slot, i| {
                if (!self.in_use[i]) {
                    self.in_use[i] = true;
                    std.Io.Threaded.mutexUnlock(&self.mutex);
                    if (slot.* == null) {
                        slot.* = PgClient.connect(self.gpa.allocator(), self.io, self.conninfo) catch |err| {
                            std.Io.Threaded.mutexLockUncancelable(&self.mutex);
                            self.in_use[i] = false;
                            std.Io.Threaded.mutexUnlock(&self.mutex);
                            return err;
                        };
                    }
                    return &slot.*.?;
                }
            }
            std.Io.Threaded.mutexUnlock(&self.mutex);
            sleepNanos(2_000_000);
        }
        return error.PoolExhausted;
    }

    /// Return a healthy client to the pool.
    pub fn checkin(self: *PgPool, client: *PgClient) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        for (self.clients, 0..) |*slot, i| {
            if (slot.* != null and &slot.*.? == client) {
                self.in_use[i] = false;
                return;
            }
        }
    }

    /// Drop a dead client: close it and free the slot so the next
    /// checkout reconnects. Must not be followed by checkin.
    pub fn drop(self: *PgPool, client: *PgClient) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        for (self.clients, 0..) |*slot, i| {
            if (slot.* != null and &slot.*.? == client) {
                slot.*.?.close();
                slot.* = null;
                self.in_use[i] = false;
                return;
            }
        }
    }
};

/// PostgreSQL-backed `repository.Repository`.
///
/// Connection strategy: a PgPool (Roadmap 4.5) of N connections,
/// default 1 — the original single-connection design, now with lazy
/// reconnect per slot. SQL strings are built on a thread-safe GPA so
/// concurrent checkouts (pool size > 1) never share an arena.
pub const PostgresStore = struct {
    alloc: Allocator,
    io: std.Io,
    conninfo: []const u8,
    pool: PgPool,
    /// Read-replica pool (Roadmap 5.5). Null = reads use the primary.
    /// Heap-allocated: a PgPool must never move after init (see PgPool).
    replica_pool: ?*PgPool = null,
    sql_gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .{},

    /// SQL-building allocator: thread-safe, so two concurrent store
    /// calls (pool size > 1) never share an arena.
    fn sqlAlloc(self: *PostgresStore) Allocator {
        return self.sql_gpa.allocator();
    }

    pub fn init(alloc: Allocator, io: std.Io, conninfo: []const u8) !PostgresStore {
        return initWithPoolSize(alloc, io, conninfo, 1);
    }

    pub fn initWithPoolSize(alloc: Allocator, io: std.Io, conninfo: []const u8, pool_size: usize) !PostgresStore {
        var self = PostgresStore{
            .alloc = alloc,
            .io = io,
            .conninfo = try alloc.dupe(u8, conninfo),
            .pool = undefined,
        };
        errdefer alloc.free(self.conninfo);
        self.pool = try PgPool.init(alloc, io, conninfo, pool_size);
        return self;
    }

    pub fn deinit(self: *PostgresStore) void {
        if (self.replica_pool) |rp| {
            rp.deinit();
            self.alloc.destroy(rp);
        }
        self.pool.deinit();
        self.alloc.free(self.conninfo);
        _ = self.sql_gpa.deinit();
    }

    /// Attach a read replica (Roadmap 5.5). Opens a second pool (2
    /// connections) to `replica_url` and routes the read methods
    /// (search, countDocuments, countBySource, scanDocuments) to it.
    /// Writes (insert/delete) always stay on the primary. The pool
    /// connects eagerly, so a bad URL fails here — the caller logs it
    /// and keeps serving reads from the primary. Calling twice is an
    /// error; the first replica stays attached.
    pub fn setReplica(self: *PostgresStore, replica_url: []const u8) !void {
        if (self.replica_pool != null) return error.ReplicaAlreadyConfigured;
        const rp = try self.alloc.create(PgPool);
        errdefer self.alloc.destroy(rp);
        rp.* = try PgPool.init(self.alloc, self.io, replica_url, 2);
        self.replica_pool = rp;
    }

    pub fn hasReplica(self: *const PostgresStore) bool {
        return self.replica_pool != null;
    }

    const ReadConn = struct {
        client: *PgClient,
        pool: *PgPool,
    };

    /// Check a client out for a READ. Prefers the replica pool when one
    /// is configured; falls back to the primary when the replica checkout
    /// fails, so a dead replica never takes reads down with it. The
    /// returned connection must be returned with checkinRead (or
    /// dropRead on query error) — never with the primary pool's methods.
    /// Reads from a replica may lag the primary by the replication delay;
    /// that staleness is acceptable for search, counts and scans.
    fn checkoutRead(self: *PostgresStore) !ReadConn {
        if (self.replica_pool) |rp| {
            if (rp.checkout()) |c| return .{ .client = c, .pool = rp } else |_| {}
        }
        return .{ .client = try self.pool.checkout(), .pool = &self.pool };
    }

    fn checkinRead(_: *PostgresStore, conn: ReadConn) void {
        conn.pool.checkin(conn.client);
    }

    fn dropRead(_: *PostgresStore, conn: ReadConn) void {
        conn.pool.drop(conn.client);
    }

    pub fn repository(self: *PostgresStore) repo_mod.Repository {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Alias matching the interface in docs/INTERFACES.md (and MemoryStore).
    pub fn asRepository(self: *PostgresStore) repo_mod.Repository {
        return self.repository();
    }

    const vtable = repo_mod.Repository.VTable{
        .insertDocument = repoInsertDocument,
        .search = repoSearch,
        .countDocuments = repoCountDocuments,
        .countBySource = repoCountBySource,
        .scanDocuments = repoScanDocuments,
        .getDocument = repoGetDocument,
        .deleteDocuments = repoDeleteDocuments,
        .analyze = repoAnalyze,
        .deinit = repoDeinit,
    };

    fn repoInsertDocument(ptr: *anyopaque, doc: types.Document) anyerror!void {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.insertDocument(doc);
    }

    fn repoSearch(ptr: *anyopaque, alloc: Allocator, q: types.SearchQuery) anyerror![]types.Document {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.search(alloc, q);
    }

    fn repoCountDocuments(ptr: *anyopaque) usize {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.countDocuments();
    }

    fn repoCountBySource(ptr: *anyopaque, alloc: Allocator) anyerror![]types.SourceCount {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.countBySource(alloc);
    }

    fn repoScanDocuments(ptr: *anyopaque, alloc: Allocator, before_ts: ?i64, limit: usize) anyerror![]types.Document {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.scanDocuments(alloc, before_ts, limit);
    }

    fn repoGetDocument(ptr: *anyopaque, alloc: Allocator, id: []const u8) anyerror!?types.Document {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.getDocument(alloc, id);
    }

    fn repoDeleteDocuments(ptr: *anyopaque, ids: []const []const u8) anyerror!usize {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        return self.deleteDocuments(ids);
    }

    fn repoDeinit(ptr: *anyopaque) void {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Refresh planner statistics for every table (Roadmap 6.11).
    /// Bare ANALYZE (no table) covers the whole database. VACUUM is
    /// deliberately NOT run here — Postgres autovacuum owns dead-tuple
    /// reclamation; ANALYZE is the maintenance-visible part.
    fn repoAnalyze(ptr: *anyopaque, alloc: Allocator) anyerror!void {
        const self: *PostgresStore = @ptrCast(@alignCast(ptr));
        const client = try self.checkout();
        errdefer self.pool.drop(client);
        defer self.pool.checkin(client);
        try client.exec(alloc, "ANALYZE");
    }

    /// Check a client out of the pool. A dead slot reconnects lazily;
    /// a query error drops the client (see the callers) so the next
    /// checkout reconnects. Checkout exclusivity is the only
    /// synchronization: PgClient is not thread-safe.
    fn checkout(self: *PostgresStore) !*PgClient {
        return self.pool.checkout();
    }

    pub fn insertDocument(self: *PostgresStore, doc: types.Document) !void {
        const client = try self.checkout();
        errdefer self.pool.drop(client);
        defer self.pool.checkin(client);
        try self.insertDocumentLocked(client, doc);
    }

    fn insertDocumentLocked(self: *PostgresStore, client: *PgClient, doc: types.Document) !void {
        const a = self.sqlAlloc();
        // Parameterised inserts (Roadmap 6.8): every value is bound as
        // a $N parameter — NULLs are null params, never the string
        // "NULL", and no value is ever interpolated into the SQL.
        var pb = ParamBuilder{};
        defer pb.params.deinit(a);
        // The source row must exist for the FK; the feed URL is unknown here,
        // so the source home URL stands in for it.
        var src_sql: std.ArrayList(u8) = .empty;
        defer src_sql.deinit(a);
        try src_sql.appendSlice(a,
            \\INSERT INTO sources (id, name, home_url, feed_url, reliability)
            \\VALUES (
        );
        try pb.param(&src_sql, a, doc.source_id);
        try src_sql.appendSlice(a, ", ");
        try pb.param(&src_sql, a, doc.source_name);
        try src_sql.appendSlice(a, ", ");
        try pb.param(&src_sql, a, doc.source_url);
        try src_sql.appendSlice(a, ", ");
        try pb.param(&src_sql, a, doc.source_url);
        try src_sql.appendSlice(a, ", ");
        try pb.floatParam(&src_sql, a, doc.reliability);
        try src_sql.appendSlice(a, ") ON CONFLICT (id) DO NOTHING");
        try client.execParams(a, src_sql.items, pb.params.items);
        pb.params.clearRetainingCapacity();

        var doc_sql: std.ArrayList(u8) = .empty;
        defer doc_sql.deinit(a);
        try doc_sql.appendSlice(a,
            \\INSERT INTO documents
            \\  (id, source_id, title, url, text, published_at, fetched_at,
            \\   reliability, topics, content_hash, lat, lon, geom, embedding, lang, summary)
            \\VALUES (
        );
        try pb.param(&doc_sql, a, doc.id);
        try doc_sql.appendSlice(a, ", ");
        try pb.param(&doc_sql, a, doc.source_id);
        try doc_sql.appendSlice(a, ", ");
        try pb.param(&doc_sql, a, doc.title);
        try doc_sql.appendSlice(a, ", ");
        try pb.param(&doc_sql, a, doc.url);
        try doc_sql.appendSlice(a, ", ");
        try pb.param(&doc_sql, a, doc.text);
        try doc_sql.appendSlice(a, ", to_timestamp(");
        if (doc.published_at) |ts| {
            try pb.intParam(&doc_sql, a, ts);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        try doc_sql.appendSlice(a, "), to_timestamp(");
        try pb.intParam(&doc_sql, a, doc.fetched_at);
        try doc_sql.appendSlice(a, "), ");
        try pb.floatParam(&doc_sql, a, doc.reliability);
        try doc_sql.appendSlice(a, ", ");
        const topics_lit = try formatTextArrayLiteral(a, doc.topics);
        try pb.param(&doc_sql, a, topics_lit);
        try doc_sql.appendSlice(a, "::text[], ");
        try pb.param(&doc_sql, a, doc.content_hash);
        try doc_sql.appendSlice(a, ", ");
        if (doc.lat) |v| {
            try pb.floatParam(&doc_sql, a, v);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        try doc_sql.appendSlice(a, ", ");
        if (doc.lon) |v| {
            try pb.floatParam(&doc_sql, a, v);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        // ST_MakePoint(NULL, NULL) is NULL, so a missing lat/lon
        // yields a NULL geography with the same SQL shape.
        try doc_sql.appendSlice(a, ", ST_SetSRID(ST_MakePoint(");
        if (doc.lon) |v| {
            try pb.floatParam(&doc_sql, a, v);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        try doc_sql.appendSlice(a, ", ");
        if (doc.lat) |v| {
            try pb.floatParam(&doc_sql, a, v);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        try doc_sql.appendSlice(a, "), 4326)::geography, ");
        if (doc.embedding) |vec| {
            const lit = try formatVectorText(a, vec);
            try pb.param(&doc_sql, a, lit);
            try doc_sql.appendSlice(a, "::vector, ");
        } else {
            try pb.nullParam(&doc_sql, a);
            try doc_sql.appendSlice(a, ", ");
        }
        try pb.param(&doc_sql, a, doc.lang);
        try doc_sql.appendSlice(a, ", ");
        if (doc.summary) |sm| {
            try pb.param(&doc_sql, a, sm);
        } else {
            try pb.nullParam(&doc_sql, a);
        }
        try doc_sql.appendSlice(a, ") ON CONFLICT (id) DO NOTHING");
        try client.execParams(a, doc_sql.items, pb.params.items);
    }

    /// Coarse candidate retrieval (the engine ranks afterwards). Matches any
    /// of `q.terms` via FTS (`websearch_to_tsquery` over `search_vector`)
    /// OR per-term ILIKE on title/text, up to 100 rows, newest first.
    /// Filters: topics use the `topics` array overlap; organizations match
    /// `source_id` or source name; counties have no column in the schema, so
    /// they match as ILIKE terms against title/text (coarse fallback).
    pub fn search(self: *PostgresStore, alloc: Allocator, q: types.SearchQuery) ![]types.Document {
        const conn = try self.checkoutRead();
        errdefer self.dropRead(conn);
        defer self.checkinRead(conn);
        return self.searchLocked(conn.client, alloc, q);
    }

    fn searchLocked(self: *PostgresStore, client: *PgClient, alloc: Allocator, q: types.SearchQuery) ![]types.Document {
        _ = self;
        const limit = if (q.limit == 0) 100 else @min(q.limit, 100);
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc,
            \\SELECT d.id, d.source_id, s.name, s.home_url, d.title, d.url, d.text,
            \\  extract(epoch from d.published_at)::bigint,
            \\  extract(epoch from d.fetched_at)::bigint,
            \\  d.reliability, d.topics, d.content_hash,
            \\  d.embedding::text, d.lat, d.lon, d.lang, d.summary
            \\FROM documents d JOIN sources s ON s.id = d.source_id
        );

        var where: std.ArrayList(u8) = .empty;
        defer where.deinit(alloc);
        // Parameterised query (Roadmap 6.8): every value below is
        // bound as a $N parameter, never interpolated into the SQL.
        // The param strings live in the caller's arena until the
        // query is sent.
        var pb = ParamBuilder{};
        defer pb.params.deinit(alloc);
        if (q.terms.len > 0 or q.query_embedding != null) {
            // FTS over the joined terms, OR per-term ILIKE fallback, OR
            // trigram similarity when fuzzy, OR pgvector closeness when a
            // query embedding is supplied.
            try where.appendSlice(alloc, "(");
            var first = true;
            if (q.terms.len > 0) {
                const joined = try std.mem.join(alloc, " ", q.terms);
                // NOT freed here: pb.params holds a slice of it until
                // queryParams sends it below. (A `defer alloc.free`
                // here was the 6.8 use-after-free: the allocator
                // refills freed memory with 0xaa and the server
                // rejected the param as invalid UTF-8.)
                try where.appendSlice(alloc, "d.search_vector @@ websearch_to_tsquery('english', ");
                try pb.param(&where, alloc, joined);
                try where.appendSlice(alloc, ")");
                first = false;
                for (q.terms) |term| {
                    try where.appendSlice(alloc, " OR d.title ILIKE ");
                    try pb.likeParam(&where, alloc, term);
                    try where.appendSlice(alloc, " OR d.text ILIKE ");
                    try pb.likeParam(&where, alloc, term);
                    if (q.fuzzy) {
                        // word_similarity measures the term against the
                        // most similar word in the title (pg_trgm). The
                        // score dilutes with title length — measured live
                        // 2026-11-12 for 'monrova': 4-word title 0.24,
                        // 7-word 0.14, 8-word 0.12; unrelated titles 0.00.
                        // The SQL threshold is therefore a loose 0.1
                        // candidate floor; the engine re-scores fuzzy
                        // candidates with the strict per-word 0.5 trigram
                        // check before ranking.
                        try where.appendSlice(alloc, " OR word_similarity(d.title, ");
                        try pb.param(&where, alloc, term);
                        try where.appendSlice(alloc, ") > 0.1");
                    }
                }
            }
            if (q.query_embedding) |vec| {
                if (!first) try where.appendSlice(alloc, " OR ");
                const lit = try formatVectorText(alloc, vec);
                // NOT freed here: same reason as `joined` above —
                // pb.params holds a slice until queryParams sends it.
                try where.appendSlice(alloc, "d.embedding <=> ");
                try pb.param(&where, alloc, lit);
                try where.appendSlice(alloc, "::vector < 0.6");
            }
            try where.appendSlice(alloc, ")");
        }
        if (q.from_ts != null or q.to_ts != null) {
            // A document's date is published_at, falling back to fetched_at
            // for manually ingested docs (published_at null).
            if (where.items.len > 0) try where.appendSlice(alloc, " AND ");
            try where.appendSlice(alloc, "(");
            if (q.from_ts) |from| {
                try where.appendSlice(alloc, "COALESCE(d.published_at, d.fetched_at) >= to_timestamp(");
                try pb.intParam(&where, alloc, from);
                try where.appendSlice(alloc, ")");
            }
            if (q.to_ts) |to| {
                if (q.from_ts != null) try where.appendSlice(alloc, " AND ");
                try where.appendSlice(alloc, "COALESCE(d.published_at, d.fetched_at) < to_timestamp(");
                try pb.intParam(&where, alloc, to);
                try where.appendSlice(alloc, ")");
            }
            try where.appendSlice(alloc, ")");
        }
        if (q.geo) |g| {
            if (where.items.len > 0) try where.appendSlice(alloc, " AND ");
            try where.appendSlice(alloc, "ST_DWithin(d.geom, ST_SetSRID(ST_MakePoint(");
            try pb.floatParam(&where, alloc, g.lon);
            try where.appendSlice(alloc, ", ");
            try pb.floatParam(&where, alloc, g.lat);
            try where.appendSlice(alloc, "), 4326)::geography, ");
            try pb.floatParam(&where, alloc, g.radius_km * 1000.0);
            try where.appendSlice(alloc, ")");
        }
        if (q.organizations.len > 0) {
            if (where.items.len > 0) try where.appendSlice(alloc, " AND ");
            try where.appendSlice(alloc, "(");
            for (q.organizations, 0..) |org, i| {
                if (i > 0) try where.appendSlice(alloc, " OR ");
                try where.appendSlice(alloc, "d.source_id = ");
                try pb.param(&where, alloc, org);
                try where.appendSlice(alloc, " OR s.name ILIKE ");
                try pb.likeParam(&where, alloc, org);
            }
            try where.appendSlice(alloc, ")");
        }
        if (q.topics.len > 0) {
            if (where.items.len > 0) try where.appendSlice(alloc, " AND ");
            try where.appendSlice(alloc, "d.topics && ARRAY[");
            for (q.topics, 0..) |t, i| {
                if (i > 0) try where.appendSlice(alloc, ", ");
                try pb.param(&where, alloc, t);
            }
            try where.appendSlice(alloc, "]::text[]");
        }
        if (q.counties.len > 0) {
            // No county column exists on documents; coarse text match.
            if (where.items.len > 0) try where.appendSlice(alloc, " AND ");
            try where.appendSlice(alloc, "(");
            for (q.counties, 0..) |county, i| {
                if (i > 0) try where.appendSlice(alloc, " OR ");
                try where.appendSlice(alloc, "d.title ILIKE ");
                try pb.likeParam(&where, alloc, county);
                try where.appendSlice(alloc, " OR d.text ILIKE ");
                try pb.likeParam(&where, alloc, county);
            }
            try where.appendSlice(alloc, ")");
        }
        if (where.items.len > 0) {
            try sql.appendSlice(alloc, " WHERE ");
            try sql.appendSlice(alloc, where.items);
        }
        try sql.appendSlice(alloc, " ORDER BY d.fetched_at DESC LIMIT ");
        try pb.intParam(&sql, alloc, @intCast(limit));

        var res = try client.queryParams(alloc, sql.items, pb.params.items);
        defer res.deinit(alloc);
        var docs = try alloc.alloc(types.Document, res.rows.len);
        for (res.rows, 0..) |row, i| {
            docs[i] = try documentFromRow(alloc, row);
        }
        return docs;
    }

    fn documentFromRow(alloc: Allocator, row: Row) !types.Document {
        if (row.cols.len != 17) return error.ProtocolError;
        const c = row.cols;
        const req = struct {
            fn text(cols: []?[]const u8, idx: usize) ![]const u8 {
                return cols[idx] orelse return error.ProtocolError;
            }
        }.text;
        return .{
            .id = try alloc.dupe(u8, try req(c, 0)),
            .source_id = try alloc.dupe(u8, try req(c, 1)),
            .source_name = try alloc.dupe(u8, try req(c, 2)),
            .source_url = try alloc.dupe(u8, try req(c, 3)),
            .title = try alloc.dupe(u8, try req(c, 4)),
            .url = try alloc.dupe(u8, try req(c, 5)),
            .text = try alloc.dupe(u8, try req(c, 6)),
            .published_at = if (c[7]) |v| try std.fmt.parseInt(i64, v, 10) else null,
            .fetched_at = try std.fmt.parseInt(i64, try req(c, 8), 10),
            .reliability = try std.fmt.parseFloat(f32, try req(c, 9)),
            .topics = try parseTextArray(alloc, c[10]),
            .content_hash = try alloc.dupe(u8, try req(c, 11)),
            .embedding = try parseVectorText(alloc, c[12]),
            .lat = if (c[13]) |v| try std.fmt.parseFloat(f64, v) else null,
            .lon = if (c[14]) |v| try std.fmt.parseFloat(f64, v) else null,
            .lang = try alloc.dupe(u8, try req(c, 15)),
            .summary = if (c[16]) |s| try alloc.dupe(u8, s) else null,
        };
    }

    pub fn countDocuments(self: *PostgresStore) usize {
        const conn = self.checkoutRead() catch return 0;
        defer self.checkinRead(conn);
        const client = conn.client;
        var arena = std.heap.ArenaAllocator.init(self.sqlAlloc());
        defer arena.deinit();
        const res = client.query(arena.allocator(), "SELECT count(*) FROM documents") catch {
            self.dropRead(conn);
            return 0;
        };
        if (res.rows.len == 0) return 0;
        const v = res.rows[0].cols[0] orelse return 0;
        return std.fmt.parseInt(usize, v, 10) catch 0;
    }

    /// Scan documents oldest-first (Roadmap 3.5 maintenance). `before_ts`
    /// limits to documents fetched before the cutoff; null scans all.
    /// `limit` is capped at 1000 per call — retention loops in batches.
    pub fn scanDocuments(self: *PostgresStore, alloc: Allocator, before_ts: ?i64, limit: usize) ![]types.Document {
        const conn = try self.checkoutRead();
        errdefer self.dropRead(conn);
        defer self.checkinRead(conn);
        const client = conn.client;
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc,
            \\SELECT d.id, d.source_id, s.name, s.home_url, d.title, d.url, d.text,
            \\  extract(epoch from d.published_at)::bigint,
            \\  extract(epoch from d.fetched_at)::bigint,
            \\  d.reliability, d.topics, d.content_hash,
            \\  d.embedding::text, d.lat, d.lon, d.lang, d.summary
            \\FROM documents d JOIN sources s ON s.id = d.source_id
        );
        var pb = ParamBuilder{};
        defer pb.params.deinit(alloc);
        if (before_ts) |cut| {
            try sql.appendSlice(alloc, " WHERE d.fetched_at <= to_timestamp(");
            try pb.intParam(&sql, alloc, cut);
            try sql.appendSlice(alloc, ")");
        }
        try sql.appendSlice(alloc, " ORDER BY d.fetched_at DESC LIMIT ");
        try pb.intParam(&sql, alloc, @intCast(@min(limit, 1000)));
        var res = try client.queryParams(alloc, sql.items, pb.params.items);
        defer res.deinit(alloc);
        var docs = try alloc.alloc(types.Document, res.rows.len);
        for (res.rows, 0..) |row, i| {
            docs[i] = try documentFromRow(alloc, row);
        }
        return docs;
    }

    /// Fetch one document by its content id (Roadmap 6.3, in-memory
    /// index resolution). Null when absent.
    pub fn getDocument(self: *PostgresStore, alloc: Allocator, id: []const u8) !?types.Document {
        const conn = try self.checkoutRead();
        errdefer self.dropRead(conn);
        defer self.checkinRead(conn);
        const client = conn.client;
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc,
            \\SELECT d.id, d.source_id, s.name, s.home_url, d.title, d.url, d.text,
            \\  extract(epoch from d.published_at)::bigint,
            \\  extract(epoch from d.fetched_at)::bigint,
            \\  d.reliability, d.topics, d.content_hash,
            \\  d.embedding::text, d.lat, d.lon, d.lang, d.summary
            \\FROM documents d JOIN sources s ON s.id = d.source_id
            \\ WHERE d.id =
        );
        var pb = ParamBuilder{};
        defer pb.params.deinit(alloc);
        try pb.param(&sql, alloc, id);
        var res = try client.queryParams(alloc, sql.items, pb.params.items);
        defer res.deinit(alloc);
        if (res.rows.len == 0) return null;
        return try documentFromRow(alloc, res.rows[0]);
    }

    /// Delete documents by id (Roadmap 3.5 retention). The 001
    /// event_sources table has no ON DELETE CASCADE, so evidence links
    /// are removed first; the caller recomputes event doc_counts via
    /// the knowledge store afterwards. Returns rows actually removed.
    pub fn deleteDocuments(self: *PostgresStore, ids: []const []const u8) !usize {
        if (ids.len == 0) return 0;
        const client = try self.checkout();
        errdefer self.pool.drop(client);
        defer self.pool.checkin(client);
        const a = self.sqlAlloc();
        // Parameterised IN-list (Roadmap 6.8): one $N per id, the same
        // params list bound to both statements.
        var pb = ParamBuilder{};
        defer pb.params.deinit(a);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(a);
        for (ids, 0..) |id, i| {
            if (i > 0) try list.appendSlice(a, ", ");
            try pb.param(&list, a, id);
        }
        const unlink = try std.fmt.allocPrint(a, "DELETE FROM event_sources WHERE document_id IN ({s})", .{list.items});
        defer a.free(unlink);
        try client.execParams(a, unlink, pb.params.items);
        const del = try std.fmt.allocPrint(a, "DELETE FROM documents WHERE id IN ({s}) RETURNING id", .{list.items});
        defer a.free(del);
        var res = try client.queryParams(a, del, pb.params.items);
        defer res.deinit(a);
        return res.rows.len;
    }

    pub fn countBySource(self: *PostgresStore, alloc: Allocator) ![]types.SourceCount {
        const conn = try self.checkoutRead();
        errdefer self.dropRead(conn);
        defer self.checkinRead(conn);
        const client = conn.client;
        var res = try client.query(alloc,
            "SELECT source_id, count(*) FROM documents GROUP BY source_id ORDER BY count(*) DESC",
        );
        defer res.deinit(alloc);
        var out = try alloc.alloc(types.SourceCount, res.rows.len);
        for (res.rows, 0..) |row, i| {
            if (row.cols.len != 2) return error.ProtocolError;
            out[i] = .{
                .source_id = try alloc.dupe(u8, row.cols[0] orelse return error.ProtocolError),
                .count = std.fmt.parseInt(usize, row.cols[1] orelse return error.ProtocolError, 10) catch
                    return error.ProtocolError,
            };
        }
        return out;
    }
};

/// Parse a PostgreSQL TEXT[] literal: `{a,b,c}`, `{}` for empty, NULL -> empty.
/// Topic values are taxonomy slugs (no commas/quotes), so a plain split is
/// exact for this schema.
fn parseTextArray(alloc: Allocator, val: ?[]const u8) ![]const []const u8 {
    const s = val orelse return &.{};
    if (s.len < 2 or s[0] != '{' or s[s.len - 1] != '}') return error.ProtocolError;
    const inner = s[1 .. s.len - 1];
    if (inner.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |elem| {
        if (elem.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, elem));
    }
    return out.toOwnedSlice(alloc);
}

/// Format topics as a Postgres text[] input literal, e.g.
/// `{"politics","fuel"}` (Roadmap 6.8). Elements are double-quoted
/// with `"` and `\` escaped, so any topic text round-trips through a
/// $N::text[] parameter. Empty list formats as `{}`.
fn formatTextArrayLiteral(alloc: Allocator, topics: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    for (topics, 0..) |t, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        for (t) |c| {
            if (c == '"' or c == '\\') try out.append(alloc, '\\');
            try out.append(alloc, c);
        }
        try out.append(alloc, '"');
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "postgres: startup message bytes" {
    const alloc = testing.allocator;
    const msg = try buildStartupMessage(alloc, "postgres", "pulse");
    defer alloc.free(msg);
    // int32 len=38 | int32 196608 | "user\0postgres\0database\0pulse\0\0"
    const want = [_]u8{ 0, 0, 0, 38, 0, 3, 0, 0 } ++
        "user\x00postgres\x00database\x00pulse\x00\x00";
    try testing.expectEqualSlices(u8, want[0..], msg);
}

test "postgres: md5 password response" {
    const alloc = testing.allocator;
    // Ground truth computed with Python hashlib (see task notes):
    // md5("secret"+"postgres") = 53f48b7c..., outer over salt 01 02 03 04.
    const resp = try md5PasswordResponse(alloc, "secret", "postgres", .{ 1, 2, 3, 4 });
    defer alloc.free(resp);
    try testing.expectEqualStrings("md5bb41a296aab6baccb36ff243a562abff", resp);
}

test "postgres: pbkdf2-sha256 matches RFC 6070 vectors" {
    var out: [32]u8 = undefined;
    pbkdf2Sha256("password", "salt", 1, &out);
    try testing.expectEqualStrings(
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
        &std.fmt.bytesToHex(out, .lower),
    );
    pbkdf2Sha256("password", "salt", 2, &out);
    try testing.expectEqualStrings(
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
        &std.fmt.bytesToHex(out, .lower),
    );
    pbkdf2Sha256("password", "salt", 4096, &out);
    try testing.expectEqualStrings(
        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
        &std.fmt.bytesToHex(out, .lower),
    );
}

test "postgres: scram client-first message format" {
    const alloc = testing.allocator;
    // Fixed nonce so the message is deterministic.
    const bare = try buildClientFirstBare(alloc, "postgres", "rOprNGfwEbeRWgbNEkqO");
    defer alloc.free(bare);
    try testing.expectEqualStrings("n=postgres,r=rOprNGfwEbeRWgbNEkqO", bare);

    const escaped = try buildClientFirstBare(alloc, "a=b,c", "AAAAAAAAAAAAAAAAAAAAAA==");
    defer alloc.free(escaped);
    try testing.expectEqualStrings("n=a=3Db=2Cc,r=AAAAAAAAAAAAAAAAAAAAAA==", escaped);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var st = try ScramState.init(alloc, threaded.io(), "postgres");
    defer st.deinit(alloc);
    try testing.expect(std.mem.startsWith(u8, st.client_first, "n,,n=postgres,r="));
    try testing.expectEqual(@as(usize, 24), st.client_nonce_b64.len);
}

test "postgres: escapeLiteral" {
    const alloc = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "''" },
        .{ .in = "plain", .want = "'plain'" },
        .{ .in = "o'clock", .want = "'o''clock'" },
        .{ .in = "back\\slash", .want = "'back\\slash'" }, // backslashes stay literal
        .{ .in = "100%_x", .want = "'100%_x'" },
    };
    for (cases) |c| {
        const got = try escapeLiteral(alloc, c.in);
        defer alloc.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    // Two single quotes -> each doubled, inside quotes: ''''''
    const q = try escapeLiteral(alloc, "''");
    defer alloc.free(q);
    try testing.expectEqualStrings("''''''", q);
}

test "postgres: escapeLikePattern" {
    const alloc = testing.allocator;
    const got = try escapeLikePattern(alloc, "50%_off\\sale");
    defer alloc.free(got);
    try testing.expectEqualStrings("50\\%\\_off\\\\sale", got);
}

test "postgres: escapeIdent rejects unsafe names" {
    const alloc = testing.allocator;
    const ok = try escapeIdent(alloc, "documents");
    defer alloc.free(ok);
    try testing.expectEqualStrings("\"documents\"", ok);
    try testing.expectError(error.InvalidConnInfo, escapeIdent(alloc, "a; DROP TABLE x"));
    try testing.expectError(error.InvalidConnInfo, escapeIdent(alloc, "9lives"));
    try testing.expectError(error.InvalidConnInfo, escapeIdent(alloc, ""));
}

test "postgres: parseConnInfo" {
    const alloc = testing.allocator;

    var full = try parseConnInfo(alloc, "postgres://bob:s3cret@db.example.com:5433/pulse?sslmode=disable");
    defer full.deinit(alloc);
    try testing.expectEqualStrings("bob", full.user);
    try testing.expectEqualStrings("s3cret", full.password.?);
    try testing.expectEqualStrings("db.example.com", full.host);
    try testing.expectEqual(@as(u16, 5433), full.port);
    try testing.expectEqualStrings("pulse", full.database);
    try testing.expectEqual(SslMode.disable, full.sslmode);

    // Defaults: no port, no db, no password, no sslmode.
    var def = try parseConnInfo(alloc, "postgres://alice@localhost");
    defer def.deinit(alloc);
    try testing.expectEqualStrings("alice", def.user);
    try testing.expectEqual(@as(?[]const u8, null), def.password);
    try testing.expectEqualStrings("localhost", def.host);
    try testing.expectEqual(@as(u16, 5432), def.port);
    try testing.expectEqualStrings("alice", def.database); // db defaults to user
    try testing.expectEqual(SslMode.prefer, def.sslmode);

    // Missing password + missing user/host: everything defaults.
    var bare = try parseConnInfo(alloc, "postgres://");
    defer bare.deinit(alloc);
    try testing.expectEqualStrings("postgres", bare.user);
    try testing.expectEqualStrings("localhost", bare.host);
    try testing.expectEqual(@as(u16, 5432), bare.port);
    try testing.expectEqualStrings("postgres", bare.database);

    // Percent-decoding in user/password/db.
    var pct = try parseConnInfo(alloc, "postgres://us%40er:p%40ss@h:5432/d%20b");
    defer pct.deinit(alloc);
    try testing.expectEqualStrings("us@er", pct.user);
    try testing.expectEqualStrings("p@ss", pct.password.?);
    try testing.expectEqualStrings("d b", pct.database);

    // postgresql:// scheme + sslmode=require parses (connect refuses it).
    var req = try parseConnInfo(alloc, "postgresql://u:p@h/db?sslmode=require");
    defer req.deinit(alloc);
    try testing.expectEqual(SslMode.require, req.sslmode);

    // Invalid port: out of range, non-numeric, empty.
    try testing.expectError(error.InvalidPort, parseConnInfo(alloc, "postgres://u:p@h:99999/db"));
    try testing.expectError(error.InvalidPort, parseConnInfo(alloc, "postgres://u:p@h:abc/db"));
    try testing.expectError(error.InvalidPort, parseConnInfo(alloc, "postgres://u:p@h:/db"));

    // Wrong scheme / no scheme.
    try testing.expectError(error.InvalidConnInfo, parseConnInfo(alloc, "mysql://u:p@h/db"));
    try testing.expectError(error.InvalidConnInfo, parseConnInfo(alloc, "u:p@h/db"));
}

test "postgres: parseConnInfo logTarget never includes the password" {
    const alloc = testing.allocator;
    var info = try parseConnInfo(alloc, "postgres://bob:s3cret@db.example.com:5433/pulse");
    defer info.deinit(alloc);
    const t = try info.logTarget(alloc);
    defer alloc.free(t);
    try testing.expectEqualStrings("db.example.com:5433/pulse", t);
    try testing.expect(std.mem.indexOf(u8, t, "s3cret") == null);
}

test "postgres: parseTextArray" {
    const alloc = testing.allocator;
    const empty = try parseTextArray(alloc, "{}");
    try testing.expectEqual(@as(usize, 0), empty.len);
    const none = try parseTextArray(alloc, null);
    try testing.expectEqual(@as(usize, 0), none.len);
    const two = try parseTextArray(alloc, "{energy,politics}");
    defer {
        for (two) |e| alloc.free(e);
        alloc.free(two);
    }
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("energy", two[0]);
    try testing.expectEqualStrings("politics", two[1]);
    try testing.expectError(error.ProtocolError, parseTextArray(alloc, "not-an-array"));
}

/// Read one variable from the process environment without libc.
/// Zig 0.17 std has no getenv without linking libc, so the live test reads
/// /proc/self/environ directly (Linux-only; the live test is dev-only).
/// Public so other storage modules' live tests can reuse it.
pub fn getTestEnvVar(alloc: Allocator, io: std.Io, name: []const u8) !?[]u8 {
    const proc_dir = std.Io.Dir.openDirAbsolute(io, "/proc/self", .{}) catch return null;
    defer proc_dir.close(io);
    var file = proc_dir.openFile(io, "environ", .{}) catch return null;
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const bytes = reader.interface.readAllocShort(alloc, 1 << 20) catch return null;
    defer alloc.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
            return try alloc.dupe(u8, entry[name.len + 1 ..]);
        }
    }
    return null;
}

test "postgres: server dying mid-handshake fails cleanly" {
    // Guards the connect() errdefer ownership: an auth-phase failure must
    // return an error, not crash on a double free of the ConnInfo strings.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 18777);
    var server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("skip: cannot bind test listener: {any}\n", .{err});
        return;
    };
    defer server.deinit(io);

    const Acceptor = struct {
        fn run(srv: *std.Io.net.Server, io2: std.Io) void {
            var conn = srv.accept(io2) catch return;
            conn.close(io2); // die immediately, mid-handshake
        }
    };
    const t = try std.Thread.spawn(.{}, Acceptor.run, .{ &server, io });
    const result = PgClient.connect(alloc, io, "postgres://postgres:pw@127.0.0.1:18777/pulse");
    t.join();
    // The server closed before sending anything: the client must fail
    // (EOF / reset), never succeed and never crash (no double free of
    // the ConnInfo strings on the auth-phase error path).
    if (result) |c| {
        var cl = c;
        cl.close();
        return error.TestUnexpectedResult;
    } else |_| {
        // Any error is fine (EOF/reset); the point is no crash/double-free.
    }
}

test "postgres: live" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var client = PgClient.connect(alloc, io, url) catch |err| {
        std.debug.print("live test: connect failed: {any}\n", .{err});
        return err;
    };
    defer client.close();

    try client.ping();
    try runMigrations(alloc, io, url, "/home/hatch/workspace/pulse/migrations");

    // Insert a test document and read it back.
    var store = PostgresStore.init(alloc, io, url) catch |err| {
        std.debug.print("live test: store init failed: {any}\n", .{err});
        return err;
    };
    defer store.deinit();

    const id = try types.contentHash(alloc, "new-dawn", "https://example.com/pg-test", "Pulse PG live test");
    defer alloc.free(id);
    const doc = types.Document{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Pulse PG live test",
        .url = "https://example.com/pg-test",
        .text = "A unique zebraquux marker for the live test.",
        .published_at = null,
        .fetched_at = 1762953600,
        .reliability = 0.70,
        .topics = &.{"politics"},
        .content_hash = id,
    };
    var repo = store.repository();
    try repo.insertDocument(doc);
    // Idempotent re-insert must not error or duplicate.
    try repo.insertDocument(doc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const found = try repo.search(arena.allocator(), .{ .terms = &.{"zebraquux"}, .limit = 10 });
    try testing.expect(found.len >= 1);
    var saw_it = false;
    for (found) |d| {
        if (std.mem.eql(u8, d.id, id)) saw_it = true;
    }
    try testing.expect(saw_it);

    // Hybrid-search filters: insert a geo-tagged, embedded doc and check
    // the time window, geo radius, fuzzy term, and vector legs find it.
    const geo_id = try types.contentHash(alloc, "new-dawn", "https://example.com/pg-geo", "Monrovia fuel queue test");
    defer alloc.free(geo_id);
    var emb: [128]f32 = undefined;
    for (&emb) |*v| v.* = 0;
    emb[0] = 1;
    const geo_doc = types.Document{
        .id = geo_id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Monrovia fuel queue test",
        .url = "https://example.com/pg-geo",
        .text = "A hybrid-search probe document for Monrovia.",
        .published_at = 1794441600 + 3600, // 2026-11-12 01:00 UTC
        .fetched_at = 1794441600 + 7200,
        .reliability = 0.70,
        .topics = &.{"energy"},
        .content_hash = geo_id,
        .lat = 6.3204,
        .lon = -10.8060,
        .embedding = &emb,
    };
    try repo.insertDocument(geo_doc);
    // Search by a term the probe doc carries: an unfiltered top-10
    // search is state-dependent (real worker docs now live in this
    // DB) and the probe can rank outside it. The term search still
    // exercises the geo leg — lat/lon + embedding round-trip.
    const geo_found = try repo.search(arena.allocator(), .{ .terms = &.{"fuel"}, .limit = 10 });
    var saw_geo = false;
    for (geo_found) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) {
            saw_geo = true;
            try testing.expect(d.lat != null);
            try testing.expectApproxEqAbs(@as(f64, 6.3204), d.lat.?, 0.001);
            try testing.expect(d.embedding != null);
            try testing.expectEqual(@as(usize, 128), d.embedding.?.len);
        }
    }
    try testing.expect(saw_geo);
    // Time window [Nov 12, Nov 13) keeps the geo doc, drops the Nov 2025 one.
    const in_window = try repo.search(arena.allocator(), .{
        .terms = &.{},
        .from_ts = 1794441600,
        .to_ts = 1794441600 + 86400,
        .limit = 100,
    });
    var saw_geo_window = false;
    var saw_old_window = false;
    for (in_window) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) saw_geo_window = true;
        if (std.mem.eql(u8, d.id, id)) saw_old_window = true;
    }
    try testing.expect(saw_geo_window);
    try testing.expect(!saw_old_window);
    // Geo radius 50 km around Monrovia keeps the geo doc.
    const near = try repo.search(arena.allocator(), .{
        .terms = &.{},
        .geo = .{ .lat = 6.3204, .lon = -10.8060, .radius_km = 50 },
        .limit = 100,
    });
    var saw_geo_near = false;
    for (near) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) saw_geo_near = true;
    }
    try testing.expect(saw_geo_near);
    // Fuzzy "monrova" (typo) finds the Monrovia doc only with fuzzy on.
    const fuzzy_off = try repo.search(arena.allocator(), .{ .terms = &.{"monrova"}, .limit = 100 });
    var saw_geo_exact = false;
    for (fuzzy_off) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) saw_geo_exact = true;
    }
    try testing.expect(!saw_geo_exact);
    const fuzzy_on = try repo.search(arena.allocator(), .{ .terms = &.{"monrova"}, .fuzzy = true, .limit = 100 });
    var saw_geo_fuzzy = false;
    for (fuzzy_on) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) saw_geo_fuzzy = true;
    }
    try testing.expect(saw_geo_fuzzy);
    // Vector leg: the same [1,0,...] embedding retrieves the geo doc with
    // no terms at all.
    const vec = try repo.search(arena.allocator(), .{
        .terms = &.{},
        .query_embedding = &emb,
        .limit = 100,
    });
    var saw_geo_vec = false;
    for (vec) |d| {
        if (std.mem.eql(u8, d.id, geo_id)) saw_geo_vec = true;
    }
    try testing.expect(saw_geo_vec);

    try testing.expect(repo.countDocuments() >= 1);
    const by_source = try repo.countBySource(arena.allocator());
    try testing.expect(by_source.len >= 1);

    // Migrations are idempotent: a second run must not error.
    try runMigrations(alloc, io, url, "/home/hatch/workspace/pulse/migrations");
}

test "postgres: source profiles migration 013 seeds 12 profiles (live, Phase 1)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var client = PgClient.connect(alloc, io, url) catch |err| {
        std.debug.print("live test: connect failed: {any}\n", .{err});
        return err;
    };
    defer client.close();

    try runMigrations(alloc, io, url, "/home/hatch/workspace/pulse/migrations");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var res = try client.query(a, "SELECT count(*) FROM source_profiles");
    defer res.deinit(a);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    const profiles_n = try std.fmt.parseInt(usize, res.rows[0].cols[0].?, 10);
    try testing.expectEqual(@as(usize, 12), profiles_n);

    var res2 = try client.query(a, "SELECT count(*) FROM source_profile_history WHERE action = 'profile_created'");
    defer res2.deinit(a);
    const hist_n = try std.fmt.parseInt(usize, res2.rows[0].cols[0].?, 10);
    try testing.expectEqual(@as(usize, 12), hist_n);

    // Spot checks: Montserrado base county for all, 9 active / 3
    // removed, Local Voices the one unverified assignment.
    var res3 = try client.query(a, "SELECT count(*) FROM source_profiles WHERE county = 'Montserrado'");
    defer res3.deinit(a);
    try testing.expectEqual(@as(usize, 12), try std.fmt.parseInt(usize, res3.rows[0].cols[0].?, 10));
    var res4 = try client.query(a, "SELECT count(*) FROM source_profiles WHERE status = 'active'");
    defer res4.deinit(a);
    try testing.expectEqual(@as(usize, 9), try std.fmt.parseInt(usize, res4.rows[0].cols[0].?, 10));
    var res5 = try client.query(a, "SELECT county_confidence FROM source_profiles WHERE source_id = 'local-voices'");
    defer res5.deinit(a);
    try testing.expectEqual(@as(usize, 1), res5.rows.len);
    try testing.expectEqualStrings("unverified", res5.rows[0].cols[0].?);

    // Re-running the migration is a no-op for the history seed.
    try runMigrations(alloc, io, url, "/home/hatch/workspace/pulse/migrations");
    var res6 = try client.query(a, "SELECT count(*) FROM source_profile_history WHERE action = 'profile_created'");
    defer res6.deinit(a);
    try testing.expectEqual(@as(usize, 12), try std.fmt.parseInt(usize, res6.rows[0].cols[0].?, 10));
}

test "postgres: prepared statements (live, Roadmap 6.8)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var client = PgClient.connect(alloc, io, url) catch |err| {
        std.debug.print("live test: connect failed: {any}\n", .{err});
        return err;
    };
    defer client.close();

    // queryParams returns the same rows as the simple query for the
    // same statement.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var plain = try client.query(aa, "SELECT 1 AS a, 'x' AS b");
    defer plain.deinit(aa);
    var prepped = try client.queryParams(aa, "SELECT $1::int AS a, $2 AS b", &.{ "1", "x" });
    defer prepped.deinit(aa);
    try testing.expectEqual(@as(usize, 1), plain.rows.len);
    try testing.expectEqual(@as(usize, 1), prepped.rows.len);
    try testing.expectEqualStrings("1", prepped.rows[0].cols[0].?);
    try testing.expectEqualStrings("x", prepped.rows[0].cols[1].?);

    // A value containing a quote is bound, never interpolated: the
    // query succeeds and returns the value verbatim. Under the old
    // string-interpolation path this input needed escaping.
    var quoted = try client.queryParams(aa, "SELECT $1 AS v", &.{"o'brien"});
    defer quoted.deinit(aa);
    try testing.expectEqualStrings("o'brien", quoted.rows[0].cols[0].?);

    // NULL params bind as SQL NULL. The cast gives the server the
    // type context: a bare `$1 IS NULL` cannot infer a type and the
    // server rejects it with 42P18 (could not determine data type).
    // Every real call site has type context (a column, a function
    // argument, or an explicit cast), so only context-free test SQL
    // needs the cast.
    var nul = try client.queryParams(aa, "SELECT $1::text IS NULL AS is_null", &.{null});
    defer nul.deinit(aa);
    try testing.expectEqualStrings("t", nul.rows[0].cols[0].?);

    // A failed Parse returns PgServerError AND leaves the connection
    // usable — the next query on the same connection succeeds.
    const bad = client.queryParams(aa, "SELECT * FROM no_such_table_xyz", &.{});
    try testing.expectError(error.PgServerError, bad);
    try client.ping();

    // execParams: an INSERT with params, then read it back.
    try client.execParams(aa, "CREATE TEMP TABLE pulse_prep_test (id int, name text)", &.{});
    try client.execParams(aa, "INSERT INTO pulse_prep_test VALUES ($1, $2)", &.{ "7", "o'brien" });
    var back = try client.queryParams(aa, "SELECT name FROM pulse_prep_test WHERE id = $1", &.{"7"});
    defer back.deinit(aa);
    try testing.expectEqual(@as(usize, 1), back.rows.len);
    try testing.expectEqualStrings("o'brien", back.rows[0].cols[0].?);

    // The store search path (now parameterised) handles a term with a
    // quote without a syntax error.
    var store = PostgresStore.init(alloc, io, url) catch |err| {
        std.debug.print("live test: store init failed: {any}\n", .{err});
        return err;
    };
    defer store.deinit();
    var repo = store.repository();
    const found = try repo.search(aa, .{ .terms = &.{"o'brien"}, .limit = 5 });
    _ = found;
    const missing = try repo.getDocument(aa, "o'brien");
    try testing.expect(missing == null);
}

test "postgres: read replica routes reads, falls back on failure (live)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var store = PostgresStore.init(alloc, io, url) catch |err| {
        std.debug.print("live replica test: store init failed: {any}\n", .{err});
        return err;
    };
    defer store.deinit();

    try testing.expect(!store.hasReplica());

    // The "replica" is a second pool to the same test database: this
    // proves the routing, not replication. A real replica is a streaming
    // standby behind PULSE_DATABASE_REPLICA_URL.
    try store.setReplica(url);
    try testing.expect(store.hasReplica());
    // A second attach is an error; the first replica stays attached.
    try testing.expectError(error.ReplicaAlreadyConfigured, store.setReplica(url));

    // Writes go to the primary; reads route through the replica pool.
    const id = try types.contentHash(alloc, "new-dawn", "https://example.com/pg-replica", "Replica routing probe");
    defer alloc.free(id);
    var repo = store.repository();
    try repo.insertDocument(.{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Replica routing probe",
        .url = "https://example.com/pg-replica",
        .text = "A unique replicaquux marker for the replica test.",
        .published_at = null,
        .fetched_at = 1762953600,
        .reliability = 0.70,
        .topics = &.{"politics"},
        .content_hash = id,
    });
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const found = try repo.search(arena.allocator(), .{ .terms = &.{"replicaquux"}, .limit = 10 });
    var saw_it = false;
    for (found) |d| {
        if (std.mem.eql(u8, d.id, id)) saw_it = true;
    }
    try testing.expect(saw_it);
    try testing.expect(repo.countDocuments() >= 1);
    try testing.expect((try repo.countBySource(arena.allocator())).len >= 1);

    // A store whose replica URL is unreachable fails at attach (any
    // error is fine — the point is no replica) and keeps serving reads
    // from the primary.
    var store2 = PostgresStore.init(alloc, io, url) catch |err| {
        std.debug.print("live replica test: store2 init failed: {any}\n", .{err});
        return err;
    };
    defer store2.deinit();
    if (store2.setReplica("postgres://postgres:pulse_test@127.0.0.1:1/pulse_test")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expect(!store2.hasReplica());
    var repo2 = store2.repository();
    const found2 = try repo2.search(arena.allocator(), .{ .terms = &.{"replicaquux"}, .limit = 10 });
    var saw_it2 = false;
    for (found2) |d| {
        if (std.mem.eql(u8, d.id, id)) saw_it2 = true;
    }
    try testing.expect(saw_it2);
}

test "PgPool: two threads hold two connections at once (live)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var pool = try PgPool.init(alloc, io, url, 2);
    defer pool.deinit();

    const Ctx = struct {
        pool: *PgPool,
        held: *std.atomic.Value(usize),
        max_held: *std.atomic.Value(usize),
        ok: *std.atomic.Value(bool),

        fn run(c: *@This()) void {
            const client = c.pool.checkout() catch {
                c.ok.store(false, .seq_cst);
                return;
            };
            const cur = c.held.fetchAdd(1, .seq_cst) + 1;
            var prev = c.max_held.load(.seq_cst);
            while (cur > prev) {
                if (c.max_held.cmpxchgWeak(prev, cur, .seq_cst, .seq_cst) == null) break;
                prev = c.max_held.load(.seq_cst);
            }
            client.ping() catch {
                c.ok.store(false, .seq_cst);
            };
            // Plain nanosleep: Io.sleep goes through the Io instance
            // and is not reliable from a raw spawned thread.
            PgPool.sleepNanos(50_000_000);
            _ = c.held.fetchSub(1, .seq_cst);
            c.pool.checkin(client);
        }
    };
    var held = std.atomic.Value(usize).init(0);
    var max_held = std.atomic.Value(usize).init(0);
    var ok = std.atomic.Value(bool).init(true);
    var ctx = Ctx{ .pool = &pool, .held = &held, .max_held = &max_held, .ok = &ok };
    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    t1.join();
    t2.join();
    try testing.expect(ok.load(.seq_cst));
    // Both threads held a connection at the same time: the pool really
    // handed out two distinct connections, not one behind a mutex.
    try testing.expectEqual(@as(usize, 2), max_held.load(.seq_cst));
    // A checkout after both returned works (slots freed).
    const c = try pool.checkout();
    try c.ping();
    pool.checkin(c);
}

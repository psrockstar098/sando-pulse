//! Production self-audit (Roadmap 5.1): `pulse audit`.
//!
//! A pre-flight checklist for operators. Every check is one line:
//! `[PASS|WARN|FAIL|SKIP] <id>: <detail>`. Any FAIL makes the command
//! exit 1; WARNs are operator judgement calls, not blockers.
//!
//! Checks that need no connections run from the config alone (and are
//! unit-tested here). The Postgres and Redis checks connect live when
//! DATABASE_URL / REDIS_URL are set and SKIP otherwise. No secret is
//! ever printed: keys and passwords appear only as "set"/"unset".

const std = @import("std");
const config = @import("../config/config.zig");
const compression = @import("../storage/compression.zig");
const postgres = @import("../storage/postgres.zig");
const redis = @import("../storage/redis.zig");

pub const Status = enum { pass, warn, fail, skip };

pub const Check = struct {
    id: []const u8,
    status: Status,
    detail: []const u8,
};

fn check(id: []const u8, status: Status, detail: []const u8) Check {
    return .{ .id = id, .status = status, .detail = detail };
}

/// API key configured? Open dev mode in production is a FAIL.
pub fn checkApiKey(cfg: config.Config) Check {
    if (cfg.api_key != null) return check("api_key", .pass, "PULSE_API_KEY is set");
    if (cfg.api_key_previous != null) return check("api_key", .warn, "only PULSE_API_KEY_PREVIOUS is set — finish the rotation (set PULSE_API_KEY)");
    return check("api_key", .fail, "no API key configured — /v1/query and /v1/ingest are open");
}

/// Rotation state sane? Same value in both slots means the rotation
/// never happened (or a copy-paste error).
pub fn checkRotation(cfg: config.Config) Check {
    if (cfg.api_key_previous == null) return check("key_rotation", .pass, "no rotation in progress");
    if (cfg.api_key == null) return check("key_rotation", .warn, "previous key set but no current key — see api_key");
    if (std.mem.eql(u8, cfg.api_key.?, cfg.api_key_previous.?)) {
        return check("key_rotation", .fail, "PULSE_API_KEY and PULSE_API_KEY_PREVIOUS are identical — rotate to a fresh key");
    }
    return check("key_rotation", .pass, "rotation in progress: current + previous keys differ");
}

/// Rate limits sane? 0 blocks everything; absurdly high limits are
/// barely limits at all.
pub fn checkRateLimits(cfg: config.Config) Check {
    if (cfg.rate_limit_per_minute == 0 or cfg.rate_limit_per_day == 0) {
        return check("rate_limits", .fail, "a zero rate limit blocks all authenticated requests");
    }
    if (cfg.rate_limit_per_minute > 1000 or cfg.rate_limit_per_day > 100000) {
        return check("rate_limits", .warn, "limits are very high for a public API — consider tightening PULSE_RATE_LIMIT_*");
    }
    return check("rate_limits", .pass, "per-minute and per-day limits within the sane range");
}

/// Retention enabled? 0 disables archival/deletion entirely.
pub fn checkRetention(cfg: config.Config) Check {
    if (cfg.retention_days == 0) return check("retention", .warn, "retention disabled (PULSE_RETENTION_DAYS=0) — documents accumulate forever");
    return check("retention", .pass, "retention enforced");
}

/// TLS termination in place? Pulse itself serves plain HTTP (the Zig
/// 0.17.1 stdlib has no TLS server); production must sit behind a
/// TLS-terminating reverse proxy and say so with PULSE_BEHIND_TLS_PROXY=1.
pub fn checkTls(cfg: config.Config) Check {
    if (cfg.behind_tls_proxy) return check("tls", .pass, "TLS termination configured (PULSE_BEHIND_TLS_PROXY=1)");
    return check("tls", .warn, "no TLS termination configured — serve behind a TLS proxy in production (PULSE_BEHIND_TLS_PROXY=1)");
}

/// Database password is not the documented example ("pulse")?
pub fn checkDbPassword(alloc: std.mem.Allocator, cfg: config.Config) Check {
    const url = cfg.database_url orelse return check("db_password", .skip, "no DATABASE_URL configured");
    var info = postgres.parseConnInfo(alloc, url) catch return check("db_password", .skip, "DATABASE_URL unparsable — cannot check the password");
    defer info.deinit(alloc);
    if (info.password) |pw| {
        if (std.mem.eql(u8, pw, "pulse")) {
            return check("db_password", .fail, "database password is the documented example 'pulse' — change it");
        }
    }
    return check("db_password", .pass, "database password is not the example value");
}

/// Linked dependencies: Zig version + libzstd version. Pulse has no
/// external packages (std only); the system libraries are libc + zstd.
pub fn checkDependencies() Check {
    const zv = compression.version();
    if (zv.len == 0) return check("dependencies", .fail, "libzstd version unreadable");
    // "1.5.5" — major.minor must parse and be >= 1.5.0.
    var it = std.mem.splitScalar(u8, zv, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    if (major < 1 or (major == 1 and minor < 5)) {
        return check("dependencies", .fail, "libzstd is too old for Pulse — need >= 1.5.0");
    }
    return check("dependencies", .pass, "std-only build; libzstd linked");
}

fn parsePgMajor(version_s: []const u8) ?u32 {
    // "PostgreSQL 16.15 on x86_64-pc-linux-gnu, ..."
    const prefix = "PostgreSQL ";
    const at = std.mem.indexOf(u8, version_s, prefix) orelse return null;
    const rest = version_s[at + prefix.len ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    return std.fmt.parseInt(u32, rest[0..dot], 10) catch null;
}

/// Live Postgres check: connect, report the server version, list the
/// extensions Pulse needs (vector, postgis, pg_trgm).
pub fn checkPostgres(alloc: std.mem.Allocator, io: std.Io, url: []const u8) Check {
    var client = postgres.PgClient.connect(alloc, io, url) catch {
        return check("postgres", .fail, "cannot connect to DATABASE_URL");
    };
    defer client.close();
    const vres = client.query(alloc, "SELECT version()") catch {
        return check("postgres", .fail, "connected but SELECT version() failed");
    };
    if (vres.rows.len == 0 or vres.rows[0].cols.len == 0 or vres.rows[0].cols[0] == null) {
        return check("postgres", .fail, "SELECT version() returned no row");
    }
    const version_s = vres.rows[0].cols[0].?;
    const major = parsePgMajor(version_s) orelse {
        return check("postgres", .warn, "unparsable server version string");
    };
    if (major < 14) {
        return check("postgres", .fail, "PostgreSQL is too old — need >= 14");
    }
    const eres = client.query(alloc, "SELECT extname FROM pg_extension WHERE extname IN ('vector','postgis','pg_trgm')") catch {
        return check("postgres", .warn, "connected, but the extension query failed");
    };
    var have_vector = false;
    var have_postgis = false;
    var have_trgm = false;
    for (eres.rows) |row| {
        if (row.cols.len == 0 or row.cols[0] == null) continue;
        const name = row.cols[0].?;
        if (std.mem.eql(u8, name, "vector")) have_vector = true;
        if (std.mem.eql(u8, name, "postgis")) have_postgis = true;
        if (std.mem.eql(u8, name, "pg_trgm")) have_trgm = true;
    }
    if (!have_vector or !have_postgis or !have_trgm) {
        return check("postgres", .fail, "missing required extension(s) — need vector, postgis, pg_trgm");
    }
    return check("postgres", .pass, "server version ok, required extensions present");
}

/// Live index-health check (Roadmap 6.11): counts the indexes on the
/// public schema, names the ones never scanned, and reports when the
/// documents table was last ANALYZEd. WARN when there are no indexes
/// at all (search would scan) or when documents has never been
/// ANALYZEd (run `pulse maintenance`). Never-scanned indexes on a
/// fresh install are reported, not warned — a new table has no scans
/// yet, and dropping an index is an operator decision.
pub fn checkIndexes(alloc: std.mem.Allocator, io: std.Io, url: []const u8) Check {
    var client = postgres.PgClient.connect(alloc, io, url) catch {
        return check("indexes", .fail, "cannot connect to DATABASE_URL");
    };
    defer client.close();
    const ires = client.query(alloc, "SELECT indexrelname, idx_scan FROM pg_stat_user_indexes WHERE schemaname = 'public' ORDER BY indexrelname") catch {
        return check("indexes", .fail, "index query failed");
    };
    var total: usize = 0;
    var never_scanned: usize = 0;
    var never_names: std.ArrayList(u8) = .empty;
    defer never_names.deinit(alloc);
    for (ires.rows) |row| {
        if (row.cols.len < 2 or row.cols[0] == null) continue;
        total += 1;
        const scans = if (row.cols[1]) |s| std.fmt.parseInt(i64, s, 10) catch -1 else -1;
        if (scans == 0) {
            never_scanned += 1;
            if (never_names.items.len > 0) never_names.appendSlice(alloc, ", ") catch {};
            never_names.appendSlice(alloc, row.cols[0].?) catch {};
        }
    }
    const ares = client.query(alloc, "SELECT last_analyze FROM pg_stat_user_tables WHERE schemaname = 'public' AND relname = 'documents'") catch {
        return check("indexes", .fail, "last_analyze query failed");
    };
    const last_analyze: ?[]const u8 = if (ares.rows.len > 0 and ares.rows[0].cols.len > 0) ares.rows[0].cols[0] else null;
    if (total == 0) {
        return check("indexes", .warn, "no indexes on the public schema — search scans");
    }
    const detail = if (never_scanned > 0)
        std.fmt.allocPrint(alloc, "{d} indexes, {d} never scanned ({s}); documents last ANALYZE: {s}", .{ total, never_scanned, never_names.items, last_analyze orelse "never" }) catch "index summary unavailable"
    else
        std.fmt.allocPrint(alloc, "{d} indexes, none never scanned; documents last ANALYZE: {s}", .{ total, last_analyze orelse "never" }) catch "index summary unavailable";
    if (last_analyze == null) {
        return check("indexes", .warn, detail);
    }
    return check("indexes", .pass, detail);
}

fn redisConfigGet(alloc: std.mem.Allocator, client: *redis.RedisClient, param: []const u8) ?[]const u8 {
    const res = client.command(alloc, &.{ "CONFIG", "GET", param }) catch return null;
    if (res != .array) return null;
    const items = res.array orelse return null;
    if (items.len < 2) return null;
    if (items[1] != .bulk) return null;
    return items[1].bulk orelse return null;
}

/// Live Redis check: the query cache (Roadmap 4.5) has no count bound,
/// so the deployment MUST bound it with a Redis maxmemory policy.
/// PASS only when maxmemory > 0 AND the eviction policy is not noeviction.
pub fn checkRedis(alloc: std.mem.Allocator, io: std.Io, url: []const u8) Check {
    var client = redis.RedisClient.connect(alloc, io, url) catch {
        return check("redis", .fail, "cannot connect to REDIS_URL");
    };
    defer client.close();
    const maxmem_s = redisConfigGet(alloc, &client, "maxmemory") orelse {
        return check("redis", .warn, "connected, but CONFIG GET maxmemory failed");
    };
    const maxmem = std.fmt.parseInt(i64, maxmem_s, 10) catch -1;
    if (maxmem <= 0) {
        return check("redis", .warn, "maxmemory is 0 (unbounded) — the query cache can grow until the host runs out of memory; set maxmemory + maxmemory-policy");
    }
    const policy = redisConfigGet(alloc, &client, "maxmemory-policy") orelse "unknown";
    if (std.mem.eql(u8, policy, "noeviction")) {
        return check("redis", .warn, "maxmemory is set but policy is noeviction — cache writes fail when full instead of evicting; use allkeys-lru");
    }
    return check("redis", .pass, "maxmemory bounded with an evicting policy");
}

/// Run every check and print the report. Returns the process exit code:
/// 0 when nothing FAILED, 1 otherwise.
pub fn run(alloc: std.mem.Allocator, io: std.Io, cfg: config.Config) u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var fails: usize = 0;
    var warns: usize = 0;
    var passes: usize = 0;
    var skips: usize = 0;

    const checks = [_]Check{
        checkApiKey(cfg),
        checkRotation(cfg),
        checkRateLimits(cfg),
        checkRetention(cfg),
        checkTls(cfg),
        checkDbPassword(a, cfg),
        checkDependencies(),
    };
    for (checks) |c| {
        printCheck(c);
        switch (c.status) {
            .pass => passes += 1,
            .warn => warns += 1,
            .fail => fails += 1,
            .skip => skips += 1,
        }
    }
    if (cfg.database_url) |url| {
        const c = checkPostgres(a, io, url);
        printCheck(c);
        switch (c.status) {
            .pass => passes += 1,
            .warn => warns += 1,
            .fail => fails += 1,
            .skip => skips += 1,
        }
        // Index health (Roadmap 6.11): same connection target as the
        // Postgres check above; a second connect is cheap and keeps
        // each check independent.
        const ic = checkIndexes(a, io, url);
        printCheck(ic);
        switch (ic.status) {
            .pass => passes += 1,
            .warn => warns += 1,
            .fail => fails += 1,
            .skip => skips += 1,
        }
    } else {
        printCheck(check("postgres", .skip, "no DATABASE_URL configured"));
        skips += 1;
        printCheck(check("indexes", .skip, "no DATABASE_URL configured"));
        skips += 1;
    }
    if (cfg.redis_url) |url| {
        const c = checkRedis(a, io, url);
        printCheck(c);
        switch (c.status) {
            .pass => passes += 1,
            .warn => warns += 1,
            .fail => fails += 1,
            .skip => skips += 1,
        }
    } else {
        printCheck(check("redis", .skip, "no REDIS_URL configured"));
        skips += 1;
    }
    std.debug.print("audit: {d} pass, {d} warn, {d} fail, {d} skip\n", .{ passes, warns, fails, skips });
    return if (fails > 0) 1 else 0;
}

fn printCheck(c: Check) void {
    const label: []const u8 = switch (c.status) {
        .pass => "PASS",
        .warn => "WARN",
        .fail => "FAIL",
        .skip => "SKIP",
    };
    std.debug.print("[{s}] {s}: {s}\n", .{ label, c.id, c.detail });
}

test "audit: api key check" {
    var cfg = config.Config{};
    try std.testing.expectEqual(Status.fail, checkApiKey(cfg).status);
    cfg.api_key = "k";
    try std.testing.expectEqual(Status.pass, checkApiKey(cfg).status);
    cfg.api_key = null;
    cfg.api_key_previous = "old";
    try std.testing.expectEqual(Status.warn, checkApiKey(cfg).status);
}

test "audit: rotation check" {
    var cfg = config.Config{};
    try std.testing.expectEqual(Status.pass, checkRotation(cfg).status);
    cfg.api_key = "new";
    cfg.api_key_previous = "old";
    try std.testing.expectEqual(Status.pass, checkRotation(cfg).status);
    cfg.api_key_previous = "new";
    try std.testing.expectEqual(Status.fail, checkRotation(cfg).status);
    cfg.api_key = null;
    try std.testing.expectEqual(Status.warn, checkRotation(cfg).status);
}

test "audit: rate limits check" {
    var cfg = config.Config{};
    try std.testing.expectEqual(Status.pass, checkRateLimits(cfg).status);
    cfg.rate_limit_per_minute = 0;
    try std.testing.expectEqual(Status.fail, checkRateLimits(cfg).status);
    cfg.rate_limit_per_minute = 100;
    cfg.rate_limit_per_day = 200000;
    try std.testing.expectEqual(Status.warn, checkRateLimits(cfg).status);
}

test "audit: retention and tls checks" {
    var cfg = config.Config{};
    try std.testing.expectEqual(Status.pass, checkRetention(cfg).status);
    cfg.retention_days = 0;
    try std.testing.expectEqual(Status.warn, checkRetention(cfg).status);
    try std.testing.expectEqual(Status.warn, checkTls(cfg).status);
    cfg.behind_tls_proxy = true;
    try std.testing.expectEqual(Status.pass, checkTls(cfg).status);
}

test "audit: db password check" {
    const alloc = std.testing.allocator;
    var cfg = config.Config{};
    try std.testing.expectEqual(Status.skip, checkDbPassword(alloc, cfg).status);
    cfg.database_url = "postgres://pulse:pulse@localhost:5432/pulse";
    try std.testing.expectEqual(Status.fail, checkDbPassword(alloc, cfg).status);
    cfg.database_url = "postgres://pulse:something-else@localhost:5432/pulse";
    try std.testing.expectEqual(Status.pass, checkDbPassword(alloc, cfg).status);
    cfg.database_url = "not-a-url";
    try std.testing.expectEqual(Status.skip, checkDbPassword(alloc, cfg).status);
}

test "audit: dependencies check reports the linked zstd" {
    const c = checkDependencies();
    try std.testing.expectEqual(Status.pass, c.status);
    try std.testing.expect(std.mem.indexOf(u8, c.detail, "libzstd") != null);
}

test "audit: parsePgMajor" {
    try std.testing.expectEqual(@as(?u32, 16), parsePgMajor("PostgreSQL 16.15 on x86_64-pc-linux-gnu, compiled by gcc"));
    try std.testing.expectEqual(@as(?u32, 14), parsePgMajor("PostgreSQL 14.9"));
    try std.testing.expectEqual(@as(?u32, null), parsePgMajor("garbage"));
}

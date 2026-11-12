//! Runtime configuration, read from environment variables ONLY.
//! Secrets are never written to any file: an API key or password lives in
//! the process environment (or a gitignored .env loaded by the operator's
//! shell/compose), never in the repo.

const std = @import("std");
const logging = @import("../common/logging.zig");

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    /// If null, the API runs in open dev mode and logs a warning on boot.
    /// Set PULSE_API_KEY to require Bearer auth on /v1/query and /v1/ingest.
    api_key: ?[]const u8 = null,
    database_url: ?[]const u8 = null,
    redis_url: ?[]const u8 = null,
    minio_endpoint: ?[]const u8 = null,
    minio_access_key: ?[]const u8 = null,
    minio_secret_key: ?[]const u8 = null,
    minio_bucket: []const u8 = "pulse-raw",
    ingest_interval_s: u64 = 300,
    rate_limit_per_minute: u32 = 100,
    rate_limit_per_day: u32 = 10000,
    log_level: []const u8 = "info",
};

fn envOwned(alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, name: []const u8) ?[]u8 {
    const v = env_map.get(name) orelse return null;
    return alloc.dupe(u8, v) catch null;
}

pub fn parsePort(s: []const u8) ?u16 {
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    if (n > 65535) return null;
    return @intCast(n);
}

pub fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

pub fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Load config from the process environment map (Zig 0.17.1: the runtime
/// hands the map to main via std.process.Init). The allocator owns the
/// returned strings; the caller keeps `alloc` alive for the process lifetime.
pub fn load(alloc: std.mem.Allocator, env_map: *std.process.Environ.Map) !Config {
    var cfg = Config{};
    if (envOwned(alloc, env_map, "PULSE_HOST")) |v| cfg.host = v;
    if (envOwned(alloc, env_map, "PULSE_PORT")) |v| {
        if (parsePort(v)) |p| {
            cfg.port = p;
        } else {
            logging.warn("invalid PULSE_PORT, using default 9000", &.{.{ .key = "value", .value = v }});
        }
    }
    if (envOwned(alloc, env_map, "PULSE_API_KEY")) |v| {
        if (v.len > 0) cfg.api_key = v;
    }
    if (envOwned(alloc, env_map, "DATABASE_URL")) |v| {
        if (v.len > 0) cfg.database_url = v;
    }
    if (envOwned(alloc, env_map, "REDIS_URL")) |v| {
        if (v.len > 0) cfg.redis_url = v;
    }
    if (envOwned(alloc, env_map, "MINIO_ENDPOINT")) |v| {
        if (v.len > 0) cfg.minio_endpoint = v;
    }
    if (envOwned(alloc, env_map, "MINIO_ACCESS_KEY")) |v| {
        if (v.len > 0) cfg.minio_access_key = v;
    }
    if (envOwned(alloc, env_map, "MINIO_SECRET_KEY")) |v| {
        if (v.len > 0) cfg.minio_secret_key = v;
    }
    if (envOwned(alloc, env_map, "MINIO_BUCKET")) |v| {
        if (v.len > 0) cfg.minio_bucket = v;
    }
    if (envOwned(alloc, env_map, "PULSE_INGEST_INTERVAL_S")) |v| {
        cfg.ingest_interval_s = parseU64(v) orelse 300;
    }
    if (envOwned(alloc, env_map, "PULSE_RATE_LIMIT_PER_MINUTE")) |v| {
        cfg.rate_limit_per_minute = parseU32(v) orelse 100;
    }
    if (envOwned(alloc, env_map, "PULSE_RATE_LIMIT_PER_DAY")) |v| {
        cfg.rate_limit_per_day = parseU32(v) orelse 10000;
    }
    if (envOwned(alloc, env_map, "PULSE_LOG_LEVEL")) |v| cfg.log_level = v;
    return cfg;
}

test "parsePort accepts valid ports and rejects bad input" {
    try std.testing.expectEqual(@as(?u16, 9000), parsePort("9000"));
    try std.testing.expectEqual(@as(?u16, 80), parsePort("80"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("70000"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("abc"));
    try std.testing.expectEqual(@as(?u16, null), parsePort(""));
}

test "parseU64 and parseU32" {
    try std.testing.expectEqual(@as(?u64, 300), parseU64("300"));
    try std.testing.expectEqual(@as(?u64, null), parseU64("-1"));
    try std.testing.expectEqual(@as(?u32, 100), parseU32("100"));
    try std.testing.expectEqual(@as(?u32, null), parseU32("4294967296"));
}

test "load returns defaults without env vars" {
    // Defaults must hold; env-dependent values are only asserted as sane.
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const cfg = try load(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
    try std.testing.expectEqual(@as(u64, 300), cfg.ingest_interval_s);
    try std.testing.expectEqual(@as(u32, 100), cfg.rate_limit_per_minute);
    try std.testing.expectEqual(@as(u32, 10000), cfg.rate_limit_per_day);
    try std.testing.expectEqualStrings("pulse-raw", cfg.minio_bucket);
}

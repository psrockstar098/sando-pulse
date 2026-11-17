//! Runtime configuration, read from environment variables ONLY.
//! Secrets are never written to any file: an API key or password lives in
//! the process environment (or a gitignored .env loaded by the operator's
//! shell/compose), never in the repo.

const std = @import("std");
const logging = @import("../common/logging.zig");
const usage = @import("../api/usage.zig");

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    /// If null, the API runs in open dev mode and logs a warning on boot.
    /// Set PULSE_API_KEY to require Bearer auth on /v1/query and /v1/ingest.
    api_key: ?[]const u8 = null,
    /// Previous key, accepted alongside api_key during rotation
    /// (Roadmap 5.1). Remove it once clients have migrated.
    api_key_previous: ?[]const u8 = null,
    /// Base URL of this Pulse instance, used by the mock-sando client
    /// (Roadmap 5.2). Defaults to the local server.
    pulse_url: []const u8 = "http://127.0.0.1:9000",
    /// SearXNG base URL for real web search: the unified /v1/query
    /// fans out to it, and `pulse websearch` calls it directly. Null
    /// = web search unavailable: the query answers with web status
    /// "unavailable" and the CLI refuses to run. In the all-in-one
    /// image the entrypoint sets this to http://127.0.0.1:8080;
    /// on the compose network it is "http://searxng:8080".
    searxng_url: ?[]const u8 = null,
    /// Unified-query web deadline in milliseconds: how long /v1/query
    /// waits for the SearXNG leg before answering with web status
    /// "timeout" (the leg keeps running and is joined after the
    /// response). Local results never wait on the web.
    web_timeout_ms: u64 = 1500,
    /// Registered API consumers (Roadmap 5.3). Empty = a single implicit
    /// "default" consumer with all scopes and the global daily limit.
    consumers: []const usage.Consumer = &.{},
    /// JSONL audit-log file path (Roadmap 5.3). Null = Postgres + structured
    /// log only.
    audit_log_path: ?[]const u8 = null,
    database_url: ?[]const u8 = null,
    /// Read-replica URL (Roadmap 5.5). When set, search reads route to
    /// a second pool on this URL; writes stay on the primary. Null =
    /// reads use the primary. A replica that fails to connect is logged
    /// and ignored — never a boot failure.
    database_replica_url: ?[]const u8 = null,
    /// Deployment country, ISO 3166-1 alpha-2 (Roadmap 5.5). Default
    /// "lr" (Liberia). Reported in /v1/health and `pulse status`;
    /// the multi-country extension point (see docs/SCALABILITY.md).
    country: []const u8 = "lr",
    redis_url: ?[]const u8 = null,
    minio_endpoint: ?[]const u8 = null,
    minio_access_key: ?[]const u8 = null,
    minio_secret_key: ?[]const u8 = null,
    minio_bucket: []const u8 = "pulse-raw",
    ingest_interval_s: u64 = 300,
    /// Worker identity for the Redis Streams consumer group (4.3).
    /// Distinct per worker process when scaling (compose --scale).
    worker_id: []const u8 = "worker-1",
    /// Precomputed briefing (4.4): recompute every N seconds, cache TTL.
    precompute_interval_s: u64 = 3600,
    precompute_ttl_s: u64 = 3600,
    /// Query-result cache TTL (Roadmap 4.5). 0 disables caching.
    query_cache_ttl_s: u64 = 300,
    /// Max sources fetched concurrently in one ingest run (Roadmap 4.5).
    max_concurrent_sources: usize = 4,
    /// Postgres connection pool size (Roadmap 4.5). 1 = the original
    /// single-connection design; higher values only help when store
    /// calls run concurrently.
    pg_pool_size: usize = 1,
    /// L1 in-process cache (Roadmap 6.2): entry cap, byte cap, TTL.
    l1_max_entries: usize = 512,
    l1_max_bytes: usize = 8 * 1024 * 1024,
    /// Popular searches (Roadmap 6.4): distinct-query cap, persistence
    /// file, save interval (records), and how many top queries to
    /// warm the cache with at boot.
    popular_max_tracked: usize = 1000,
    popular_path: []const u8 = "popular.json",
    popular_save_every: usize = 100,
    popular_warm_n: usize = 10,
    l1_ttl_s: u64 = 300,
    /// Parallel query fan-out (Roadmap 6.6): run the news + knowledge
    /// backends concurrently when the store is Postgres (pool/mutex
    /// guarded). Sequential otherwise. 0 disables fan-out entirely.
    parallel_query: bool = true,
    /// Fan-out deadline in milliseconds (Roadmap 6.6): stragglers are
    /// joined after the response; partial results are labelled.
    fanout_timeout_ms: u64 = 100,
    /// In-memory index (Roadmap 6.3): term cap and document cap, and
    /// how often (seconds) the server rebuilds it when the cache epoch
    /// moved (worker ingests bump the epoch).
    memindex_max_terms: usize = 50000,
    memindex_max_docs: usize = 100000,
    reindex_interval_s: u64 = 3600,
    /// Auto-tuning (Roadmap 6.10): off by default; opt in with
    /// PULSE_AUTOTUNE=1. Adjusts only the safe knobs within bounds,
    /// and logs every change.
    autotune_enabled: bool = false,
    /// Circuit breakers (Roadmap 6.11): consecutive failures that trip
    /// the breaker open, and the cooldown (seconds) before a trial call
    /// is allowed. The embedding breaker guards the external HTTP
    /// embedder (no per-request timeout exists in std.http.Client);
    /// the Redis breaker guards the L2 cache lookups. Both fall back
    /// to the degraded path that already exists (lexical / compute
    /// fresh) while open.
    embed_breaker_failures: u32 = 5,
    embed_breaker_cooldown_s: u64 = 60,
    redis_breaker_failures: u32 = 5,
    redis_breaker_cooldown_s: u64 = 60,
    rate_limit_per_minute: u32 = 100,
    rate_limit_per_day: u32 = 10000,
    /// TLS termination is handled by a reverse proxy in front of Pulse
    /// (the Zig 0.17.1 stdlib has no TLS server). Set
    /// PULSE_BEHIND_TLS_PROXY=1 when the proxy is in place; the audit
    /// command warns while it is unset.
    behind_tls_proxy: bool = false,
    /// Strict outbound mode: refuse plain-http feed URLs (Roadmap 5.1).
    /// Default false — one registry feed (Daily Observer) is http-only.
    require_https_fetches: bool = false,
    log_level: []const u8 = "info",
    /// Minutes east of UTC for time-aware queries (Africa/Monrovia = 0).
    tz_offset_minutes: i32 = 0,
    /// Retention: documents older than this many days are archived
    /// (compressed) and deleted by maintenance. 0 disables retention
    /// (aggregation + dedup reporting still run).
    retention_days: u32 = 365,
    /// Local directory for compressed retention archives.
    archive_dir: []const u8 = "archive",
    /// Seconds between maintenance passes in the worker loop.
    maintenance_interval_s: u64 = 86400,
    /// Embedding provider for semantic search: "local" (deterministic
    /// hashed lexical embedding, default), "external" (OpenAI-compatible
    /// API), or "none" (keyword search only).
    embedding_provider: []const u8 = "local",
    embedding_api_url: ?[]const u8 = null,
    embedding_api_key: ?[]const u8 = null,
    embedding_model: []const u8 = "text-embedding-3-small",
    /// Embedding dimensions. Must match the `embedding vector(N)` column
    /// (migration 003 uses 128); change both together.
    embedding_dims: usize = 128,
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

pub fn parseI32(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, s, 10) catch null;
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
    if (envOwned(alloc, env_map, "PULSE_API_KEY_PREVIOUS")) |v| {
        if (v.len > 0) cfg.api_key_previous = v;
    }
    if (envOwned(alloc, env_map, "PULSE_URL")) |v| {
        if (v.len > 0) cfg.pulse_url = v;
    }
    if (envOwned(alloc, env_map, "PULSE_SEARXNG_URL")) |v| {
        if (v.len > 0) cfg.searxng_url = v;
    }
    if (envOwned(alloc, env_map, "PULSE_CONSUMERS")) |v| {
        if (v.len > 0) {
            cfg.consumers = usage.parseConsumers(alloc, v) catch &.{};
            if (cfg.consumers.len == 0) {
                logging.warn("PULSE_CONSUMERS set but no valid entries parsed — falling back to the default consumer", &.{});
            }
        }
    }
    if (envOwned(alloc, env_map, "PULSE_AUDIT_LOG")) |v| {
        if (v.len > 0) cfg.audit_log_path = v;
    }
    if (envOwned(alloc, env_map, "DATABASE_URL")) |v| {
        if (v.len > 0) cfg.database_url = v;
    }
    if (envOwned(alloc, env_map, "PULSE_DATABASE_REPLICA_URL")) |v| {
        if (v.len > 0) cfg.database_replica_url = v;
    }
    if (envOwned(alloc, env_map, "PULSE_COUNTRY")) |v| {
        if (v.len > 0) cfg.country = v;
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
    if (envOwned(alloc, env_map, "PULSE_WORKER_ID")) |v| {
        if (v.len > 0) cfg.worker_id = v;
    }
    if (envOwned(alloc, env_map, "PULSE_PRECOMPUTE_INTERVAL_S")) |v| {
        cfg.precompute_interval_s = parseU64(v) orelse 3600;
    }
    if (envOwned(alloc, env_map, "PULSE_PRECOMPUTE_TTL_S")) |v| {
        cfg.precompute_ttl_s = parseU64(v) orelse 3600;
    }
    if (envOwned(alloc, env_map, "PULSE_QUERY_CACHE_TTL_S")) |v| {
        cfg.query_cache_ttl_s = parseU64(v) orelse 300;
    }
    if (envOwned(alloc, env_map, "PULSE_MAX_CONCURRENT_SOURCES")) |v| {
        cfg.max_concurrent_sources = @intCast(@max(1, @min(parseU64(v) orelse 4, 8)));
    }
    if (envOwned(alloc, env_map, "PULSE_PG_POOL_SIZE")) |v| {
        cfg.pg_pool_size = @intCast(parseU64(v) orelse 1);
    }
    if (envOwned(alloc, env_map, "PULSE_L1_MAX_ENTRIES")) |v| {
        cfg.l1_max_entries = @intCast(@max(1, parseU64(v) orelse 512));
    }
    if (envOwned(alloc, env_map, "PULSE_L1_MAX_BYTES")) |v| {
        cfg.l1_max_bytes = @intCast(@max(1024, parseU64(v) orelse 8 * 1024 * 1024));
    }
    if (envOwned(alloc, env_map, "PULSE_L1_TTL_S")) |v| {
        cfg.l1_ttl_s = parseU64(v) orelse 300;
    }
    if (envOwned(alloc, env_map, "PULSE_POPULAR_MAX_TRACKED")) |v| {
        cfg.popular_max_tracked = @intCast(@max(1, parseU64(v) orelse 1000));
    }
    if (envOwned(alloc, env_map, "PULSE_POPULAR_PATH")) |v| {
        if (v.len > 0) cfg.popular_path = v;
    }
    if (envOwned(alloc, env_map, "PULSE_POPULAR_SAVE_EVERY")) |v| {
        cfg.popular_save_every = @intCast(@max(1, parseU64(v) orelse 100));
    }
    if (envOwned(alloc, env_map, "PULSE_POPULAR_WARM_N")) |v| {
        cfg.popular_warm_n = @intCast(parseU64(v) orelse 10);
    }
    if (envOwned(alloc, env_map, "PULSE_PARALLEL_QUERY")) |v| {
        cfg.parallel_query = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (envOwned(alloc, env_map, "PULSE_FANOUT_TIMEOUT_MS")) |v| {
        cfg.fanout_timeout_ms = @max(10, parseU64(v) orelse 100);
    }
    if (envOwned(alloc, env_map, "PULSE_WEB_TIMEOUT_MS")) |v| {
        defer alloc.free(v);
        cfg.web_timeout_ms = @max(50, parseU64(v) orelse 1500);
    }
    if (envOwned(alloc, env_map, "PULSE_MEMINDEX_MAX_TERMS")) |v| {
        cfg.memindex_max_terms = @intCast(@max(100, parseU64(v) orelse 50000));
    }
    if (envOwned(alloc, env_map, "PULSE_MEMINDEX_MAX_DOCS")) |v| {
        cfg.memindex_max_docs = @intCast(@max(10, parseU64(v) orelse 100000));
    }
    if (envOwned(alloc, env_map, "PULSE_REINDEX_INTERVAL_S")) |v| {
        cfg.reindex_interval_s = @max(60, parseU64(v) orelse 3600);
    }
    if (envOwned(alloc, env_map, "PULSE_AUTOTUNE")) |v| {
        cfg.autotune_enabled = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (envOwned(alloc, env_map, "PULSE_BREAKER_EMBED_FAILURES")) |v| {
        cfg.embed_breaker_failures = @intCast(@max(1, @min(parseU64(v) orelse 5, 100)));
    }
    if (envOwned(alloc, env_map, "PULSE_BREAKER_EMBED_COOLDOWN_S")) |v| {
        cfg.embed_breaker_cooldown_s = @max(5, parseU64(v) orelse 60);
    }
    if (envOwned(alloc, env_map, "PULSE_BREAKER_REDIS_FAILURES")) |v| {
        cfg.redis_breaker_failures = @intCast(@max(1, @min(parseU64(v) orelse 5, 100)));
    }
    if (envOwned(alloc, env_map, "PULSE_BREAKER_REDIS_COOLDOWN_S")) |v| {
        cfg.redis_breaker_cooldown_s = @max(5, parseU64(v) orelse 60);
    }
    if (envOwned(alloc, env_map, "PULSE_RATE_LIMIT_PER_MINUTE")) |v| {
        cfg.rate_limit_per_minute = parseU32(v) orelse 100;
    }
    if (envOwned(alloc, env_map, "PULSE_RATE_LIMIT_PER_DAY")) |v| {
        cfg.rate_limit_per_day = parseU32(v) orelse 10000;
    }
    if (envOwned(alloc, env_map, "PULSE_BEHIND_TLS_PROXY")) |v| {
        cfg.behind_tls_proxy = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (envOwned(alloc, env_map, "PULSE_REQUIRE_HTTPS_FETCHES")) |v| {
        cfg.require_https_fetches = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (envOwned(alloc, env_map, "PULSE_RETENTION_DAYS")) |v| {
        if (parseU32(v)) |n| {
            if (n <= 3650) cfg.retention_days = n;
        }
    }
    if (envOwned(alloc, env_map, "PULSE_ARCHIVE_DIR")) |v| {
        if (v.len > 0) cfg.archive_dir = v;
    }
    if (envOwned(alloc, env_map, "PULSE_MAINTENANCE_INTERVAL_S")) |v| {
        cfg.maintenance_interval_s = parseU64(v) orelse 86400;
    }
    if (envOwned(alloc, env_map, "PULSE_LOG_LEVEL")) |v| cfg.log_level = v;
    if (envOwned(alloc, env_map, "PULSE_TZ_OFFSET_MINUTES")) |v| {
        if (parseI32(v)) |n| {
            if (n >= -720 and n <= 840) cfg.tz_offset_minutes = n;
        }
    }
    if (envOwned(alloc, env_map, "PULSE_EMBEDDING_PROVIDER")) |v| {
        if (std.mem.eql(u8, v, "local") or std.mem.eql(u8, v, "external") or std.mem.eql(u8, v, "none")) {
            cfg.embedding_provider = v;
        } else {
            logging.warn("unknown PULSE_EMBEDDING_PROVIDER, using local", &.{.{ .key = "value", .value = v }});
        }
    }
    if (envOwned(alloc, env_map, "PULSE_EMBEDDING_API_URL")) |v| {
        if (v.len > 0) cfg.embedding_api_url = v;
    }
    if (envOwned(alloc, env_map, "PULSE_EMBEDDING_API_KEY")) |v| {
        if (v.len > 0) cfg.embedding_api_key = v;
    }
    if (envOwned(alloc, env_map, "PULSE_EMBEDDING_MODEL")) |v| {
        if (v.len > 0) cfg.embedding_model = v;
    }
    if (envOwned(alloc, env_map, "PULSE_EMBEDDING_DIMS")) |v| {
        if (parseU64(v)) |n| {
            if (n >= 16 and n <= 4096) cfg.embedding_dims = @intCast(n);
        }
    }
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
    try std.testing.expectEqual(@as(u32, 365), cfg.retention_days);
    try std.testing.expectEqualStrings("archive", cfg.archive_dir);
    try std.testing.expectEqual(@as(u64, 86400), cfg.maintenance_interval_s);
    try std.testing.expectEqualStrings("lr", cfg.country);
    try std.testing.expect(cfg.database_replica_url == null);
}

test "load reads replica URL and country from env" {
    const alloc = std.testing.allocator;
    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put("PULSE_DATABASE_REPLICA_URL", "postgres://replica:5432/pulse");
    try map.put("PULSE_COUNTRY", "sl");
    const cfg = try load(alloc, &map);
    // Both values are dupes owned by the test allocator in this test.
    defer alloc.free(cfg.database_replica_url.?);
    defer alloc.free(cfg.country);
    try std.testing.expectEqualStrings("postgres://replica:5432/pulse", cfg.database_replica_url.?);
    try std.testing.expectEqualStrings("sl", cfg.country);
}

test "load reads searxng URL from env, null by default" {
    const alloc = std.testing.allocator;
    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    const empty_cfg = try load(alloc, &map);
    try std.testing.expect(empty_cfg.searxng_url == null);
    try std.testing.expectEqual(@as(u64, 1500), empty_cfg.web_timeout_ms);
    try map.put("PULSE_SEARXNG_URL", "http://searxng:8080");
    try map.put("PULSE_WEB_TIMEOUT_MS", "2500");
    const cfg = try load(alloc, &map);
    defer alloc.free(cfg.searxng_url.?);
    try std.testing.expectEqualStrings("http://searxng:8080", cfg.searxng_url.?);
    try std.testing.expectEqual(@as(u64, 2500), cfg.web_timeout_ms);
}

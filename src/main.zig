//! Pulse CLI: `pulse serve` | `pulse worker [--once]` | `pulse migrate` |
//! `pulse status` | `pulse keygen` | `pulse maintenance`.
//!
//! Zig 0.17.1 entry point: main takes `std.process.Init`, which carries the
//! Io implementation, the allocator, argv, and the environment map — no
//! `std.process.argsAlloc` / `getEnvVarOwned` (both removed in this std).
//!
//! Storage selection: DATABASE_URL unset -> in-memory store (dev default).
//! DATABASE_URL set -> PostgreSQL store; migrations run on boot, and the
//! process fails fast if Postgres is unreachable (never silently fall back
//! to memory while the operator believes data is persisted).
//!
//! CLI output goes to stderr via std.debug.print (this std has no
//! std.io.getStdOut); that is fine for an operator-run CLI.

const std = @import("std");
const logging = @import("common/logging.zig");
const timex = @import("common/time.zig");
const config = @import("config/config.zig");
const repository = @import("storage/repository.zig");
const knowledge = @import("storage/knowledge.zig");
const maintenance = @import("storage/maintenance.zig");
const memory = @import("storage/memory.zig");
const postgres = @import("storage/postgres.zig");
const postgres_knowledge = @import("storage/postgres_knowledge.zig");
const redis = @import("storage/redis.zig");
const object_store = @import("storage/object_store.zig");
const pipeline = @import("ingestion/pipeline.zig");
const facebook = @import("ingestion/connectors/facebook/facebook.zig");
const fb_notifications = @import("ingestion/connectors/facebook/notifications.zig");
const sources = @import("ingestion/sources.zig");
const auth = @import("api/auth.zig");
const ratelimit = @import("api/ratelimit.zig");
const metrics = @import("api/metrics.zig");
const server = @import("api/server.zig");
const worker = @import("workers/worker.zig");
const providers = @import("ai/providers.zig");

fn redisSinkPublish(ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void {
    const bus: *redis.EventBus = @ptrCast(@alignCast(ptr));
    _ = try bus.publishDocumentCollected(alloc, doc_id, source_id);
}

fn printStatus(cfg: config.Config) void {
    std.debug.print(
        \\{{"version":"0.1.0","host":"{s}","port":{d},"auth_configured":{},"store":"{s}","database_configured":{},"redis_configured":{},"minio_configured":{},"sources_total":{d},"sources_enabled":{d}}}
        \\
    , .{
        cfg.host,
        cfg.port,
        cfg.api_key != null,
        if (cfg.database_url != null) "postgres" else "memory",
        cfg.database_url != null,
        cfg.redis_url != null,
        cfg.minio_endpoint != null,
        sources.sources.len,
        sources.enabledCount(),
    });
}

pub fn main(init: std.process.Init) !void {
    // Process-lifetime allocations use the runtime arena (freed at exit with
    // no per-allocation leak report); the GPA would report every
    // never-freed process-lifetime allocation as a leak in debug builds.
    const alloc = init.arena.allocator();
    const io = init.io;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    const cmd: []const u8 = args_it.next() orelse "serve";
    const cmd_arg: ?[]const u8 = args_it.next();

    if (std.mem.eql(u8, cmd, "keygen")) {
        const key = try auth.generateKey(alloc);
        std.debug.print("{s}\n", .{key});
        return;
    }

    const cfg = try config.load(alloc, init.environ_map);
    logging.setLevel(logging.parseLevel(cfg.log_level));

    if (std.mem.eql(u8, cmd, "status")) {
        printStatus(cfg);
        return;
    }

    if (std.mem.eql(u8, cmd, "migrate")) {
        const url = cfg.database_url orelse {
            logging.err("migrate needs DATABASE_URL", &.{});
            std.process.exit(2);
        };
        try postgres.runMigrations(alloc, io, url, "migrations");
        logging.info("migrations applied", &.{});
        return;
    }

    const is_worker = std.mem.eql(u8, cmd, "worker");
    const once = is_worker and (cmd_arg != null and std.mem.eql(u8, cmd_arg.?, "--once"));
    if (!std.mem.eql(u8, cmd, "serve") and !is_worker and !std.mem.eql(u8, cmd, "maintenance")) {
        logging.err("unknown command (serve | worker [--once] | migrate | status | keygen | maintenance)", &.{});
        std.process.exit(2);
    }

    if (cfg.api_key == null) {
        logging.warn("PULSE_API_KEY is not set: API runs in open dev mode (no auth on /v1/query and /v1/ingest)", &.{});
    }

    // --- storage ---
    var mem_store: ?*memory.MemoryStore = null;
    var pg_store: ?*postgres.PostgresStore = null;
    var repo: repository.Repository = undefined;
    var store_name: []const u8 = "memory";
    var ks: ?knowledge.KnowledgeStore = null;
    var mem_knowledge: ?*knowledge.MemoryKnowledge = null;
    var pg_knowledge: ?*postgres_knowledge.PostgresKnowledge = null;
    if (cfg.database_url) |url| {
        logging.info("opening postgres store", &.{});
        const pg = try alloc.create(postgres.PostgresStore);
        pg.* = try postgres.PostgresStore.init(alloc, io, url);
        // Fresh `compose up` should just work: migrate on boot.
        try postgres.runMigrations(alloc, io, url, "migrations");
        pg_store = pg;
        repo = pg.asRepository();
        store_name = "postgres";
        const pgk = try alloc.create(postgres_knowledge.PostgresKnowledge);
        pgk.* = try postgres_knowledge.PostgresKnowledge.init(alloc, io, url);
        pg_knowledge = pgk;
        ks = pgk.asKnowledge();
    } else {
        const mem = try alloc.create(memory.MemoryStore);
        mem.* = memory.MemoryStore.init(alloc);
        mem_store = mem;
        repo = mem.asRepository();
        const mk = try alloc.create(knowledge.MemoryKnowledge);
        mk.* = knowledge.MemoryKnowledge.init(alloc);
        mem_knowledge = mk;
        ks = mk.asKnowledge();
    }

    // --- redis (optional; streams + cache). Failure warns, never blocks boot.
    var redis_client: ?*redis.RedisClient = null;
    var bus: ?redis.EventBus = null;
    var sink: ?pipeline.EventSink = null;
    if (cfg.redis_url) |url| {
        const c = alloc.create(redis.RedisClient) catch null;
        if (c) |client| {
            if (redis.RedisClient.connect(alloc, io, url)) |connected| {
                client.* = connected;
                redis_client = client;
                bus = redis.EventBus.init(client);
                sink = .{ .ptr = &bus.?, .publish = redisSinkPublish };
            } else |_| {
                logging.warn("redis unavailable: continuing without streams/cache", &.{});
                alloc.destroy(client);
            }
        }
    }

    // --- minio raw archive (optional) ---
    var archiver = object_store.S3Client.init(alloc, io, cfg.minio_endpoint, cfg.minio_access_key, cfg.minio_secret_key, cfg.minio_bucket);
    if (archiver == null and cfg.minio_endpoint != null) {
        logging.warn("minio not fully configured (need endpoint + access key + secret key): raw archiving disabled", &.{});
    }

    var m = metrics.Metrics{};
    m.setDocumentsIndexed(@intCast(repo.countDocuments()));
    var limiter = ratelimit.RateLimiter.init(alloc, cfg.rate_limit_per_minute, cfg.rate_limit_per_day);
    defer limiter.deinit();

    // Embedding provider for semantic search + ingest-time embeddings.
    // "local" (default) is a deterministic hashed lexical embedding;
    // "external" needs PULSE_EMBEDDING_API_URL + KEY; "none" disables it.
    const embedder = try providers.makeEmbeddingProvider(
        alloc,
        io,
        cfg.embedding_provider,
        cfg.embedding_api_url,
        cfg.embedding_api_key,
        cfg.embedding_model,
        cfg.embedding_dims,
        init.environ_map,
    );
    if (embedder == null and std.mem.eql(u8, cfg.embedding_provider, "external")) {
        logging.warn("PULSE_EMBEDDING_PROVIDER=external but no URL/key set: semantic search disabled", &.{});
    }

    // --- facebook connector (Roadmap 3.2) ---
    // Notification store: Postgres when a database is configured
    // (durable server -> worker handoff), memory otherwise.
    // The store structs live in the process arena (never deinited).
    var notification_store: ?fb_notifications.NotificationStore = null;
    if (cfg.database_url) |url| {
        const pgn = try alloc.create(fb_notifications.PostgresNotifications);
        pgn.* = try fb_notifications.PostgresNotifications.init(alloc, io, url);
        notification_store = pgn.store();
    } else {
        const mn = try alloc.create(fb_notifications.MemoryNotifications);
        mn.* = fb_notifications.MemoryNotifications.init(alloc);
        notification_store = mn.store();
    }
    var fb_connector = try facebook.FacebookConnector.init(alloc, io, init.environ_map, notification_store);
    if (fb_connector.validate()) |reason| {
        logging.info("facebook connector unavailable", &.{.{ .key = "reason", .value = reason }});
    } else {
        logging.info("facebook connector ready", &.{
            .{ .key = "registered_pages", .value = try std.fmt.allocPrint(alloc, "{d}", .{fb_connector.registeredPages()}) },
        });
    }

    if (std.mem.eql(u8, cmd, "maintenance")) {
        const policy = maintenance.RetentionPolicy{
            .docs_retention_days = cfg.retention_days,
            .archive_dir = cfg.archive_dir,
        };
        const report = try maintenance.runMaintenance(alloc, io, repo, ks, policy, timex.nowSeconds(io));
        std.debug.print("maintenance: archived={d} deleted={d} exact_dupes={d} near_dupes={d} aggregates={d} archive={s}\n", .{
            report.archived,
            report.deleted,
            report.duplicates_exact,
            report.duplicates_near,
            report.aggregates_recorded,
            report.archive_path orelse "-",
        });
        return;
    }

    if (is_worker) {
        if (once) {
            const report = try worker.runOnce(alloc, io, repo, sink, if (archiver) |*a| a else null, &m, init.environ_map, embedder, ks, cfg.ingest_interval_s, &fb_connector);
            std.debug.print("ingest once: docs {d} -> {d}, {d} sources, had_error={}\n", .{
                report.docs_before,
                report.docs_after,
                report.sources.len,
                report.had_error,
            });
            return;
        }
        try worker.runLoop(alloc, io, cfg, repo, sink, if (archiver) |*a| a else null, &m, init.environ_map, embedder, ks, &fb_connector);
        return;
    }

    var srv = server.Server{
        .alloc = alloc,
        .io = io,
        .cfg = cfg,
        .repo = repo,
        .store_name = store_name,
        .metrics = &m,
        .limiter = &limiter,
        .sink = sink,
        .embedder = embedder,
        .knowledge = ks,
        .facebook = &fb_connector,
    };
    try srv.serve();
}

//! Pulse CLI: `pulse serve` | `pulse worker [--once]` | `pulse migrate` |
//! `pulse status` | `pulse keygen` | `pulse maintenance` | `pulse seed` |
//! `pulse briefing` | `pulse alerts` | `pulse loadtest [--url ...] [--threads N] [--requests N] [--query ...]` |
//! `pulse audit` | `pulse backup [--out <path>] [--keep N]` | `pulse restore --in <path>`.
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
const usage = @import("api/usage.zig");
const auditlog = @import("api/auditlog.zig");
const loadtest = @import("cli/loadtest.zig");
const audit = @import("cli/audit.zig");
const backup_cli = @import("cli/backup.zig");
const mock_sando = @import("cli/mock_sando.zig");
const repository = @import("storage/repository.zig");
const knowledge = @import("storage/knowledge.zig");
const seed = @import("seed/liberia.zig");
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
const l1cache = @import("api/l1cache.zig");
const popular = @import("api/popular.zig");
const cache = @import("api/cache.zig");
const memindex = @import("engine/memindex.zig");
const autotune = @import("engine/autotune.zig");
const breaker = @import("engine/breaker.zig");
const worker = @import("workers/worker.zig");
const providers = @import("ai/providers.zig");

fn redisSinkPublish(ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void {
    const bus: *redis.EventBus = @ptrCast(@alignCast(ptr));
    _ = try bus.publishDocumentCollected(alloc, doc_id, source_id);
}

fn printStatus(cfg: config.Config) void {
    std.debug.print(
        \\{{"version":"0.1.0","api_version":"1","country":"{s}","host":"{s}","port":{d},"auth_configured":{},"key_rotation_configured":{},"store":"{s}","database_configured":{},"read_replica_configured":{},"redis_configured":{},"minio_configured":{},"sources_total":{d},"sources_enabled":{d},"consumers_configured":{d},"audit_log_file":{}}}
        \\
    , .{
        cfg.country,
        cfg.host,
        cfg.port,
        cfg.api_key != null,
        cfg.api_key_previous != null,
        if (cfg.database_url != null) "postgres" else "memory",
        cfg.database_url != null,
        cfg.database_replica_url != null,
        cfg.redis_url != null,
        cfg.minio_endpoint != null,
        sources.sources.len,
        sources.enabledCount(),
        cfg.consumers.len,
        cfg.audit_log_path != null,
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

    if (std.mem.eql(u8, cmd, "loadtest")) {
        var rest: std.ArrayList([]const u8) = .empty;
        if (cmd_arg) |a| try rest.append(alloc, a);
        while (args_it.next()) |a| try rest.append(alloc, a);
        try loadtest.run(alloc, rest.items);
        return;
    }

    const cfg = try config.load(alloc, init.environ_map);
    logging.setLevel(logging.parseLevel(cfg.log_level));

    if (std.mem.eql(u8, cmd, "audit")) {
        std.process.exit(audit.run(alloc, io, cfg));
    }

    if (std.mem.eql(u8, cmd, "backup") or std.mem.eql(u8, cmd, "restore")) {
        const url = cfg.database_url orelse {
            logging.err("backup/restore need DATABASE_URL", &.{});
            std.process.exit(2);
        };
        // Remaining args: --out <path> --keep <n> (backup), --in <path> (restore).
        var out_path: ?[]const u8 = null;
        var in_path: ?[]const u8 = null;
        var keep: usize = backup_cli.default_keep;
        var flag_args: std.ArrayList([]const u8) = .empty;
        if (cmd_arg) |a| try flag_args.append(alloc, a);
        while (args_it.next()) |a| try flag_args.append(alloc, a);
        var i: usize = 0;
        while (i < flag_args.items.len) : (i += 1) {
            const a = flag_args.items[i];
            if (std.mem.eql(u8, a, "--out") and i + 1 < flag_args.items.len) {
                out_path = flag_args.items[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--in") and i + 1 < flag_args.items.len) {
                in_path = flag_args.items[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--keep") and i + 1 < flag_args.items.len) {
                keep = std.fmt.parseInt(usize, flag_args.items[i + 1], 10) catch backup_cli.default_keep;
                i += 1;
            } else {
                logging.err("unknown backup/restore flag (backup [--out <path>] [--keep N] | restore --in <path>)", &.{});
                std.process.exit(2);
            }
        }
        if (std.mem.eql(u8, cmd, "backup")) {
            backup_cli.backup(alloc, io, url, out_path, keep) catch |e| {
                logging.err("backup failed", &.{.{ .key = "error", .value = @errorName(e) }});
                std.process.exit(1);
            };
        } else {
            const path = in_path orelse {
                logging.err("restore needs --in <path>", &.{});
                std.process.exit(2);
            };
            backup_cli.restore(alloc, io, url, path) catch |e| {
                logging.err("restore failed", &.{.{ .key = "error", .value = @errorName(e) }});
                std.process.exit(1);
            };
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "mock-sando")) {
        const question = cmd_arg orelse {
            logging.err("mock-sando needs a question (mock-sando \"<question>\" [--county <name>] [--pulse-url <url>] [--api-key <key>])", &.{});
            std.process.exit(2);
        };
        var flag_args: std.ArrayList([]const u8) = .empty;
        try flag_args.append(alloc, question);
        while (args_it.next()) |a| try flag_args.append(alloc, a);
        std.process.exit(mock_sando.run(alloc, io, cfg, flag_args.items));
    }

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
    if (!std.mem.eql(u8, cmd, "serve") and !is_worker and !std.mem.eql(u8, cmd, "maintenance") and !std.mem.eql(u8, cmd, "seed") and !std.mem.eql(u8, cmd, "briefing") and !std.mem.eql(u8, cmd, "alerts") and !std.mem.eql(u8, cmd, "loadtest") and !std.mem.eql(u8, cmd, "audit") and !std.mem.eql(u8, cmd, "backup") and !std.mem.eql(u8, cmd, "restore") and !std.mem.eql(u8, cmd, "mock-sando") and !std.mem.eql(u8, cmd, "reindex")) {
        logging.err("unknown command (serve | worker [--once] | migrate | status | keygen | maintenance | seed | briefing | alerts | loadtest | audit | backup | restore | mock-sando | reindex)", &.{});
        std.process.exit(2);
    }

    if (cfg.api_key == null and cfg.api_key_previous == null) {
        logging.warn("PULSE_API_KEY is not set: API runs in open dev mode (no auth on /v1/query and /v1/ingest)", &.{});
    }
    if (cfg.api_key_previous != null) {
        logging.info("API key rotation active: previous key still accepted (remove PULSE_API_KEY_PREVIOUS once clients migrate)", &.{});
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
        pg.* = try postgres.PostgresStore.initWithPoolSize(alloc, io, url, cfg.pg_pool_size);
        // Fresh `compose up` should just work: migrate on boot.
        try postgres.runMigrations(alloc, io, url, "migrations");
        // Read replica (Roadmap 5.5): a replica that fails to connect is
        // logged and ignored — reads stay on the primary.
        if (cfg.database_replica_url) |replica_url| {
            pg.setReplica(replica_url) catch |e| {
                logging.warn("read replica unavailable, reads stay on primary", &.{ .{ .key = "error", .value = @errorName(e) } });
            };
            if (pg.hasReplica()) {
                logging.info("read replica configured: search reads route to the replica", &.{});
            }
        }
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
    // `var`: the external provider is wrapped in a circuit breaker
    // (Roadmap 6.11) just below.
    var embedder = try providers.makeEmbeddingProvider(
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

    // Circuit breaker for the external embedder (Roadmap 6.11): the
    // wrapper short-circuits to an error while open, and both call
    // sites (query search + ingest) already fall back to lexical on
    // embed failure. The local provider is never wrapped — it cannot
    // fail and does no I/O. The breaker lives in the process arena
    // (never deinited); the server keeps the pointer for /metrics.
    var embed_breaker: ?*breaker.CircuitBreaker = null;
    if (embedder != null and std.mem.eql(u8, cfg.embedding_provider, "external")) {
        const eb = try alloc.create(breaker.CircuitBreaker);
        eb.* = breaker.CircuitBreaker.init(cfg.embed_breaker_failures, cfg.embed_breaker_cooldown_s * 1000);
        const wrapped = try alloc.create(breaker.BreakerEmbedding);
        wrapped.* = .{ .inner = embedder.?, .breaker = eb, .io = io };
        embedder = wrapped.provider();
        embed_breaker = eb;
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

    if (std.mem.eql(u8, cmd, "seed")) {
        const report = try seed.seed(alloc, ks.?);
        std.debug.print("seed: locations={d} facilities={d} statistics={d} store={s} verified_at={s}\n", .{
            report.locations,
            report.facilities,
            report.statistics,
            store_name,
            seed.verification_date,
        });
        return;
    }

    if (std.mem.eql(u8, cmd, "briefing")) {
        const precomputed = @import("intelligence/precomputed.zig");
        const b = try precomputed.computeBriefing(alloc, repo, ks, timex.nowSeconds(io));
        const payload = try precomputed.renderBriefing(alloc, b);
        std.debug.print("{s}\n", .{payload});
        return;
    }

    if (std.mem.eql(u8, cmd, "alerts")) {
        // Roadmap 7.3: read the breaking-alert stream back, newest
        // first. An empty stream is a real answer (nothing breaking
        // has been published), not an error.
        const alerts_mod = @import("intelligence/alerts.zig");
        const c = redis_client orelse {
            std.debug.print("alerts: no redis configured (REDIS_URL unset) — stream unavailable\n", .{});
            return;
        };
        const entries = c.xrevrange(alloc, alerts_mod.alert_stream, 20) catch |err| {
            std.debug.print("alerts: failed to read stream {s}: {s}\n", .{ alerts_mod.alert_stream, @errorName(err) });
            return;
        };
        if (entries.len == 0) {
            std.debug.print("alerts: no alerts in stream {s}\n", .{alerts_mod.alert_stream});
            return;
        }
        for (entries) |e| {
            var kind: []const u8 = "?";
            var title: []const u8 = "?";
            var srcs: []const u8 = "?";
            var docs: []const u8 = "?";
            var imp: []const u8 = "?";
            for (e.fields) |f| {
                if (std.mem.eql(u8, f.name, "kind")) kind = f.value;
                if (std.mem.eql(u8, f.name, "title")) title = f.value;
                if (std.mem.eql(u8, f.name, "sources")) srcs = f.value;
                if (std.mem.eql(u8, f.name, "doc_count")) docs = f.value;
                if (std.mem.eql(u8, f.name, "importance")) imp = f.value;
            }
            std.debug.print("{s} [{s}] {s} sources={s} docs={s} importance={s}\n", .{ e.id, kind, title, srcs, docs, imp });
        }
        return;
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

    if (std.mem.eql(u8, cmd, "reindex")) {
        // Roadmap 6.5: rebuild the in-memory index from the store and
        // report the measured result. The server does this at boot and
        // on epoch change; this command rebuilds it on demand.
        var idx = memindex.MemIndex.init(alloc, cfg.memindex_max_terms, cfg.memindex_max_docs, 64 * 1024 * 1024);
        defer idx.deinit();
        const start_ms = timex.nowMillis(io);
        const report = try idx.buildFromRepo(alloc, repo, timex.nowMillis(io), start_ms);
        std.debug.print("reindex: docs_seen={d} docs_added={d} docs_evicted={d} terms={d} duration_ms={d}\n", .{
            report.docs_seen,
            report.docs_added,
            report.docs_evicted,
            report.terms,
            report.duration_ms,
        });
        return;
    }

    if (is_worker) {
        if (once) {
            const report = try worker.runOnce(alloc, io, repo, sink, if (archiver) |*a| a else null, &m, init.environ_map, embedder, ks, cfg.ingest_interval_s, cfg.max_concurrent_sources, &fb_connector);
            std.debug.print("ingest once: docs {d} -> {d}, {d} sources, had_error={}\n", .{
                report.docs_before,
                report.docs_after,
                report.sources.len,
                report.had_error,
            });
            return;
        }
        try worker.runLoop(alloc, io, cfg, repo, sink, if (archiver) |*a| a else null, &m, init.environ_map, embedder, ks, &fb_connector, redis_client);
        return;
    }

    // Usage tracking (Roadmap 5.3): Redis-backed when a client is
    // configured, in-memory otherwise. Process-lifetime.
    var usage_tracker = usage.UsageTracker.init(alloc, redis_client);

    // Audit sink (Roadmap 5.3): Postgres audit_log table (migration 011)
    // + optional JSONL file + structured log. Best-effort: a sink that
    // cannot connect degrades to log-only rather than failing boot.
    var audit_pg: ?*postgres.PgClient = null;
    var audit_pg_owned: ?*postgres.PgClient = null;
    if (cfg.database_url) |url| {
        const holder = alloc.create(postgres.PgClient) catch null;
        if (holder) |h| {
            if (postgres.PgClient.connect(alloc, io, url)) |connected| {
                h.* = connected;
                audit_pg = h;
                audit_pg_owned = h;
            } else |_| {
                logging.warn("audit: postgres unavailable, audit records go to log/file only", &.{});
                alloc.destroy(h);
            }
        }
    }
    defer if (audit_pg_owned) |h| alloc.destroy(h);
    var audit_file: ?std.Io.File = null;
    var audit_file_len: u64 = 0;
    if (cfg.audit_log_path) |p| {
        var cwd = std.Io.Dir.cwd();
        if (cwd.createFile(io, p, .{ .truncate = false })) |f| {
            audit_file = f;
            if (f.stat(io)) |st| {
                audit_file_len = @intCast(st.size);
            } else |_| {}
        } else |e| {
            logging.warn("audit: cannot open audit log file", &.{ .{ .key = "error", .value = @errorName(e) } });
        }
    }
    defer if (audit_file) |f| f.close(io);
    // Allocator for components that FREE memory (optimization
    // scope): the process arena's free is a no-op, so a component
    // that evicts/frees into it retains every freed byte forever
    // (the L1's evicted bodies alone grew RSS ~6 KB per fresh
    // distinct query once full). c_allocator (malloc/free) makes
    // those frees real, so each component's RSS is bounded by its
    // live size. No leak report: c_allocator never reports. Only
    // the four churning components use it; everything else keeps
    // the process arena.
    const churn_alloc = std.heap.c_allocator;
    var audit_sink = auditlog.AuditSink.init(churn_alloc, io, audit_pg, audit_file, audit_file_len);

    // L1 in-process cache (Roadmap 6.2): process-lifetime, sits in
    // front of the Redis (L2) query cache.
    var l1 = l1cache.L1Cache.init(churn_alloc, cfg.l1_max_entries, cfg.l1_max_bytes, cfg.l1_ttl_s);
    defer l1.deinit();

    // In-memory index (Roadmap 6.3/6.5): built from the store at boot.
    // A build failure is a warning, not a boot failure — queries fall
    // back to the store search.
    var mem_index = memindex.MemIndex.init(churn_alloc, cfg.memindex_max_terms, cfg.memindex_max_docs, 64 * 1024 * 1024);
    defer mem_index.deinit();
    var index_ptr: ?*memindex.MemIndex = null;
    var index_epoch: i64 = 0;
    var index_built_ms: i64 = 0;
    {
        const start_ms = timex.nowMillis(io);
        const report = mem_index.buildFromRepo(churn_alloc, repo, timex.nowMillis(io), start_ms) catch null;
        if (report) |r| {
            index_ptr = &mem_index;
            if (redis_client) |rc| index_epoch = cache.currentEpoch(rc, alloc);
            index_built_ms = timex.nowMillis(io);
            logging.info("memindex built", &.{
                .{ .key = "docs_added", .value = std.fmt.allocPrint(alloc, "{d}", .{r.docs_added}) catch "?" },
                .{ .key = "terms", .value = std.fmt.allocPrint(alloc, "{d}", .{r.terms}) catch "?" },
                .{ .key = "duration_ms", .value = std.fmt.allocPrint(alloc, "{d}", .{r.duration_ms}) catch "?" },
            });
        } else {
            logging.warn("memindex build failed, queries use the store search", &.{});
        }
    }

    // Popular searches (Roadmap 6.4): loaded from the persistence
    // file when present (a missing file just means no history yet).
    var pop = popular.PopularSearches.load(churn_alloc, io, cfg.popular_path, cfg.popular_max_tracked);
    defer pop.deinit();
    if (pop.tracked() > 0) {
        logging.info("popular searches loaded", &.{
            .{ .key = "tracked", .value = std.fmt.allocPrint(alloc, "{d}", .{pop.tracked()}) catch "?" },
            .{ .key = "path", .value = cfg.popular_path },
        });
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
        .redis = redis_client,
        .l1 = &l1,
        .index = index_ptr,
        .index_epoch = index_epoch,
        .index_built_ms = index_built_ms,
        .popular = &pop,
        .usage_tracker = &usage_tracker,
        .audit_sink = &audit_sink,
        .autotuner = autotune.Autotuner.init(cfg.autotune_enabled, cfg.l1_ttl_s, cfg.fanout_timeout_ms, cfg.max_concurrent_sources),
        .fanout_timeout_ms = cfg.fanout_timeout_ms,
        .redis_breaker = breaker.CircuitBreaker.init(cfg.redis_breaker_failures, cfg.redis_breaker_cooldown_s * 1000),
        .embed_breaker = embed_breaker,
        .reindex_interval_s = cfg.reindex_interval_s,
        .req_arena = std.heap.ArenaAllocator.init(alloc),
    };
    // Cache warming (Roadmap 6.4): run the most popular queries
    // through the pipeline and store the answers in L1/L2, so the
    // first real user of a popular query gets an instant hit.
    srv.warmCache();
    try srv.serve();
}

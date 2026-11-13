//! Background worker: runs the ingestion pipeline on a schedule.
//! `pulse worker` loops forever; `pulse worker --once` runs a single pass
//! (used by tests and the smoke test).

const std = @import("std");
const logging = @import("../common/logging.zig");
const timex = @import("../common/time.zig");
const config = @import("../config/config.zig");
const repository = @import("../storage/repository.zig");
const knowledge = @import("../storage/knowledge.zig");
const maintenance = @import("../storage/maintenance.zig");
const pipeline = @import("../ingestion/pipeline.zig");
const facebook = @import("../ingestion/connectors/facebook/facebook.zig");
const object_store = @import("../storage/object_store.zig");
const metrics = @import("../api/metrics.zig");
const providers = @import("../ai/providers.zig");
const redis = @import("../storage/redis.zig");
const cache = @import("../api/cache.zig");
const realtime = @import("realtime.zig");
const precomputed = @import("../intelligence/precomputed.zig");
const autotune = @import("../engine/autotune.zig");

pub fn runOnce(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    sink: ?pipeline.EventSink,
    archiver: ?*object_store.S3Client,
    m: *metrics.Metrics,
    environ: ?*const std.process.Environ.Map,
    embedder: ?providers.EmbeddingProvider,
    ks: ?knowledge.KnowledgeStore,
    default_interval_s: u64,
    /// Bounded worker concurrency for the fetch phase (Roadmap 4.5).
    max_concurrent_sources: usize,
    fb: ?*facebook.FacebookConnector,
) !pipeline.IngestReport {
    const report = try pipeline.runOnce(alloc, io, repo, sink, archiver, environ, embedder, ks, default_interval_s, max_concurrent_sources, fb);
    m.observeIngestRun(report.had_error);
    m.setDocumentsIndexed(@intCast(report.docs_after));
    logging.info("ingest run done", &.{
        .{ .key = "docs_before", .value = try std.fmt.allocPrint(alloc, "{d}", .{report.docs_before}) },
        .{ .key = "docs_after", .value = try std.fmt.allocPrint(alloc, "{d}", .{report.docs_after}) },
        .{ .key = "duration_ms", .value = try std.fmt.allocPrint(alloc, "{d}", .{report.duration_ms}) },
        .{ .key = "had_error", .value = if (report.had_error) "true" else "false" },
    });
    return report;
}

pub fn runLoop(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    repo: repository.Repository,
    sink: ?pipeline.EventSink,
    archiver: ?*object_store.S3Client,
    m: *metrics.Metrics,
    environ: ?*const std.process.Environ.Map,
    embedder: ?providers.EmbeddingProvider,
    ks: ?knowledge.KnowledgeStore,
    fb: ?*facebook.FacebookConnector,
    redis_client: ?*redis.RedisClient,
) !void {
    var last_maintenance: ?i64 = null;
    var last_precompute: ?i64 = null;
    // Real-time stream consumer (Roadmap 4.3): one consumer per worker
    // process, named by PULSE_WORKER_ID. No Redis -> no stream work.
    var consumer: ?realtime.StreamConsumer = null;
    var invalidator: ?cache.EpochInvalidator = null;
    if (redis_client) |rc| {
        invalidator = .{ .client = rc };
        consumer = .{ .client = rc, .consumer = cfg.worker_id };
        consumer.?.ensureGroup() catch |e| {
            logging.warn("stream group setup failed (stream work disabled this run)", &.{.{ .key = "error", .value = @errorName(e) }});
            consumer = null;
        };
    }
    // Bounded auto-tuning (Roadmap 6.10): the worker owns the
    // max-concurrent-sources knob. One adjustment per 10 runs at
    // most; every adjustment is logged. Disabled by default
    // (PULSE_AUTOTUNE=1 enables it).
    var tuner = autotune.Autotuner.init(cfg.autotune_enabled, cfg.l1_ttl_s, cfg.fanout_timeout_ms, cfg.max_concurrent_sources);
    var max_concurrent = cfg.max_concurrent_sources;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const maybe_report = runOnce(arena.allocator(), io, repo, sink, archiver, m, environ, embedder, ks, cfg.ingest_interval_s, max_concurrent, fb) catch |e| blk: {
            logging.err("ingest run failed", &.{.{ .key = "error", .value = @errorName(e) }});
            m.observeIngestRun(true);
            // A failed run still feeds the tuner: it counts as an
            // error signal (shed concurrency when sources struggle).
            if (tuner.maybeTuneWorker(.{ .run_errors = 1, .run_mean_duration_ms = 0 })) |adj| {
                max_concurrent = @intCast(adj.new_value);
                logging.info("autotune adjustment", &.{
                    .{ .key = "knob", .value = "max_concurrent_sources" },
                    .{ .key = "old", .value = std.fmt.allocPrint(arena.allocator(), "{d}", .{adj.old_value}) catch "?" },
                    .{ .key = "new", .value = std.fmt.allocPrint(arena.allocator(), "{d}", .{adj.new_value}) catch "?" },
                    .{ .key = "reason", .value = adj.reason },
                });
            }
            break :blk null;
        };
        if (maybe_report) |report| {
            // Tune from the run report: errors shed concurrency, slow
            // but clean fetches add it. Signals are computed from the
            // per-source reports (skipped sources excluded).
            var err_count: usize = 0;
            var dur_total: i64 = 0;
            var dur_n: usize = 0;
            for (report.sources) |s| {
                if (s.skipped) continue;
                err_count += s.errors;
                dur_total += s.duration_ms;
                dur_n += 1;
            }
            if (tuner.maybeTuneWorker(.{
                .run_errors = err_count,
                .run_mean_duration_ms = if (dur_n > 0) @divTrunc(dur_total, @as(i64, @intCast(dur_n))) else 0,
            })) |adj| {
                max_concurrent = @intCast(adj.new_value);
                logging.info("autotune adjustment", &.{
                    .{ .key = "knob", .value = "max_concurrent_sources" },
                    .{ .key = "old", .value = std.fmt.allocPrint(arena.allocator(), "{d}", .{adj.old_value}) catch "?" },
                    .{ .key = "new", .value = std.fmt.allocPrint(arena.allocator(), "{d}", .{adj.new_value}) catch "?" },
                    .{ .key = "reason", .value = adj.reason },
                });
            }
        }
        // Real-time processing (Roadmap 4.3): drain new stream entries,
        // then reclaim unacked ones (recovery). A Redis outage here is
        // logged and retried next iteration — never fatal.
        if (consumer) |*c| {
            const proc = invalidator.?.processor();
            if (c.drainOnce(arena.allocator(), proc)) |report| {
                if (report.read > 0) {
                    logging.info("stream drain done", &.{
                        .{ .key = "read", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.read}) },
                        .{ .key = "processed", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.processed}) },
                        .{ .key = "dead_lettered", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.dead_lettered}) },
                    });
                }
            } else |e| {
                logging.warn("stream drain failed", &.{.{ .key = "error", .value = @errorName(e) }});
            }
            if (c.reclaimPending(arena.allocator(), proc)) |report| {
                if (report.read > 0) {
                    logging.info("stream reclaim done", &.{
                        .{ .key = "read", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.read}) },
                        .{ .key = "processed", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.processed}) },
                        .{ .key = "dead_lettered", .value = try std.fmt.allocPrint(arena.allocator(), "{d}", .{report.dead_lettered}) },
                    });
                }
            } else |e| {
                logging.warn("stream reclaim failed", &.{.{ .key = "error", .value = @errorName(e) }});
            }
        }
        // Maintenance (Roadmap 3.5): aggregation, dedup report,
        // retention. At most once per maintenance_interval_s; a
        // failed pass logs and retries next interval — never fatal.
        const now = timex.nowSeconds(io);
        const due = last_maintenance == null or now - last_maintenance.? >= @as(i64, @intCast(cfg.maintenance_interval_s));
        if (due) {
            last_maintenance = now;
            const policy = maintenance.RetentionPolicy{
                .docs_retention_days = cfg.retention_days,
                .archive_dir = cfg.archive_dir,
            };
            _ = maintenance.runMaintenance(arena.allocator(), io, repo, ks, policy, now) catch |e| {
                logging.err("maintenance run failed", &.{.{ .key = "error", .value = @errorName(e) }});
            };
        }
        // Precomputed briefing (Roadmap 4.4): recompute on schedule
        // and cache in Redis. A stale or missing cache is fine — the
        // endpoint recomputes live; a failed refresh just retries.
        const now2 = timex.nowSeconds(io);
        const precompute_due = last_precompute == null or now2 - last_precompute.? >= @as(i64, @intCast(cfg.precompute_interval_s));
        if (precompute_due) {
            last_precompute = now2;
            if (redis_client) |rc| {
                if (precomputed.refreshBriefing(arena.allocator(), rc, repo, ks, now2, cfg.precompute_ttl_s)) {
                    logging.info("briefing refreshed", &.{});
                } else {
                    logging.warn("briefing refresh failed", &.{});
                }
            }
        }
        try std.Io.sleep(io, .{ .nanoseconds = @intCast(cfg.ingest_interval_s * std.time.ns_per_s) }, .boot);
    }
}

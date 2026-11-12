//! Background worker: runs the ingestion pipeline on a schedule.
//! `pulse worker` loops forever; `pulse worker --once` runs a single pass
//! (used by tests and the smoke test).

const std = @import("std");
const logging = @import("../common/logging.zig");
const config = @import("../config/config.zig");
const repository = @import("../storage/repository.zig");
const knowledge = @import("../storage/knowledge.zig");
const pipeline = @import("../ingestion/pipeline.zig");
const facebook = @import("../ingestion/connectors/facebook/facebook.zig");
const object_store = @import("../storage/object_store.zig");
const metrics = @import("../api/metrics.zig");
const providers = @import("../ai/providers.zig");

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
    fb: ?*facebook.FacebookConnector,
) !pipeline.IngestReport {
    const report = try pipeline.runOnce(alloc, io, repo, sink, archiver, environ, embedder, ks, default_interval_s, fb);
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
) !void {
    while (true) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        _ = runOnce(arena.allocator(), io, repo, sink, archiver, m, environ, embedder, ks, cfg.ingest_interval_s, fb) catch |e| {
            logging.err("ingest run failed", &.{.{ .key = "error", .value = @errorName(e) }});
            m.observeIngestRun(true);
        };
        try std.Io.sleep(io, .{ .nanoseconds = @intCast(cfg.ingest_interval_s * std.time.ns_per_s) }, .boot);
    }
}

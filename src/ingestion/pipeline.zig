//! Ingestion pipeline: fetch each enabled source, parse its RSS feed,
//! normalize items into Documents, insert them (idempotent), publish a
//! stream event per document, and archive the raw feed to MinIO.
//! A failure in one source never stops the others; archiving and event
//! publishing failures are warnings, not fatal — the query engine must keep
//! working on whatever is already indexed.

const std = @import("std");
const logging = @import("../common/logging.zig");
const timex = @import("../common/time.zig");
const types = @import("../common/types.zig");
const repository = @import("../storage/repository.zig");
const sources = @import("sources.zig");
const rss = @import("rss.zig");
const fetchers = @import("fetchers.zig");
const normalizer = @import("normalizer.zig");
const object_store = @import("../storage/object_store.zig");
const providers = @import("../ai/providers.zig");

/// Publish one document-collected event. Implemented by the Redis EventBus
/// (see storage/redis.zig); the pipeline only knows this interface so it
/// compiles and runs with or without Redis.
pub const EventSink = struct {
    ptr: *anyopaque,
    publish: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void,
};

pub const SourceReport = struct {
    source_id: []const u8,
    fetched: usize,
    inserted: usize,
    errors: usize,
    duration_ms: i64,
};

pub const IngestReport = struct {
    sources: []SourceReport,
    docs_before: usize,
    docs_after: usize,
    duration_ms: i64,
    had_error: bool,
};

fn ingestOneSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    source: sources.Source,
    sink: ?EventSink,
    archiver: ?*object_store.S3Client,
    now: i64,
    environ: ?*const std.process.Environ.Map,
    embedder: ?providers.EmbeddingProvider,
) SourceReport {
    const start = timex.nowMillis(io);
    var report = SourceReport{
        .source_id = source.id,
        .fetched = 0,
        .inserted = 0,
        .errors = 0,
        .duration_ms = 0,
    };
    const body = fetchers.fetchFeed(alloc, io, source.feed_url, environ) catch {
        report.errors += 1;
        report.duration_ms = timex.nowMillis(io) - start;
        return report;
    };
    // Archive the raw feed (best effort).
    if (archiver) |arc| {
        const key = std.fmt.allocPrint(alloc, "raw/{s}/{d}.xml", .{ source.id, now }) catch null;
        if (key) |k| {
            arc.putObject(k, body, "application/rss+xml") catch {
                logging.warn("raw archive failed", &.{.{ .key = "source", .value = source.id }});
            };
        }
    }
    const items = rss.parse(alloc, body) catch {
        report.errors += 1;
        report.duration_ms = timex.nowMillis(io) - start;
        return report;
    };
    report.fetched = items.len;
    for (items) |item| {
        var doc = normalizer.normalize(alloc, source, item, now) catch {
            report.errors += 1;
            continue;
        };
        // Ingest-time embedding: title + text, capped at 4000 bytes so an
        // external API call stays cheap. A failed embedding never blocks
        // the document — it is stored without one.
        if (embedder) |emb| {
            const full = std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text }) catch null;
            if (full) |text| {
                const capped = if (text.len > 4000) text[0..4000] else text;
                if (emb.embed(alloc, capped)) |vec| {
                    doc.embedding = vec;
                } else |_| {
                    logging.warn("ingest embedding failed", &.{.{ .key = "source", .value = source.id }});
                }
            }
        }
        repo.insertDocument(doc) catch {
            report.errors += 1;
            continue;
        };
        report.inserted += 1;
        if (sink) |s| {
            s.publish(s.ptr, alloc, doc.id, doc.source_id) catch {
                logging.warn("event publish failed", &.{.{ .key = "source", .value = source.id }});
            };
        }
    }
    report.duration_ms = timex.nowMillis(io) - start;
    return report;
}

pub fn runOnce(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    sink: ?EventSink,
    archiver: ?*object_store.S3Client,
    environ: ?*const std.process.Environ.Map,
    embedder: ?providers.EmbeddingProvider,
) !IngestReport {
    const start = timex.nowMillis(io);
    const now = timex.nowSeconds(io);
    const before = repo.countDocuments();
    var reports: std.ArrayList(SourceReport) = .empty;
    var had_error = false;
    for (sources.sources) |source| {
        if (!source.enabled) continue;
        const r = ingestOneSource(alloc, io, repo, source, sink, archiver, now, environ, embedder);
        if (r.errors > 0) had_error = true;
        logging.info("ingest source done", &.{
            .{ .key = "source", .value = source.id },
            .{ .key = "fetched", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.fetched}) },
            .{ .key = "inserted", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.inserted}) },
            .{ .key = "errors", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.errors}) },
        });
        try reports.append(alloc, r);
    }
    const after = repo.countDocuments();
    return .{
        .sources = try reports.toOwnedSlice(alloc),
        .docs_before = before,
        .docs_after = after,
        .duration_ms = timex.nowMillis(io) - start,
        .had_error = had_error,
    };
}

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
const knowledge = @import("../storage/knowledge.zig");
const compression = @import("../storage/compression.zig");
const sources = @import("sources.zig");
const source_manager = @import("source_manager.zig");
const rss = @import("rss.zig");
const connectors = @import("connectors.zig");
const facebook = @import("connectors/facebook/facebook.zig");
const normalizer = @import("normalizer.zig");
const validate = @import("validate.zig");
const entities = @import("../engine/entities.zig");
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
    /// True when the run skipped this source (disabled, auth missing,
    /// or interval not elapsed) — not an error, just no fetch.
    skipped: bool = false,
};

pub const IngestReport = struct {
    sources: []SourceReport,
    docs_before: usize,
    docs_after: usize,
    duration_ms: i64,
    had_error: bool,
};

/// Compressed archive key for a raw feed (Roadmap 3.5): the feed is
/// stored as a zstd frame, not raw XML, so archives stay small.
pub fn archiveKey(alloc: std.mem.Allocator, source_id: []const u8, now: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "raw/{s}/{d}.xml.zst", .{ source_id, now });
}

test "archive key is a compressed object key" {
    const key = try archiveKey(std.testing.allocator, "new-dawn", 1794441600);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("raw/new-dawn/1794441600.xml.zst", key);
}

/// Record one source's fetch outcome in the knowledge store (Roadmap
/// 3.1 health monitoring). Success resets the failure streak and stamps
/// last_success_at; failure keeps the old success time and grows the
/// streak. `docs_total` accumulates across runs. Never fatal.
fn recordHealth(
    ks: knowledge.KnowledgeStore,
    alloc: std.mem.Allocator,
    source_id: []const u8,
    now: i64,
    ok: bool,
    err_detail: ?[]const u8,
    inserted: usize,
) void {
    const prev = ks.getSourceHealth(alloc, source_id) catch null;
    const health = knowledge.SourceHealth{
        .source_id = source_id,
        .last_run_at = now,
        .last_success_at = if (ok) now else if (prev) |p| p.last_success_at else null,
        .last_error = if (ok) null else err_detail,
        .consecutive_failures = if (ok) 0 else if (prev) |p| p.consecutive_failures + 1 else 1,
        .docs_total = (if (prev) |p| p.docs_total else 0) + inserted,
    };
    ks.recordSourceHealth(alloc, health) catch |e| {
        logging.warn("source health record failed", &.{
            .{ .key = "source", .value = source_id },
            .{ .key = "error", .value = @errorName(e) },
        });
    };
}

/// Store one already-normalized, already-validated document:
/// ingest-time embedding, idempotent insert, knowledge recording
/// (entities + event clustering), event publish. Returns true when
/// the document was inserted. Knowledge/sink failures only warn —
/// the document is already stored. Shared by the RSS and Facebook
/// paths so both go through exactly one store step.
fn storeDocument(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    sink: ?EventSink,
    embedder: ?providers.EmbeddingProvider,
    ks: ?knowledge.KnowledgeStore,
    doc: *types.Document,
) bool {
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
                logging.warn("ingest embedding failed", &.{.{ .key = "source", .value = doc.source_id }});
            }
        }
    }
    repo.insertDocument(doc.*) catch return false;
    // Knowledge recording (3.4): entities + event clustering.
    // Failures are warnings only — the document is already stored.
    if (ks) |k| {
        const combined = std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text }) catch null;
        if (combined) |c| {
            if (entities.extract(alloc, c)) |ent| {
                k.recordEntities(alloc, doc.*, ent) catch |e| {
                    logging.warn("knowledge entities failed", &.{ .{ .key = "source", .value = doc.source_id }, .{ .key = "error", .value = @errorName(e) } });
                };
                if (k.upsertEventForDoc(alloc, doc.*, ent)) |ev| {
                    alloc.free(ev);
                } else |e| {
                    logging.warn("knowledge event failed", &.{ .{ .key = "source", .value = doc.source_id }, .{ .key = "error", .value = @errorName(e) } });
                }
            } else |_| {}
        }
    }
    if (sink) |s| {
        s.publish(s.ptr, alloc, doc.id, doc.source_id) catch {
            logging.warn("event publish failed", &.{.{ .key = "source", .value = doc.source_id }});
        };
    }
    return true;
}

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
    ks: ?knowledge.KnowledgeStore,
    limit: usize,
) SourceReport {
    const start = timex.nowMillis(io);
    var report = SourceReport{
        .source_id = source.id,
        .fetched = 0,
        .inserted = 0,
        .errors = 0,
        .duration_ms = 0,
    };
    // Fetch through the RSS connector (3.2 framework); the connector
    // is the single place where fetch policy lives.
    const body = connectors.rssConnector().fetch(alloc, io, source.feed_url, environ) catch {
        report.errors += 1;
        report.duration_ms = timex.nowMillis(io) - start;
        if (ks) |k| recordHealth(k, alloc, source.id, now, false, "fetch failed", 0);
        return report;
    };
    // Archive the raw feed, compressed (best effort). A compression
    // failure falls back to the raw body — archiving never blocks
    // ingestion, and the .zst key is only used for compressed bytes.
    if (archiver) |arc| {
        const compressed = compression.compress(alloc, body, compression.default_level) catch null;
        if (compressed) |zst| {
            defer alloc.free(zst);
            const key = std.fmt.allocPrint(alloc, "raw/{s}/{d}.xml.zst", .{ source.id, now }) catch null;
            if (key) |k| {
                arc.putObject(k, zst, "application/zstd") catch {
                    logging.warn("raw archive failed", &.{.{ .key = "source", .value = source.id }});
                };
            }
        } else {
            const key = std.fmt.allocPrint(alloc, "raw/{s}/{d}.xml", .{ source.id, now }) catch null;
            if (key) |k| {
                arc.putObject(k, body, "application/rss+xml") catch {
                    logging.warn("raw archive failed", &.{.{ .key = "source", .value = source.id }});
                };
            }
        }
    }
    const items = rss.parse(alloc, body) catch {
        report.errors += 1;
        report.duration_ms = timex.nowMillis(io) - start;
        if (ks) |k| recordHealth(k, alloc, source.id, now, false, "parse failed", 0);
        return report;
    };
    report.fetched = items.len;
    // Per-source collection limit (3.1): only the first N items of a
    // run are processed; the rest wait for the next run.
    const limited = items[0..@min(items.len, limit)];
    for (limited) |item| {
        var doc = normalizer.normalize(alloc, source, item, now) catch {
            report.errors += 1;
            continue;
        };
        // Validation (3.3): a malformed document is dropped and counted,
        // never stored half-valid.
        validate.validate(doc) catch {
            report.errors += 1;
            continue;
        };
        if (!storeDocument(alloc, repo, sink, embedder, ks, &doc)) {
            report.errors += 1;
            continue;
        }
        report.inserted += 1;
    }
    report.duration_ms = timex.nowMillis(io) - start;
    // Reached only when fetch + parse succeeded: the source is healthy
    // even if individual items failed validation/storage.
    if (ks) |k| recordHealth(k, alloc, source.id, now, true, null, report.inserted);
    return report;
}

/// Facebook leg (Roadmap 3.2): poll due registered pages through
/// the Facebook connector and store new posts through the same store
/// step as RSS. Unavailable (no token / no pages) reports a skipped
/// source, never an error. Health is recorded under "facebook" for
/// the run; per-page health lives in the connector's page states.
fn ingestFacebook(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    sink: ?EventSink,
    now: i64,
    environ: ?*const std.process.Environ.Map,
    embedder: ?providers.EmbeddingProvider,
    ks: ?knowledge.KnowledgeStore,
    fb: *facebook.FacebookConnector,
) SourceReport {
    const start = timex.nowMillis(io);
    var report = SourceReport{
        .source_id = "facebook",
        .fetched = 0,
        .inserted = 0,
        .errors = 0,
        .duration_ms = 0,
    };
    if (fb.validate() != null) {
        report.skipped = true;
        report.duration_ms = timex.nowMillis(io) - start;
        return report;
    }
    // Registry edits take effect without a restart.
    fb.reloadRegistry(io) catch |e| {
        logging.warn("facebook registry reload failed", &.{.{ .key = "error", .value = @errorName(e) }});
    };
    const outcome = fb.collect(alloc, io, environ, now) catch |e| {
        report.errors += 1;
        report.duration_ms = timex.nowMillis(io) - start;
        logging.warn("facebook collect failed", &.{.{ .key = "error", .value = @errorName(e) }});
        return report;
    };
    report.fetched = outcome.docs.len;
    for (outcome.docs) |*doc| {
        validate.validate(doc.*) catch {
            report.errors += 1;
            continue;
        };
        if (!storeDocument(alloc, repo, sink, embedder, ks, doc)) {
            report.errors += 1;
            continue;
        }
        report.inserted += 1;
    }
    report.duration_ms = timex.nowMillis(io) - start;
    if (ks) |k| recordHealth(k, alloc, "facebook", now, report.errors == 0, null, report.inserted);
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
    ks: ?knowledge.KnowledgeStore,
    default_interval_s: u64,
    /// Facebook connector (null when the process runs without one).
    /// Its collect() is a no-op while unconfigured.
    fb: ?*facebook.FacebookConnector,
) !IngestReport {
    const start = timex.nowMillis(io);
    const now = timex.nowSeconds(io);
    const before = repo.countDocuments();
    var reports: std.ArrayList(SourceReport) = .empty;
    var had_error = false;
    for (sources.sources) |source| {
        // Per-source runtime config (3.1): env overrides, auth state,
        // interval scheduling against the recorded last run.
        const rt = source_manager.resolve(alloc, environ, source, default_interval_s) catch {
            logging.warn("source config failed, using registry defaults", &.{.{ .key = "source", .value = source.id }});
            continue;
        };
        if (!rt.enabled) continue;
        if (rt.auth == .missing) {
            logging.warn("source skipped: credential env var not set", &.{
                .{ .key = "source", .value = source.id },
                .{ .key = "auth_env_var", .value = rt.auth_env_var orelse "" },
            });
            try reports.append(alloc, .{
                .source_id = source.id,
                .fetched = 0,
                .inserted = 0,
                .errors = 0,
                .duration_ms = 0,
                .skipped = true,
            });
            continue;
        }
        if (ks) |k| {
            const health = k.getSourceHealth(alloc, source.id) catch null;
            const last_run = if (health) |h| h.last_run_at else null;
            if (!source_manager.isDue(rt.interval_s, now, last_run)) {
                try reports.append(alloc, .{
                    .source_id = source.id,
                    .fetched = 0,
                    .inserted = 0,
                    .errors = 0,
                    .duration_ms = 0,
                    .skipped = true,
                });
                continue;
            }
        }
        const r = ingestOneSource(alloc, io, repo, source, sink, archiver, now, environ, embedder, ks, rt.limit);
        if (r.errors > 0) had_error = true;
        logging.info("ingest source done", &.{
            .{ .key = "source", .value = source.id },
            .{ .key = "fetched", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.fetched}) },
            .{ .key = "inserted", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.inserted}) },
            .{ .key = "errors", .value = try std.fmt.allocPrint(alloc, "{d}", .{r.errors}) },
        });
        try reports.append(alloc, r);
    }
    if (fb) |connector| {
        const r = ingestFacebook(alloc, io, repo, sink, now, environ, embedder, ks, connector);
        if (r.errors > 0) had_error = true;
        logging.info("ingest source done", &.{
            .{ .key = "source", .value = "facebook" },
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

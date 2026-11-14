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
const events_intel = @import("../intelligence/events.zig");
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

test "pipeline recordHealth: last_new_at moves only on an inserting run" {
    const alloc = std.testing.allocator;
    var k = knowledge.MemoryKnowledge.init(alloc);
    defer k.deinit();
    const ks = k.asKnowledge();
    // getSourceHealth dupes its strings into the caller's allocator;
    // free each read before the next (the store keeps its own copies).
    const freeHealth = struct {
        fn free(a: std.mem.Allocator, h: knowledge.SourceHealth) void {
            a.free(h.source_id);
            if (h.last_error) |e| a.free(e);
        }
    }.free;
    // First run inserts 2 docs: last_new_at stamps now.
    recordHealth(ks, alloc, "new-dawn", 1000, true, null, 2);
    var h = (try ks.getSourceHealth(alloc, "new-dawn")).?;
    try std.testing.expectEqual(@as(?i64, 1000), h.last_new_at);
    try std.testing.expectEqual(@as(usize, 2), h.docs_total);
    freeHealth(alloc, h);
    // Second run inserts nothing: the stamp stays, docs_total stays.
    recordHealth(ks, alloc, "new-dawn", 2000, true, null, 0);
    h = (try ks.getSourceHealth(alloc, "new-dawn")).?;
    try std.testing.expectEqual(@as(?i64, 1000), h.last_new_at);
    try std.testing.expectEqual(@as(usize, 2), h.docs_total);
    try std.testing.expectEqual(@as(?i64, 2000), h.last_success_at);
    freeHealth(alloc, h);
    // A failing run keeps the stamp too.
    recordHealth(ks, alloc, "new-dawn", 3000, false, "fetch failed", 0);
    h = (try ks.getSourceHealth(alloc, "new-dawn")).?;
    try std.testing.expectEqual(@as(?i64, 1000), h.last_new_at);
    try std.testing.expectEqual(@as(usize, 1), h.consecutive_failures);
    freeHealth(alloc, h);
    // A later inserting run moves it forward.
    recordHealth(ks, alloc, "new-dawn", 4000, true, null, 1);
    h = (try ks.getSourceHealth(alloc, "new-dawn")).?;
    try std.testing.expectEqual(@as(?i64, 4000), h.last_new_at);
    try std.testing.expectEqual(@as(usize, 3), h.docs_total);
    try std.testing.expectEqual(@as(usize, 0), h.consecutive_failures);
    freeHealth(alloc, h);
}

test "pipeline retraction: publisher marker flips the event to retracted" {
    const memory = @import("../storage/memory.zig");
    const alloc = std.testing.allocator;
    var store = memory.MemoryStore.init(alloc);
    defer store.deinit();
    var k = knowledge.MemoryKnowledge.init(alloc);
    defer k.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1794484800;
    var doc = types.Document{
        .id = "retract-1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/r1",
        .text = "Fuel stations in Monrovia report long queues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{},
        .content_hash = "retract-1",
    };
    try std.testing.expect(storeDocument(a, store.asRepository(), null, null, k.asKnowledge(), &doc));
    var doc2 = doc;
    doc2.id = "retract-2";
    doc2.url = "https://example.com/r2";
    doc2.content_hash = "retract-2";
    doc2.title = "RETRACTION: Fuel shortage hits Monrovia";
    doc2.text = "We retract our earlier report: there was no fuel shortage.";
    doc2.published_at = now - 1800;
    try std.testing.expect(storeDocument(a, store.asRepository(), null, null, k.asKnowledge(), &doc2));
    const ev = (try k.asKnowledge().getEvent(a, "retract-1")).?;
    try std.testing.expectEqualStrings("retracted", ev.status);
    try std.testing.expectEqual(@as(usize, 2), ev.doc_count);
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
        // Phase 2 monitoring: a new document arrived in this run.
        // Otherwise keep the previous value — a fetch with nothing
        // new is not activity, and the stamp never moves backwards.
        .last_new_at = if (ok and inserted > 0) now else if (prev) |p| p.last_new_at else null,
    };
    // getSourceHealth dupes its strings into the caller's allocator;
    // the health above only borrows scalars, so free them here.
    if (prev) |p| {
        alloc.free(p.source_id);
        if (p.last_error) |e| alloc.free(e);
    }
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
                    // Correction/retraction tracking (4.1): the
                    // publisher's own markers persist on the event.
                    // Only escalates (reported -> corrected ->
                    // retracted); a failure here is a warning, the
                    // document is already stored.
                    if (events_intel.scanRetraction(alloc, doc.title) catch null orelse
                        (events_intel.scanRetraction(alloc, doc.text) catch null)) |st| {
                        k.markEventStatus(alloc, ev, st) catch |e| {
                            logging.warn("knowledge event status failed", &.{ .{ .key = "error", .value = @errorName(e) } });
                        };
                    }
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

/// One source that is due for a fetch, with its per-source item limit
/// (3.1). Built sequentially in runOnce; the fetch itself is concurrent.
const DueSource = struct {
    source: sources.Source,
    limit: usize,
};

/// Fetch one URL body. Implemented by the RSS connector in production;
/// tests inject a fake. Runs on a worker thread with that thread's own
/// io — never the shared main io (see FetchTask).
pub const FetchFn = *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8) anyerror![]u8;

const RssFetchCtx = struct {
    environ: ?*const std.process.Environ.Map,
};

fn rssFetchFn(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8) anyerror![]u8 {
    const c: *RssFetchCtx = @ptrCast(@alignCast(ctx));
    return connectors.rssConnector().fetch(alloc, io, url, c.environ);
}

/// One source fetched + parsed on its own thread (Roadmap 4.5).
/// Each task owns its arena and its own `std.Io.Threaded` instance:
/// `HostName.connect` resolves DNS through `io.async`, and the
/// Threaded io's wait machinery is only reliable from the thread that
/// owns it — sharing the main io across spawned threads deadlocked/
/// corrupted state (same lesson as the PgPool mutex, 2026-11-13).
/// Nothing shared is touched on the worker: the repository, event
/// sink and knowledge store are only used by the main thread when it
/// processes the fetched results afterwards.
pub const FetchTask = struct {
    source: sources.Source,
    limit: usize,
    fetch_fn: FetchFn,
    fetch_ctx: *anyopaque,
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    body: ?[]u8 = null,
    items: ?[]rss.RawItem = null,
    err: ?anyerror = null,
    err_stage: enum { fetch, parse } = .fetch,
    duration_ms: i64 = 0,
    /// Shared concurrency accounting (atomics only — no shared heap).
    current: *std.atomic.Value(usize),
    max_seen: *std.atomic.Value(usize),

    fn run(self: *FetchTask) void {
        const io = self.threaded.io();
        const start = timex.nowMillis(io);
        const cur = self.current.fetchAdd(1, .monotonic) + 1;
        defer _ = self.current.fetchSub(1, .monotonic);
        var prev = self.max_seen.load(.monotonic);
        while (cur > prev) {
            if (self.max_seen.cmpxchgWeak(prev, cur, .monotonic, .monotonic) == null) break;
            prev = self.max_seen.load(.monotonic);
        }
        const alloc = self.arena.allocator();
        const body = self.fetch_fn(self.fetch_ctx, alloc, io, self.source.feed_url) catch |e| {
            self.err = e;
            self.err_stage = .fetch;
            self.duration_ms = timex.nowMillis(io) - start;
            return;
        };
        self.body = body;
        const items = rss.parse(alloc, body) catch |e| {
            self.err = e;
            self.err_stage = .parse;
            self.duration_ms = timex.nowMillis(io) - start;
            return;
        };
        self.items = items;
        self.duration_ms = timex.nowMillis(io) - start;
    }
};

/// Fetch a list of due sources concurrently, bounded by `max_concurrent`
/// (clamped to 1..32), in waves. Returns the tasks in source order; the
/// caller processes them sequentially and then deinits each task's
/// `threaded` + `arena` and frees the slice.
pub fn fetchConcurrent(
    alloc: std.mem.Allocator,
    due: []const DueSource,
    fetch_fn: FetchFn,
    fetch_ctx: *anyopaque,
    max_concurrent: usize,
    current: *std.atomic.Value(usize),
    max_seen: *std.atomic.Value(usize),
) ![]FetchTask {
    const tasks = try alloc.alloc(FetchTask, due.len);
    for (due, 0..) |d, i| {
        tasks[i] = .{
            .source = d.source,
            .limit = d.limit,
            .fetch_fn = fetch_fn,
            .fetch_ctx = fetch_ctx,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}),
            .current = current,
            .max_seen = max_seen,
        };
    }
    errdefer {
        for (tasks) |*t| {
            t.threaded.deinit();
            t.arena.deinit();
        }
        alloc.free(tasks);
    }
    const n = @max(1, @min(max_concurrent, 32));
    var start: usize = 0;
    while (start < tasks.len) {
        const end = @min(tasks.len, start + n);
        const wave = tasks[start..end];
        const threads = try alloc.alloc(std.Thread, wave.len);
        defer alloc.free(threads);
        var spawned: usize = 0;
        for (wave, 0..) |*t, i| {
            threads[i] = std.Thread.spawn(.{}, FetchTask.run, .{t}) catch |e| {
                for (threads[0..spawned]) |th| th.join();
                return e;
            };
            spawned += 1;
        }
        for (threads) |th| th.join();
        start = end;
    }
    return tasks;
}

/// Fetch + parse one source through the RSS connector. The error set
/// keeps the stage: FetchFailed vs ParseFailed, so health records and
/// the concurrent collector can tell them apart.
fn fetchSourceItems(alloc: std.mem.Allocator, io: std.Io, source: sources.Source, environ: ?*const std.process.Environ.Map) error{ FetchFailed, ParseFailed }!struct { body: []u8, items: []rss.RawItem } {
    const body = connectors.rssConnector().fetch(alloc, io, source.feed_url, environ) catch return error.FetchFailed;
    const items = rss.parse(alloc, body) catch return error.ParseFailed;
    return .{ .body = body, .items = items };
}

/// Archive + normalize + insert for an already-fetched source (Roadmap
/// 4.5 split). `body`/`items` are owned by the caller — in the
/// concurrent path they live in the fetch task's arena, which stays
/// alive until this returns. `fetch_ms` is the fetch phase's duration.
/// The sequential wrapper below reuses this unchanged.
fn ingestParsedSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    source: sources.Source,
    sink: ?EventSink,
    archiver: ?*object_store.S3Client,
    now: i64,
    embedder: ?providers.EmbeddingProvider,
    ks: ?knowledge.KnowledgeStore,
    body: []const u8,
    items: []const rss.RawItem,
    limit: usize,
    fetch_ms: i64,
) SourceReport {
    const start = timex.nowMillis(io);
    var report = SourceReport{
        .source_id = source.id,
        .fetched = items.len,
        .inserted = 0,
        .errors = 0,
        .duration_ms = 0,
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
    report.duration_ms = fetch_ms + (timex.nowMillis(io) - start);
    // Reached only when fetch + parse succeeded: the source is healthy
    // even if individual items failed validation/storage.
    if (ks) |k| recordHealth(k, alloc, source.id, now, true, null, report.inserted);
    return report;
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
    // Fetch through the RSS connector (3.2 framework); the connector
    // is the single place where fetch policy lives.
    const fetched = fetchSourceItems(alloc, io, source, environ) catch |e| {
        var report = SourceReport{
            .source_id = source.id,
            .fetched = 0,
            .inserted = 0,
            .errors = 1,
            .duration_ms = 0,
        };
        report.duration_ms = timex.nowMillis(io) - start;
        if (ks) |k| recordHealth(k, alloc, source.id, now, false, if (e == error.FetchFailed) "fetch failed" else "parse failed", 0);
        return report;
    };
    return ingestParsedSource(alloc, io, repo, source, sink, archiver, now, embedder, ks, fetched.body, fetched.items, limit, timex.nowMillis(io) - start);
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
    /// Bounded worker concurrency for the fetch phase (Roadmap 4.5).
    max_concurrent_sources: usize,
    /// Facebook connector (null when the process runs without one).
    /// Its collect() is a no-op while unconfigured.
    fb: ?*facebook.FacebookConnector,
) !IngestReport {
    const start = timex.nowMillis(io);
    const now = timex.nowSeconds(io);
    const before = repo.countDocuments();
    var reports: std.ArrayList(SourceReport) = .empty;
    var had_error = false;
    // 1. Due list, sequential: config resolution and the interval check
    // read the knowledge store and must not run concurrently.
    var due: std.ArrayList(DueSource) = .empty;
    defer due.deinit(alloc);
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
        try due.append(alloc, .{ .source = source, .limit = rt.limit });
    }
    // 2. Fetch the due sources concurrently (bounded waves). Each task
    // owns its arena + its own Threaded io; nothing shared is touched.
    var current: std.atomic.Value(usize) = .init(0);
    var max_seen: std.atomic.Value(usize) = .init(0);
    var rss_ctx = RssFetchCtx{ .environ = environ };
    const tasks = try fetchConcurrent(alloc, due.items, rssFetchFn, &rss_ctx, max_concurrent_sources, &current, &max_seen);
    defer {
        for (tasks) |*t| {
            t.threaded.deinit();
            t.arena.deinit();
        }
        alloc.free(tasks);
    }
    // 3. Process each fetched source sequentially on this thread: the
    // repository, event sink and knowledge store are never used
    // concurrently, so inserts stay serialized and idempotent.
    for (tasks) |*t| {
        const r = if (t.err) |_| blk: {
            const report = SourceReport{
                .source_id = t.source.id,
                .fetched = 0,
                .inserted = 0,
                .errors = 1,
                .duration_ms = t.duration_ms,
            };
            if (ks) |k| recordHealth(k, alloc, t.source.id, now, false, if (t.err_stage == .fetch) "fetch failed" else "parse failed", 0);
            break :blk report;
        } else ingestParsedSource(alloc, io, repo, t.source, sink, archiver, now, embedder, ks, t.body.?, t.items.?, t.limit, t.duration_ms);
        if (r.errors > 0) had_error = true;
        logging.info("ingest source done", &.{
            .{ .key = "source", .value = t.source.id },
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

/// Fake fetch for the concurrency test: sleeps `ms` (a raw nanosleep —
/// no Io instance exists on the worker thread) then returns a canned
/// one-item RSS feed. The sleep forces real overlap between waves.
fn fakeFetchSleep(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8) anyerror![]u8 {
    _ = io;
    _ = url;
    const ms: *const u64 = @ptrCast(@alignCast(ctx));
    var req = std.os.linux.timespec{ .sec = @intCast(ms.* / 1000), .nsec = @intCast((ms.* % 1000) * 1_000_000) };
    _ = std.os.linux.nanosleep(&req, null);
    return alloc.dupe(u8,
        \\<?xml version="1.0"?><rss><channel>
        \\<item><title>Boakai signs budget</title><link>https://example.com/a</link><description>Budget signed.</description><pubDate>Thu, 12 Nov 2026 10:00:00 +0000</pubDate></item>
        \\</channel></rss>
    );
}

test "fetchConcurrent: bounded concurrency, source order, real parse" {
    const alloc = std.testing.allocator;
    const due = [_]DueSource{
        .{ .source = .{ .id = "s1", .name = "S1", .home_url = "https://example.com/", .feed_url = "https://example.com/1.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
        .{ .source = .{ .id = "s2", .name = "S2", .home_url = "https://example.com/", .feed_url = "https://example.com/2.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
        .{ .source = .{ .id = "s3", .name = "S3", .home_url = "https://example.com/", .feed_url = "https://example.com/3.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
        .{ .source = .{ .id = "s4", .name = "S4", .home_url = "https://example.com/", .feed_url = "https://example.com/4.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
        .{ .source = .{ .id = "s5", .name = "S5", .home_url = "https://example.com/", .feed_url = "https://example.com/5.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
        .{ .source = .{ .id = "s6", .name = "S6", .home_url = "https://example.com/", .feed_url = "https://example.com/6.xml", .reliability = 0.7, .enabled = true }, .limit = 10 },
    };
    var current: std.atomic.Value(usize) = .init(0);
    var max_seen: std.atomic.Value(usize) = .init(0);
    const sleep_ms: u64 = 100;
    const tasks = try fetchConcurrent(alloc, &due, fakeFetchSleep, @constCast(&sleep_ms), 2, &current, &max_seen);
    defer {
        for (tasks) |*t| {
            t.threaded.deinit();
            t.arena.deinit();
        }
        alloc.free(tasks);
    }
    try std.testing.expectEqual(@as(usize, 6), tasks.len);
    // 6 sources x 100ms at concurrency 2: at most 2 ever ran at once.
    try std.testing.expectEqual(@as(usize, 2), max_seen.load(.monotonic));
    for (tasks, 0..) |*t, i| {
        try std.testing.expect(t.err == null);
        try std.testing.expect(t.items != null);
        try std.testing.expectEqual(@as(usize, 1), t.items.?.len);
        try std.testing.expectEqualStrings(due[i].source.id, t.source.id);
    }
}

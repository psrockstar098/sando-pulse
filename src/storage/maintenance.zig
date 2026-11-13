//! Knowledge maintenance (Roadmap 3.5): retention, compressed archives,
//! duplicate elimination, historical aggregation, and concise event
//! summaries. Runs on a schedule from the worker loop and on demand via
//! `pulse maintenance`. Rules:
//!
//! * Never delete a document without archiving it first (fail closed:
//!   if the archive write fails, nothing is deleted).
//! * Events, entities, topics, and monthly aggregates are never
//!   deleted — the historical record survives retention. Event
//!   doc_counts are recomputed after a retention run.
//! * Aggregation only counts what is stored; never invents data.
//! * Concise event summaries: the normalizer sets a 1–2 sentence
//!   extractive summary on every document at ingest; events carry
//!   the summary of their first document, and take the joining
//!   document's summary when they have none (see
//!   knowledge.upsertEventForDoc, both backends).

const std = @import("std");
const format = @import("../common/format.zig");
const types = @import("../common/types.zig");
const repository = @import("repository.zig");
const knowledge = @import("knowledge.zig");
const compression = @import("compression.zig");
const logging = @import("../common/logging.zig");

/// Retention policy (env: PULSE_RETENTION_DAYS, PULSE_ARCHIVE_DIR).
/// Documents older than `docs_retention_days` (by fetched_at) are
/// archived as compressed JSONL and then deleted from the store.
pub const RetentionPolicy = struct {
    docs_retention_days: u32 = 365,
    archive_dir: []const u8 = "archive",
};

pub const MaintenanceReport = struct {
    archived: usize = 0,
    deleted: usize = 0,
    duplicates_exact: usize = 0,
    duplicates_near: usize = 0,
    aggregates_recorded: usize = 0,
    archive_path: ?[]const u8 = null,
};

/// "YYYY-MM" (UTC) for a Unix timestamp. Civil-from-days algorithm
/// (same as the S3 client's date math). Zero-padding uses the shared
/// format helper — `{d:0>4}` prints a sign in this toolchain.
pub fn yearMonthOf(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const days = @divFloor(ts, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, m, 2);
    return alloc.dupe(u8, w.buffered());
}

/// "YYYYMMDD-HHMMSS" (UTC) for an archive filename.
fn stampOf(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const days = @divFloor(ts, 86400);
    const secs = @mod(ts, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try format.writeZeroPadded(&w, m, 2);
    try format.writeZeroPadded(&w, d, 2);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, @divFloor(secs, 3600), 2);
    try format.writeZeroPadded(&w, @divFloor(@mod(secs, 3600), 60), 2);
    try format.writeZeroPadded(&w, @mod(secs, 60), 2);
    return alloc.dupe(u8, w.buffered());
}

/// One archived document: the full record as JSONL, without the
/// embedding (vectors are re-derived on re-ingest; the archive is
/// the text record, not the index).
const ArchiveDoc = struct {
    id: []const u8,
    source_id: []const u8,
    title: []const u8,
    url: []const u8,
    text: []const u8,
    published_at: ?i64,
    fetched_at: i64,
    reliability: f32,
    topics: []const []const u8,
    content_hash: []const u8,
};

/// Archive every document fetched before `before_ts` into one
/// zstd-compressed JSONL file under `dir`, and return its path and
/// the number of documents written. The caller deletes the documents
/// only after this returns successfully. A missing `dir` is created.
/// Returns null path + 0 when there is nothing to archive.
pub fn archiveDocuments(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    dir: []const u8,
    before_ts: i64,
    now: i64,
) !struct { path: ?[]u8, count: usize } {
    var docs: std.ArrayList(types.Document) = .empty;
    defer docs.deinit(alloc);
    // One batch per archive call (max 1000 docs); the retention loop
    // runs again on the next maintenance pass for larger backlogs.
    const batch = try repo.scanDocuments(alloc, before_ts, 1000);
    try docs.appendSlice(alloc, batch);
    if (docs.items.len == 0) return .{ .path = null, .count = 0 };
    var jsonl: std.ArrayList(u8) = .empty;
    defer jsonl.deinit(alloc);
    for (docs.items) |d| {
        const ad = ArchiveDoc{
            .id = d.id,
            .source_id = d.source_id,
            .title = d.title,
            .url = d.url,
            .text = d.text,
            .published_at = d.published_at,
            .fetched_at = d.fetched_at,
            .reliability = d.reliability,
            .topics = d.topics,
            .content_hash = d.content_hash,
        };
        const line = try std.json.Stringify.valueAlloc(alloc, ad, .{});
        defer alloc.free(line);
        try jsonl.appendSlice(alloc, line);
        try jsonl.append(alloc, '\n');
    }
    const compressed = try compression.compress(alloc, jsonl.items, compression.default_level);
    defer alloc.free(compressed);
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |e| return e;
    const stamp = try stampOf(alloc, now);
    const path = try std.fmt.allocPrint(alloc, "{s}/archive-{s}.jsonl.zst", .{ dir, stamp });
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(compressed);
    try w.interface.flush();
    return .{ .path = path, .count = docs.items.len };
}

/// Enforce the retention policy: archive documents older than the
/// cutoff, then delete them, then recompute event doc_counts.
/// Returns how many were archived and deleted. Nothing is deleted
/// when the archive step fails or finds nothing.
pub fn enforceRetention(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    ks: ?knowledge.KnowledgeStore,
    policy: RetentionPolicy,
    now: i64,
) !struct { archived: usize, deleted: usize, archive_path: ?[]u8 } {
    // 0 days disables retention entirely (never delete everything).
    if (policy.docs_retention_days == 0) return .{ .archived = 0, .deleted = 0, .archive_path = null };
    const cutoff = now - @as(i64, @intCast(policy.docs_retention_days)) * 86400;
    const arc = try archiveDocuments(alloc, io, repo, policy.archive_dir, cutoff, now);
    if (arc.count == 0) return .{ .archived = 0, .deleted = 0, .archive_path = null };
    const old = try repo.scanDocuments(alloc, cutoff, 1000);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (old) |d| try ids.append(alloc, d.id);
    const deleted = try repo.deleteDocuments(ids.items);
    if (ks) |k| {
        try k.recomputeEventCounts();
    }
    return .{ .archived = arc.count, .deleted = deleted, .archive_path = arc.path };
}

pub const DuplicateReport = struct {
    /// Documents sharing a content hash (should always be 0 — the
    /// store enforces uniqueness; a nonzero count is a bug signal).
    exact: usize = 0,
    /// Documents with the same normalized title from the same source
    /// (republished / syndicated copies).
    near: usize = 0,
};

fn normalizeTitle(alloc: std.mem.Allocator, title: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var prev_space = true; // collapse runs + trim edges
    for (title) |c| {
        const lower = std.ascii.toLower(c);
        if (lower == ' ' or lower == '\t' or lower == '\n') {
            if (!prev_space) try out.append(alloc, ' ');
            prev_space = true;
        } else {
            try out.append(alloc, lower);
            prev_space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(alloc);
}

/// Duplicate content elimination (report only — nothing is deleted
/// by this pass; the operator decides). Exact duplicates share a
/// content hash; near duplicates share a normalized title from the
/// same source. Scans up to `limit` documents.
pub fn findDuplicates(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    limit: usize,
) !DuplicateReport {
    const docs = try repo.scanDocuments(alloc, null, limit);
    var hashes = std.StringHashMap(void).init(alloc);
    defer hashes.deinit();
    var titles = std.StringHashMap(void).init(alloc);
    defer titles.deinit();
    var report = DuplicateReport{};
    for (docs) |d| {
        if (hashes.contains(d.content_hash)) {
            report.exact += 1;
        } else {
            try hashes.put(d.content_hash, {});
        }
        const norm = try normalizeTitle(alloc, d.title);
        defer alloc.free(norm);
        const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ d.source_id, norm });
        defer alloc.free(key);
        if (titles.contains(key)) {
            report.near += 1;
        } else {
            try titles.put(try alloc.dupe(u8, key), {});
        }
    }
    return report;
}

/// Historical aggregation: roll the stored documents up into
/// monthly (year_month, topic) counts and record them. Documents
/// with no topics count under "general". Returns rows recorded.
/// Scans up to `limit` documents (call again for larger stores).
pub fn aggregateHistory(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    ks: knowledge.KnowledgeStore,
    limit: usize,
) !usize {
    const docs = try repo.scanDocuments(alloc, null, limit);
    var buckets = std.StringHashMap(usize).init(alloc);
    defer buckets.deinit();
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    for (docs) |d| {
        const ym = try yearMonthOf(alloc, knowledge.docTs(d));
        defer alloc.free(ym);
        const topics = if (d.topics.len > 0) d.topics else &[_][]const u8{"general"};
        for (topics) |t| {
            const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ ym, t });
            const e = try buckets.getOrPut(key);
            if (!e.found_existing) {
                e.value_ptr.* = 0;
                try keys.append(alloc, key);
            } else {
                alloc.free(key);
            }
            e.value_ptr.* += 1;
        }
    }
    var recorded: usize = 0;
    for (keys.items) |key| {
        const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
        try ks.recordMonthlyAggregate(alloc, key[0..sep], key[sep + 1 ..], buckets.get(key).?);
        recorded += 1;
    }
    return recorded;
}

/// One full maintenance pass: aggregate history, report duplicates,
/// enforce retention. Logs each step; returns the combined report.
pub fn runMaintenance(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: repository.Repository,
    ks: ?knowledge.KnowledgeStore,
    policy: RetentionPolicy,
    now: i64,
) !MaintenanceReport {
    var report = MaintenanceReport{};
    if (ks) |k| {
        report.aggregates_recorded = try aggregateHistory(alloc, repo, k, 10000);
        logging.info("maintenance: aggregates recorded", &.{.{ .key = "rows", .value = try std.fmt.allocPrint(alloc, "{d}", .{report.aggregates_recorded}) }});
    }
    const dups = try findDuplicates(alloc, repo, 10000);
    report.duplicates_exact = dups.exact;
    report.duplicates_near = dups.near;
    logging.info("maintenance: duplicates found", &.{
        .{ .key = "exact", .value = try std.fmt.allocPrint(alloc, "{d}", .{dups.exact}) },
        .{ .key = "near", .value = try std.fmt.allocPrint(alloc, "{d}", .{dups.near}) },
    });
    const ret = try enforceRetention(alloc, io, repo, ks, policy, now);
    report.archived = ret.archived;
    report.deleted = ret.deleted;
    report.archive_path = ret.archive_path;
    logging.info("maintenance: retention done", &.{
        .{ .key = "archived", .value = try std.fmt.allocPrint(alloc, "{d}", .{ret.archived}) },
        .{ .key = "deleted", .value = try std.fmt.allocPrint(alloc, "{d}", .{ret.deleted}) },
    });
    return report;
}

test "retention policy defaults are sane" {
    const p = RetentionPolicy{};
    try std.testing.expectEqual(@as(u32, 365), p.docs_retention_days);
    try std.testing.expectEqualStrings("archive", p.archive_dir);
}

test "yearMonthOf formats UTC months" {
    const alloc = std.testing.allocator;
    const ym = try yearMonthOf(alloc, 1794441600); // 2026-11-12 00:00 UTC
    defer alloc.free(ym);
    try std.testing.expectEqualStrings("2026-11", ym);
    const ym2 = try yearMonthOf(alloc, 1767225600); // 2026-01-01
    defer alloc.free(ym2);
    try std.testing.expectEqualStrings("2026-01", ym2);
}

test "maintenance: aggregate + dedup + retention on memory store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var store = @import("memory.zig").MemoryStore.init(alloc);
    defer store.deinit();
    const repo = store.asRepository();
    var mk = knowledge.MemoryKnowledge.init(alloc);
    defer mk.deinit();
    const ks = mk.asKnowledge();
    const now: i64 = 1794441600; // 2026-11-12
    const mkDoc = struct {
        fn doc(a: std.mem.Allocator, id: []const u8, title: []const u8, fetched: i64, hash: []const u8) types.Document {
            return .{
                .id = id,
                .source_id = "new-dawn",
                .source_name = "New Dawn",
                .source_url = "https://thenewdawnliberia.com/",
                .title = title,
                .url = std.fmt.allocPrint(a, "https://example.com/{s}", .{id}) catch unreachable,
                .text = "Body text.",
                .published_at = fetched - 3600,
                .fetched_at = fetched,
                .reliability = 0.70,
                .topics = &.{"energy"},
                .content_hash = hash,
            };
        }
    }.doc;
    // Two fresh docs (same normalized title, different content hash
    // -> one near duplicate), one old doc (400 days -> retention).
    const d1 = mkDoc(alloc, "d1", "Fuel shortage hits Monrovia", now - 3600, "h1");
    const d2 = mkDoc(alloc, "d2", "fuel shortage hits  Monrovia", now - 1800, "h2");
    const d3 = mkDoc(alloc, "d3", "Old budget story", now - 400 * 86400, "h3");
    try repo.insertDocument(d1);
    try repo.insertDocument(d2);
    try repo.insertDocument(d3);
    // Aggregation: all three are energy; d1/d2 in 2026-11, d3 in 2025-10.
    const agg = try aggregateHistory(alloc, repo, ks, 10000);
    try std.testing.expectEqual(@as(usize, 2), agg);
    const rows = try ks.listMonthlyAggregates(alloc, 10);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    // Dedup: 0 exact (hashes differ), 1 near (same normalized title).
    const dups = try findDuplicates(alloc, repo, 10000);
    try std.testing.expectEqual(@as(usize, 0), dups.exact);
    try std.testing.expectEqual(@as(usize, 1), dups.near);
    // Retention with a 365-day policy archives + deletes only d3.
    const tmpdir = "pulse-maintenance-test-archive";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, tmpdir) catch {};
    const ret = try enforceRetention(alloc, io, repo, ks, .{ .docs_retention_days = 365, .archive_dir = tmpdir }, now);
    try std.testing.expectEqual(@as(usize, 1), ret.archived);
    try std.testing.expectEqual(@as(usize, 1), ret.deleted);
    try std.testing.expect(ret.archive_path != null);
    try std.testing.expectEqual(@as(usize, 2), repo.countDocuments());
    // The archive file is a real zstd frame holding the old doc.
    const arc_bytes = blk: {
        const f = try cwd.openFile(io, ret.archive_path.?, .{});
        defer f.close(io);
        var rbuf: [8192]u8 = undefined;
        var reader = f.reader(io, &rbuf);
        break :blk try reader.interface.readAllocShort(alloc, 1 << 20);
    };
    defer alloc.free(arc_bytes);
    try std.testing.expect(compression.isZstd(arc_bytes));
    const plain = try compression.decompressFrame(alloc, arc_bytes);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Old budget story") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Fuel shortage") == null);
    cwd.deleteTree(io, tmpdir) catch {};
}

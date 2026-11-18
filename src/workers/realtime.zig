//! Real-time processing (Roadmap 4.3): Redis Streams event processing
//! for the `pulse:events` stream.
//!
//! The ingestion pipeline publishes one
//! `document.collected` event per document (via the Redis EventBus).
//! The worker consumes them through a consumer group:
//!
//! - `drainOnce` reads NEW entries (XREADGROUP, id ">") and processes
//!   each: the processor runs (default: bump the query-cache epoch so
//!   new documents are visible immediately), then the entry is acked.
//! - `reclaimPending` re-reads UNACKED entries (XREADGROUP, id "0") —
//!   the worker-recovery path after a crash or restart.
//! - A failing entry is left unacked and retried on the next reclaim;
//!   after `max_attempts` failures it is moved to the dead-letter stream
//!   `pulse:events:dlq` and acked, so one poison entry can never stall
//!   the stream. Attempt counts live in short-lived Redis keys
//!   (`pulse:events:attempts:<entry-id>`), deleted on ack.
//! - Unknown event types are acked and counted as skipped, so a future
//!   event kind cannot wedge the consumer.
//!
//! The processor is an interface: the production one bumps the cache
//! epoch (see api/cache.zig); tests pass a recording or failing one.
//! Stream work never fails the worker loop — a Redis outage is logged
//! and retried on the next iteration.

const std = @import("std");
const logging = @import("../common/logging.zig");
const redis = @import("../storage/redis.zig");

pub const stream_name: []const u8 = redis.events_stream;
pub const group_name: []const u8 = "pulse-workers";
pub const dlq_stream: []const u8 = "pulse:events:dlq";
pub const default_max_attempts: usize = 3;
pub const default_batch: usize = 10;
pub const default_block_ms: u64 = 200;

/// What the consumer does for one collected document. Returning an
/// error means "could not process": the entry is left for retry.
pub const Processor = struct {
    ptr: *anyopaque,
    processCollected: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void,
};

pub const DrainReport = struct {
    read: usize = 0,
    processed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    dead_lettered: usize = 0,
};

pub const StreamConsumer = struct {
    client: *redis.RedisClient,
    stream: []const u8 = stream_name,
    group: []const u8 = group_name,
    consumer: []const u8,
    max_attempts: usize = default_max_attempts,
    dlq: []const u8 = dlq_stream,

    pub fn ensureGroup(self: *StreamConsumer) !void {
        try self.client.xgroupCreate(self.stream, self.group);
    }

    /// Read new entries (BLOCK `block_ms`) and process each one.
    pub fn drainOnce(self: *StreamConsumer, alloc: std.mem.Allocator, processor: Processor) !DrainReport {
        const entries = try self.client.xreadgroup(alloc, self.group, self.consumer, self.stream, default_batch, default_block_ms);
        return self.processEntries(alloc, entries, processor);
    }

    /// Re-read unacked entries (worker recovery) and process each one.
    pub fn reclaimPending(self: *StreamConsumer, alloc: std.mem.Allocator, processor: Processor) !DrainReport {
        const entries = try self.client.xreadPending(alloc, self.group, self.consumer, self.stream, default_batch);
        return self.processEntries(alloc, entries, processor);
    }

    /// How many entries are still unacked in the group.
    pub fn pendingCount(self: *StreamConsumer, alloc: std.mem.Allocator) !i64 {
        return self.client.xpendingCount(alloc, self.stream, self.group);
    }

    fn processEntries(self: *StreamConsumer, alloc: std.mem.Allocator, entries: []redis.StreamEntry, processor: Processor) !DrainReport {
        var report = DrainReport{};
        for (entries) |entry| {
            report.read += 1;
            const kind = fieldValue(entry, "type");
            if (kind == null or !std.mem.eql(u8, kind.?, "document.collected")) {
                // Unknown kind: ack so it never blocks the stream.
                _ = self.client.xack(alloc, self.stream, self.group, &.{entry.id}) catch {};
                report.skipped += 1;
                continue;
            }
            const doc_id = fieldValue(entry, "document_id") orelse "";
            const source_id = fieldValue(entry, "source_id") orelse "";
            processor.processCollected(processor.ptr, alloc, doc_id, source_id) catch |e| {
                logging.warn("stream entry failed, leaving for retry", &.{
                    .{ .key = "entry", .value = entry.id },
                    .{ .key = "error", .value = @errorName(e) },
                });
                report.failed += 1;
                const attempts = self.recordAttempt(alloc, entry.id) catch 0;
                if (attempts >= self.max_attempts) {
                    self.deadLetter(alloc, entry) catch {};
                    _ = self.client.xack(alloc, self.stream, self.group, &.{entry.id}) catch {};
                    _ = self.client.del(alloc, &.{try attemptsKey(alloc, entry.id)}) catch {};
                    report.dead_lettered += 1;
                }
                continue;
            };
            _ = self.client.xack(alloc, self.stream, self.group, &.{entry.id}) catch {};
            _ = self.client.del(alloc, &.{try attemptsKey(alloc, entry.id)}) catch {};
            report.processed += 1;
        }
        return report;
    }

    /// INCR the attempt counter for an entry; returns the new count
    /// (0 when Redis is unreachable — the entry stays pending either way).
    fn recordAttempt(self: *StreamConsumer, alloc: std.mem.Allocator, entry_id: []const u8) !usize {
        const key = try attemptsKey(alloc, entry_id);
        const n = try self.client.incr(alloc, key);
        _ = self.client.expire(alloc, key, 86400) catch {};
        return @intCast(n);
    }

    /// Copy a failed entry to the dead-letter stream with its failure
    /// count, so the poison entry is inspectable after the ack.
    fn deadLetter(self: *StreamConsumer, alloc: std.mem.Allocator, entry: redis.StreamEntry) !void {
        var fields: std.ArrayList(redis.Field) = .empty;
        defer fields.deinit(alloc);
        for (entry.fields) |f| try fields.append(alloc, f);
        const attempts = try std.fmt.allocPrint(alloc, "{d}", .{self.max_attempts});
        try fields.append(alloc, .{ .name = "attempts", .value = attempts });
        try fields.append(alloc, .{ .name = "dead_letter_reason", .value = "max_attempts_exceeded" });
        _ = try self.client.xadd(alloc, self.dlq, fields.items);
    }
};

/// Attempts key for one stream entry id.
pub fn attemptsKey(alloc: std.mem.Allocator, entry_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "pulse:events:attempts:{s}", .{entry_id});
}

/// One field of a stream entry by name, or null when absent.
pub fn fieldValue(entry: redis.StreamEntry, name: []const u8) ?[]const u8 {
    for (entry.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A processor that records every call (test double).
const RecordingProcessor = struct {
    calls: std.ArrayList([2][]const u8),
    /// When set, calls at or after this index fail.
    fail_after: ?usize = null,

    fn processor(self: *RecordingProcessor) Processor {
        return .{ .ptr = self, .processCollected = process };
    }

    fn process(ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void {
        const self: *RecordingProcessor = @ptrCast(@alignCast(ptr));
        if (self.fail_after) |n| {
            if (self.calls.items.len >= n) return error.ProcessorFailed;
        }
        const pair = [2][]const u8{ try alloc.dupe(u8, doc_id), try alloc.dupe(u8, source_id) };
        try self.calls.append(alloc, pair);
    }
};

test "fieldValue finds fields by name" {
    const entry = redis.StreamEntry{
        .id = "1-0",
        .fields = @constCast(&[_]redis.Field{
            .{ .name = "type", .value = "document.collected" },
            .{ .name = "document_id", .value = "doc-1" },
        }),
    };
    try testing.expectEqualStrings("document.collected", fieldValue(entry, "type").?);
    try testing.expectEqualStrings("doc-1", fieldValue(entry, "document_id").?);
    try testing.expect(fieldValue(entry, "source_id") == null);
}

test "attemptsKey names the entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "pulse:events:attempts:1795000000000-0",
        try attemptsKey(arena.allocator(), "1795000000000-0"),
    );
}

test "live stream drain/ack/retry/dead-letter (gated on PULSE_TEST_REDIS_URL)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const url = (try redis.testRedisUrl(io, alloc)) orelse {
        std.debug.print("skip: PULSE_TEST_REDIS_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var client = redis.RedisClient.connect(a, io, url) catch |err| {
        std.debug.print("live stream test: connect failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.close();

    // Scratch stream + group + DLQ so the test never touches the real
    // pulse:events stream; the consumer is pointed at them directly.
    const suffix = redis.unixMillis(io);
    const stream = try std.fmt.allocPrint(alloc, "pulse:test:stream:{d}", .{suffix});
    defer alloc.free(stream);
    const dlq = try std.fmt.allocPrint(alloc, "pulse:test:dlq:{d}", .{suffix});
    defer alloc.free(dlq);

    var rec = RecordingProcessor{ .calls = .empty };
    var consumer = StreamConsumer{
        .client = &client,
        .stream = stream,
        .group = "test-workers",
        .consumer = "c1",
        .max_attempts = 2,
        .dlq = dlq,
    };
    try consumer.ensureGroup();

    const fields = [_]redis.Field{
        .{ .name = "type", .value = "document.collected" },
        .{ .name = "document_id", .value = "doc-a" },
        .{ .name = "source_id", .value = "src-a" },
        .{ .name = "ts", .value = "1795000000000" },
    };
    // Two good entries: drain delivers both, processor sees both, both ack.
    _ = try client.xadd(a, stream, &fields);
    _ = try client.xadd(a, stream, &fields);
    const r1 = try consumer.drainOnce(a, rec.processor());
    try testing.expectEqual(@as(usize, 2), r1.read);
    try testing.expectEqual(@as(usize, 2), r1.processed);
    try testing.expectEqual(@as(usize, 2), rec.calls.items.len);
    try testing.expectEqual(@as(i64, 0), try consumer.pendingCount(a));

    // One entry with a failing processor: drain leaves it pending.
    var failing = RecordingProcessor{ .calls = .empty, .fail_after = 0 };
    _ = try client.xadd(a, stream, &fields);
    const r2 = try consumer.drainOnce(a, failing.processor());
    try testing.expectEqual(@as(usize, 1), r2.read);
    try testing.expectEqual(@as(usize, 1), r2.failed);
    try testing.expectEqual(@as(usize, 0), r2.dead_lettered);
    try testing.expectEqual(@as(i64, 1), try consumer.pendingCount(a));
    // Recovery: reclaim re-reads it and fails again -> dead-lettered.
    const r3 = try consumer.reclaimPending(a, failing.processor());
    try testing.expectEqual(@as(usize, 1), r3.read);
    try testing.expectEqual(@as(usize, 1), r3.dead_lettered);
    try testing.expectEqual(@as(i64, 0), try consumer.pendingCount(a));
    // The poison entry is inspectable in the DLQ.
    const dlq_entries = try client.xrange(a, dlq, 10);
    try testing.expectEqual(@as(usize, 1), dlq_entries.len);
    try testing.expectEqualStrings("max_attempts_exceeded", fieldValue(dlq_entries[0], "dead_letter_reason").?);

    // Unknown event kinds are acked and skipped, never retried.
    const weird = [_]redis.Field{
        .{ .name = "type", .value = "something.else" },
        .{ .name = "document_id", .value = "doc-z" },
    };
    _ = try client.xadd(a, stream, &weird);
    const r4 = try consumer.drainOnce(a, rec.processor());
    try testing.expectEqual(@as(usize, 1), r4.read);
    try testing.expectEqual(@as(usize, 1), r4.skipped);
    try testing.expectEqual(@as(i64, 0), try consumer.pendingCount(a));
}

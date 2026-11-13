//! Query result cache (Roadmap 4.5) over Redis, with epoch-based
//! invalidation (Roadmap 4.3).
//!
//! A cached /v1/query response is stored under
//! `pulse:cache:q:<sha256(query|limit)>` as "<epoch>\n<json>" with a TTL.
//! Invalidation never scans or deletes keys: ingesting a document bumps
//! the single epoch counter (`pulse:cache:epoch`), which makes every
//! cached entry stale at once. A read only trusts an entry whose stored
//! epoch matches the current one. The cost of an ingest is one INCR;
//! the cost of a stale entry is one recomputed query.
//!
//! All functions are best-effort by design: any Redis error means
//! "no cache" and the caller recomputes. The cache never fails a query.

const std = @import("std");
const redis = @import("../storage/redis.zig");
const realtime = @import("../workers/realtime.zig");

pub const epoch_key: []const u8 = "pulse:cache:epoch";
pub const key_prefix: []const u8 = "pulse:cache:q:";
pub const default_ttl_s: u64 = 300;
/// Responses larger than this are served but never stored: a cached
/// giant is a memory sink, and the next query recomputes cheaply
/// enough at this scale.
pub const max_response_bytes: usize = 64 * 1024;

/// Splice the current request id into a cached response body. The
/// stored body is rendered with an empty request id, so the marker
/// `"request_id":""` is unique and fixed-length; the replacement is a
/// plain concatenation. Returns error when the marker is absent (the
/// caller then recomputes instead of serving a stale id).
pub fn stampRequestId(alloc: std.mem.Allocator, stored_json: []const u8, req_id: []const u8) ![]u8 {
    const marker = "\"request_id\":\"\"";
    const repl = try std.fmt.allocPrint(alloc, "\"request_id\":\"{s}\"", .{req_id});
    defer alloc.free(repl);
    return splice(alloc, stored_json, marker, repl);
}

fn splice(alloc: std.mem.Allocator, json: []const u8, marker: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, json, marker) orelse return error.MarkerMissing;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, json[0..at]);
    try out.appendSlice(alloc, replacement);
    try out.appendSlice(alloc, json[at + marker.len ..]);
    return out.toOwnedSlice(alloc);
}

/// Stamp the serving path, measured latency, and routing reason into a
/// cached response body (Roadmap 6.1). The stored body is rendered with
/// `"path":""`, `"latency_ms":0`, and `"routing_reason":""`, so a hit
/// reports the path that SERVED it (instant), not the path that first
/// computed it. Returns error when any marker is absent.
pub fn stampServed(alloc: std.mem.Allocator, stored_json: []const u8, req_id: []const u8, path: []const u8, latency_ms: f64, reason: []const u8) ![]u8 {
    const stamped_id = try stampRequestId(alloc, stored_json, req_id);
    defer alloc.free(stamped_id);
    const path_repl = try std.fmt.allocPrint(alloc, "\"path\":\"{s}\"", .{path});
    defer alloc.free(path_repl);
    const stamped_path = try splice(alloc, stamped_id, "\"path\":\"\"", path_repl);
    defer alloc.free(stamped_path);
    const lat_repl = try std.fmt.allocPrint(alloc, "\"latency_ms\":{d:.6}", .{latency_ms});
    defer alloc.free(lat_repl);
    const stamped_lat = try splice(alloc, stamped_path, "\"latency_ms\":0", lat_repl);
    defer alloc.free(stamped_lat);
    const reason_repl = try std.fmt.allocPrint(alloc, "\"routing_reason\":\"{s}\"", .{reason});
    defer alloc.free(reason_repl);
    return splice(alloc, stamped_lat, "\"routing_reason\":\"\"", reason_repl);
}

/// Bump the cache epoch (call on every document ingest). Returns the
/// new epoch. Best-effort: callers ignore errors.
pub fn bumpEpoch(client: *redis.RedisClient, alloc: std.mem.Allocator) !i64 {
    return client.incr(alloc, epoch_key);
}

/// Current epoch, or 0 when Redis has no epoch yet (or on error).
pub fn currentEpoch(client: *redis.RedisClient, alloc: std.mem.Allocator) i64 {
    const raw = client.get(alloc, epoch_key) catch return 0;
    const s = raw orelse return 0;
    return std.fmt.parseInt(i64, s, 10) catch 0;
}

/// Cache key for a query + result limit: SHA-256 hex of "query|limit".
pub fn cacheKey(alloc: std.mem.Allocator, query: []const u8, limit: usize) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(query);
    hasher.update("|");
    var limit_buf: [32]u8 = undefined;
    const limit_s = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    hasher.update(limit_s);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ key_prefix, hex });
}

/// Store a response under `key` with the current epoch and a TTL.
/// Best-effort: errors are swallowed by the caller.
pub fn put(client: *redis.RedisClient, alloc: std.mem.Allocator, key: []const u8, epoch: i64, response_json: []const u8, ttl_s: u64) !void {
    const value = try std.fmt.allocPrint(alloc, "{d}\n{s}", .{ epoch, response_json });
    try client.setex(key, ttl_s, value);
}

/// Fetch a cached response, or null when missing, stale (epoch moved),
/// or malformed. The returned JSON is owned by `alloc`.
pub fn get(client: *redis.RedisClient, alloc: std.mem.Allocator, key: []const u8, epoch: i64) !?[]u8 {
    const raw = (try client.get(alloc, key)) orelse return null;
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const stored_epoch = std.fmt.parseInt(i64, raw[0..nl], 10) catch return null;
    if (stored_epoch != epoch) return null;
    const duped = try alloc.dupe(u8, raw[nl + 1 ..]);
    return duped;
}

test "cacheKey is stable per query+limit and differs across inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = try cacheKey(alloc, "fuel shortage", 10);
    const b = try cacheKey(alloc, "fuel shortage", 10);
    const c = try cacheKey(alloc, "fuel shortage", 5);
    const d = try cacheKey(alloc, "fuel prices", 10);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expect(!std.mem.eql(u8, a, d));
    try std.testing.expect(std.mem.startsWith(u8, a, key_prefix));
    try std.testing.expectEqual(@as(usize, key_prefix.len + 64), a.len);
}

test "stampServed stamps id, path, latency and reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stored = "{\"query\":\"fuel\",\"path\":\"\",\"latency_ms\":0,\"routing_reason\":\"\",\"meta\":{\"request_id\":\"\"}}";
    const stamped = try stampServed(alloc, stored, "req-abc", "instant", 0.123456, "l1_hit");
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"request_id\":\"req-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"path\":\"instant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"latency_ms\":0.123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "\"routing_reason\":\"l1_hit\"") != null);
    // A body without the markers fails loudly instead of serving a lie.
    try std.testing.expectError(error.MarkerMissing, stampServed(alloc, "{\"meta\":{}}", "x", "fast", 1, "y"));
}

test "stampRequestId splices the current id into the empty marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const stored = "{\"meta\":{\"request_id\":\"\",\"results_count\":2}}";
    const stamped = try stampRequestId(alloc, stored, "req-abc123");
    try std.testing.expectEqualStrings("{\"meta\":{\"request_id\":\"req-abc123\",\"results_count\":2}}", stamped);
    try std.testing.expectError(error.MarkerMissing, stampRequestId(alloc, "{\"meta\":{}}", "x"));
}

test "stampRequestId leaves a body without the marker untouched (error, not silent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A body that already carries a real id must never be served as a
    // cache entry: the marker is only the empty string.
    try std.testing.expectError(error.MarkerMissing, stampRequestId(alloc, "{\"meta\":{\"request_id\":\"old\"}}", "new"));
}

test "epoch parsing: stored epoch must match" {
    // The stored format is "<epoch>\n<json>"; matching is exact.
    const raw = "42\n{\"ok\":true}";
    const nl = std.mem.indexOfScalar(u8, raw, '\n').?;
    try std.testing.expectEqual(@as(i64, 42), try std.fmt.parseInt(i64, raw[0..nl], 10));
    try std.testing.expectEqualStrings("{\"ok\":true}", raw[nl + 1 ..]);
    // A non-numeric epoch is malformed and must never validate.
    const bad = "xx\n{}";
    const nl2 = std.mem.indexOfScalar(u8, bad, '\n').?;
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(i64, bad[0..nl2], 10));
}

/// Processor for the real-time stream consumer (Roadmap 4.3): every
/// collected document bumps the cache epoch, so the next /v1/query
/// recomputes instead of serving a stale cached answer. A Redis error
/// here fails the entry (it is retried / dead-lettered by the consumer),
/// which is correct: an un-invalidated cache is worse than a retry.
pub const EpochInvalidator = struct {
    client: *redis.RedisClient,

    pub fn processor(self: *EpochInvalidator) realtime.Processor {
        return .{ .ptr = self, .processCollected = process };
    }

    fn process(ptr: *anyopaque, alloc: std.mem.Allocator, doc_id: []const u8, source_id: []const u8) anyerror!void {
        const self: *EpochInvalidator = @ptrCast(@alignCast(ptr));
        _ = doc_id;
        _ = source_id;
        _ = try bumpEpoch(self.client, alloc);
    }
};

//! L1 in-process memory cache (Roadmap 6.2).
//!
//! Bounded by count AND bytes, with least-recently-used eviction and a
//! per-entry TTL. Keys MUST be consumer-scoped: callers build keys as
//! "consumer|<kind>|<params>" so a cached response can never leak across
//! consumers or auth contexts. Entries carry tags (topics, counties,
//! entity names) so ingest can invalidate only the affected entries
//! instead of flushing the whole cache.
//!
//! Single-threaded server: no locking. If the server ever goes
//! multi-threaded, this cache needs a mutex first (documented in
//! docs/PERFORMANCE.md). All time is injected as milliseconds so the
//! eviction/TTL logic is unit-testable without a clock.
//!
//! Eviction is a linear scan for the least-recently-used entry; the
//! default cap is 512 entries, so the scan is negligible. Entries are
//! heap-allocated and owned by the cache; `get` returns a borrowed
//! slice that is valid until the next mutation of the cache.

const std = @import("std");

pub const default_max_entries: usize = 512;
/// 8 MiB of cached JSON by default.
pub const default_max_bytes: usize = 8 * 1024 * 1024;
pub const default_ttl_s: u64 = 300;

pub const Entry = struct {
    key: []u8,
    value: []u8,
    tags: [][]u8,
    stored_at_ms: i64,
    last_access_ms: i64,
    bytes: usize,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    inserts: u64 = 0,
    entries: usize = 0,
    bytes: usize = 0,
};

pub const L1Cache = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap(*Entry),
    max_entries: usize,
    max_bytes: usize,
    ttl_s: u64,
    stats: Stats = .{},

    pub fn init(alloc: std.mem.Allocator, max_entries: usize, max_bytes: usize, ttl_s: u64) L1Cache {
        return .{
            .alloc = alloc,
            .map = std.StringHashMap(*Entry).init(alloc),
            .max_entries = @max(1, max_entries),
            .max_bytes = @max(1, max_bytes),
            .ttl_s = ttl_s,
        };
    }

    pub fn deinit(self: *L1Cache) void {
        var it = self.map.valueIterator();
        while (it.next()) |e| self.freeEntry(e.*);
        self.map.deinit();
    }

    fn freeEntry(self: *L1Cache, e: *Entry) void {
        self.alloc.free(e.key);
        self.alloc.free(e.value);
        for (e.tags) |t| self.alloc.free(t);
        self.alloc.free(e.tags);
        self.alloc.destroy(e);
    }

    fn entryBytes(key: []const u8, value: []const u8, tags: []const []const u8) usize {
        var n = key.len + value.len;
        for (tags) |t| n += t.len;
        return n;
    }

    fn expired(self: *const L1Cache, e: *const Entry, now_ms: i64) bool {
        if (self.ttl_s == 0) return false;
        return now_ms - e.stored_at_ms > @as(i64, @intCast(self.ttl_s)) * 1000;
    }

    /// Look up a key. Returns a borrowed slice (valid until the next
    /// mutation) or null on miss/expired. Expired entries are removed.
    pub fn get(self: *L1Cache, key: []const u8, now_ms: i64) ?[]const u8 {
        const e = self.map.get(key) orelse {
            self.stats.misses += 1;
            return null;
        };
        if (self.expired(e, now_ms)) {
            _ = self.map.remove(key);
            self.stats.bytes -= e.bytes;
            self.freeEntry(e);
            self.stats.misses += 1;
            return null;
        }
        e.last_access_ms = now_ms;
        self.stats.hits += 1;
        return e.value;
    }

    /// Insert or replace an entry. Evicts least-recently-used entries
    /// until both caps hold. A single value larger than the byte cap is
    /// refused (never stored) rather than evicting the whole cache.
    pub fn put(self: *L1Cache, key: []const u8, value: []const u8, tags: []const []const u8, now_ms: i64) !void {
        const bytes = entryBytes(key, value, tags);
        if (bytes > self.max_bytes) return;
        // Replace in place when the key already exists. The new value
        // and tags are built first so a failed allocation leaves the
        // old entry untouched.
        if (self.map.get(key)) |old| {
            const new_value = try self.alloc.dupe(u8, value);
            errdefer self.alloc.free(new_value);
            var new_tags: std.ArrayList([]u8) = .empty;
            errdefer {
                for (new_tags.items) |t| self.alloc.free(t);
                new_tags.deinit(self.alloc);
            }
            for (tags) |t| try new_tags.append(self.alloc, try self.alloc.dupe(u8, t));
            const owned_tags = try new_tags.toOwnedSlice(self.alloc);
            self.stats.bytes -= old.bytes;
            self.alloc.free(old.value);
            for (old.tags) |t| self.alloc.free(t);
            self.alloc.free(old.tags);
            old.value = new_value;
            old.tags = owned_tags;
            old.stored_at_ms = now_ms;
            old.last_access_ms = now_ms;
            old.bytes = bytes;
            self.stats.bytes += bytes;
            self.stats.inserts += 1;
            return;
        }
        // Evict LRU entries until both caps hold for the new entry.
        while ((self.map.count() >= self.max_entries or self.stats.bytes + bytes > self.max_bytes) and self.map.count() > 0) {
            self.evictLru();
        }
        const e = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(e);
        var owned_tags: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned_tags.items) |t| self.alloc.free(t);
            owned_tags.deinit(self.alloc);
        }
        for (tags) |t| try owned_tags.append(self.alloc, try self.alloc.dupe(u8, t));
        e.* = .{
            .key = try self.alloc.dupe(u8, key),
            .value = try self.alloc.dupe(u8, value),
            .tags = try owned_tags.toOwnedSlice(self.alloc),
            .stored_at_ms = now_ms,
            .last_access_ms = now_ms,
            .bytes = bytes,
        };
        try self.map.put(e.key, e);
        self.stats.bytes += bytes;
        self.stats.inserts += 1;
    }

    fn evictLru(self: *L1Cache) void {
        var victim_key: ?[]const u8 = null;
        var victim_access: i64 = std.math.maxInt(i64);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.last_access_ms < victim_access) {
                victim_access = kv.value_ptr.*.last_access_ms;
                victim_key = kv.key_ptr.*;
            }
        }
        const k = victim_key orelse return;
        const e = self.map.get(k).?;
        _ = self.map.remove(k);
        self.stats.bytes -= e.bytes;
        self.stats.evictions += 1;
        self.freeEntry(e);
    }

    /// Invalidate every entry carrying any of the given tags. Returns
    /// how many entries were removed. Used on ingest so only affected
    /// queries recompute — never a blind full flush.
    pub fn invalidateTags(self: *L1Cache, tags: []const []const u8) usize {
        var removed: usize = 0;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.alloc);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            for (e.tags) |et| {
                for (tags) |t| {
                    if (std.mem.eql(u8, et, t)) {
                        keys.append(self.alloc, kv.key_ptr.*) catch break;
                        break;
                    }
                } else continue;
                break;
            }
        }
        for (keys.items) |k| {
            const e = self.map.get(k) orelse continue;
            _ = self.map.remove(k);
            self.stats.bytes -= e.bytes;
            self.freeEntry(e);
            removed += 1;
        }
        return removed;
    }

    pub fn invalidateAll(self: *L1Cache) usize {
        const n = self.map.count();
        var it = self.map.valueIterator();
        while (it.next()) |e| self.freeEntry(e.*);
        self.map.clearRetainingCapacity();
        self.stats.bytes = 0;
        return n;
    }

    pub fn snapshot(self: *const L1Cache) Stats {
        var s = self.stats;
        s.entries = self.map.count();
        s.bytes = self.stats.bytes;
        return s;
    }

    /// Consumer-scoped cache key for a query: "q|<consumer>|<sha256>".
    /// The hash input matches the L2 (Redis) key format so the two
    /// layers stay consistent.
    pub fn queryKey(alloc: std.mem.Allocator, consumer: []const u8, query: []const u8, limit: usize) ![]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(query);
        hasher.update("|");
        var limit_buf: [32]u8 = undefined;
        const limit_s = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        hasher.update(limit_s);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(alloc, "q|{s}|{s}", .{ consumer, hex });
    }

    /// Consumer-scoped cache key for a named payload (trends, briefing,
    /// locations, statistics): "p|<consumer>|<kind>|<params>".
    pub fn payloadKey(alloc: std.mem.Allocator, consumer: []const u8, kind: []const u8, params: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "p|{s}|{s}|{s}", .{ consumer, kind, params });
    }
};

test "l1 put/get round-trips and tracks stats" {
    var c = L1Cache.init(std.testing.allocator, 4, 1024, 300);
    defer c.deinit();
    try c.put("a", "{\"ok\":1}", &.{ "politics", "Monrovia" }, 1000);
    const v = c.get("a", 2000);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("{\"ok\":1}", v.?);
    try std.testing.expect(c.get("missing", 2000) == null);
    const s = c.snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(usize, 1), s.entries);
}

test "l1 ttl expiry removes the entry" {
    var c = L1Cache.init(std.testing.allocator, 4, 1024, 1);
    defer c.deinit();
    try c.put("a", "v", &.{}, 0);
    try std.testing.expect(c.get("a", 999) != null);
    try std.testing.expect(c.get("a", 1001) == null);
    try std.testing.expectEqual(@as(usize, 0), c.snapshot().entries);
}

test "l1 evicts least-recently-used when the count cap is hit" {
    var c = L1Cache.init(std.testing.allocator, 2, 1024 * 1024, 300);
    defer c.deinit();
    try c.put("a", "1", &.{}, 1000);
    try c.put("b", "2", &.{}, 1000);
    _ = c.get("a", 2000); // a is now newer than b
    try c.put("c", "3", &.{}, 3000);
    try std.testing.expect(c.get("b", 3001) == null); // b evicted
    try std.testing.expect(c.get("a", 3001) != null);
    try std.testing.expect(c.get("c", 3001) != null);
    try std.testing.expectEqual(@as(u64, 1), c.snapshot().evictions);
}

test "l1 refuses a single value larger than the byte cap" {
    var c = L1Cache.init(std.testing.allocator, 4, 16, 300);
    defer c.deinit();
    try c.put("big", "0123456789abcdef0123456789", &.{}, 0);
    try std.testing.expectEqual(@as(usize, 0), c.snapshot().entries);
    try c.put("small", "ok", &.{}, 0);
    try std.testing.expectEqual(@as(usize, 1), c.snapshot().entries);
}

test "l1 invalidateTags removes only matching entries" {
    var c = L1Cache.init(std.testing.allocator, 8, 1024 * 1024, 300);
    defer c.deinit();
    try c.put("a", "1", &.{ "politics", "Monrovia" }, 0);
    try c.put("b", "2", &.{ "sports" }, 0);
    try c.put("c", "3", &.{ "politics", "Gbarnga" }, 0);
    const n = c.invalidateTags(&.{ "politics", "Lofa" });
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(c.get("a", 10) == null);
    try std.testing.expect(c.get("b", 10) != null);
    try std.testing.expect(c.get("c", 10) == null);
}

test "l1 replace updates the value and resets the ttl" {
    var c = L1Cache.init(std.testing.allocator, 4, 1024, 1);
    defer c.deinit();
    try c.put("a", "old", &.{}, 0);
    try c.put("a", "new", &.{ "t" }, 500);
    try std.testing.expectEqualStrings("new", c.get("a", 1400).?);
    try std.testing.expectEqual(@as(usize, 1), c.snapshot().entries);
}

test "l1 queryKey is consumer-scoped and stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = try L1Cache.queryKey(alloc, "sando", "fuel", 10);
    const b = try L1Cache.queryKey(alloc, "sando", "fuel", 10);
    const c = try L1Cache.queryKey(alloc, "other", "fuel", 10);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expect(std.mem.startsWith(u8, a, "q|sando|"));
}

test "l1 invalidateAll flushes everything" {
    var c = L1Cache.init(std.testing.allocator, 4, 1024, 300);
    defer c.deinit();
    try c.put("a", "1", &.{}, 0);
    try c.put("b", "2", &.{}, 0);
    try std.testing.expectEqual(@as(usize, 2), c.invalidateAll());
    try std.testing.expectEqual(@as(usize, 0), c.snapshot().entries);
    try std.testing.expectEqual(@as(usize, 0), c.snapshot().bytes);
}

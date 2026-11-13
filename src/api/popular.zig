//! Popular searches (Roadmap 6.4).
//!
//! Tracks which queries users ask most, so the server knows what to
//! precompute and warm at startup. Only the query TEXT and a count are
//! stored — never the consumer, never any identity. The list is kept
//! in memory, bounded by a distinct-query cap (the lowest-count entry
//! is evicted when full), and persisted best-effort to a JSON file so
//! it survives restarts (loaded at boot, saved every N records).
//!
//! Single-threaded by design: the server is a single accept loop, so
//! no locking. If the server ever goes multi-threaded this module
//! needs a mutex like PgPool's.

const std = @import("std");

/// JSON-escape one string (with quotes), the way stringifyAlloc does
/// in intelligence/precomputed.zig.
fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(s, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

/// One tracked query and how many times it was asked.
pub const ScoredQuery = struct {
    query: []const u8,
    count: u64,
};

pub const PopularSearches = struct {
    counts: std.StringHashMap(u64),
    max_tracked: usize,
    /// Records since the last save; the caller persists when this
    /// reaches the configured interval.
    records_since_save: usize = 0,

    pub fn init(alloc: std.mem.Allocator, max_tracked: usize) PopularSearches {
        return .{
            .counts = std.StringHashMap(u64).init(alloc),
            .max_tracked = @max(1, max_tracked),
        };
    }

    pub fn deinit(self: *PopularSearches) void {
        var it = self.counts.keyIterator();
        while (it.next()) |k| self.counts.allocator.free(k.*);
        self.counts.deinit();
    }

    /// Normalise a query for counting: trim, lowercase, collapse
    /// internal whitespace runs to one space. Returns an owned slice.
    pub fn normalize(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var in_space = true;
        for (trimmed) |c| {
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (!in_space) try out.append(alloc, ' ');
                in_space = true;
            } else {
                try out.append(alloc, std.ascii.toLower(c));
                in_space = false;
            }
        }
        // Drop a trailing space left by a collapsed run at the end.
        if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
        return out.toOwnedSlice(alloc);
    }

    /// Record one asked query. The normalised key is kept in the
    /// map, so it is allocated with the map's own allocator — never
    /// a caller-passed one. (A caller-passed allocator caused a
    /// cross-allocator free: keys allocated by the process arena
    /// were freed by the map's allocator on eviction, aborting the
    /// server with `munmap_chunk(): invalid pointer` once tracking
    /// passed 1000 queries.) Empty and over-long (>200 chars)
    /// queries are not tracked.
    pub fn record(self: *PopularSearches, query: []const u8) !void {
        const alloc = self.counts.allocator;
        const norm = try normalize(alloc, query);
        if (norm.len == 0 or norm.len > 200) {
            alloc.free(norm);
            return;
        }
        const gop = try self.counts.getOrPut(norm);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
            alloc.free(norm);
        } else {
            gop.value_ptr.* = 1;
        }
        self.records_since_save += 1;
        if (self.counts.count() > self.max_tracked) self.evictLowest();
    }

    fn evictLowest(self: *PopularSearches) void {
        var worst_key: ?[]const u8 = null;
        var worst_count: u64 = std.math.maxInt(u64);
        var it = self.counts.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < worst_count) {
                worst_count = e.value_ptr.*;
                worst_key = e.key_ptr.*;
            }
        }
        if (worst_key) |k| {
            _ = self.counts.remove(k);
            self.counts.allocator.free(k);
        }
    }

    /// The `n` most-asked queries, most-asked first (ties broken
    /// alphabetically so the order is deterministic). The returned
    /// slice is backed by `alloc`; the query strings borrow the map
    /// keys and are valid while this PopularSearches lives.
    pub fn top(self: *PopularSearches, alloc: std.mem.Allocator, n: usize) ![]ScoredQuery {
        var list: std.ArrayList(ScoredQuery) = .empty;
        var it = self.counts.iterator();
        while (it.next()) |e| try list.append(alloc, .{ .query = e.key_ptr.*, .count = e.value_ptr.* });
        std.mem.sort(ScoredQuery, list.items, {}, struct {
            fn less(_: void, a: ScoredQuery, b: ScoredQuery) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.query, b.query);
            }
        }.less);
        return list.items[0..@min(n, list.items.len)];
    }

    pub fn tracked(self: *const PopularSearches) usize {
        return self.counts.count();
    }

    /// Persist the counts as a JSON array of {query, count} objects.
    /// Best-effort: the caller logs and ignores errors.
    pub fn save(self: *const PopularSearches, io: std.Io, path: []const u8) !void {
        var cwd = std.Io.Dir.cwd();
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.counts.allocator);
        var it = self.counts.iterator();
        try buf.appendSlice(self.counts.allocator, "[");
        var first = true;
        while (it.next()) |e| {
            if (!first) try buf.appendSlice(self.counts.allocator, ",");
            first = false;
            const esc = try jsonEscape(self.counts.allocator, e.key_ptr.*);
            defer self.counts.allocator.free(esc);
            const row = try std.fmt.allocPrint(self.counts.allocator, "{{\"query\":{s},\"count\":{d}}}", .{ esc, e.value_ptr.* });
            defer self.counts.allocator.free(row);
            try buf.appendSlice(self.counts.allocator, row);
        }
        try buf.appendSlice(self.counts.allocator, "]");
        var wbuf: [8192]u8 = undefined;
        var w = file.writer(io, &wbuf);
        try w.interface.writeAll(buf.items);
        try w.interface.flush();
    }

    /// Load a persisted file. A missing or malformed file returns an
    /// empty tracker (never an error) — the counts are advisory, not
    /// authoritative, and a corrupt file must not stop the boot.
    pub fn load(alloc: std.mem.Allocator, io: std.Io, path: []const u8, max_tracked: usize) PopularSearches {
        var p = PopularSearches.init(alloc, max_tracked);
        var cwd = std.Io.Dir.cwd();
        const data = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return p;
        defer alloc.free(data);
        const Row = struct { query: []const u8, count: u64 };
        const parsed = std.json.parseFromSlice([]Row, alloc, data, .{}) catch return p;
        defer parsed.deinit();
        for (parsed.value) |row| {
            const k = alloc.dupe(u8, row.query) catch continue;
            p.counts.put(k, row.count) catch {
                alloc.free(k);
                continue;
            };
        }
        return p;
    }
};

test "popular normalize trims, lowercases, collapses whitespace" {
    const alloc = std.testing.allocator;
    const n = try PopularSearches.normalize(alloc, "  Fuel   SHORTAGE in\tMonrovia\n");
    defer alloc.free(n);
    try std.testing.expectEqualStrings("fuel shortage in monrovia", n);
}

test "popular record counts and top orders most-asked first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = PopularSearches.init(alloc, 100);
    defer p.deinit();
    try p.record("Fuel shortage");
    try p.record("fuel  shortage");
    try p.record("FUEL SHORTAGE");
    try p.record("elections");
    try p.record("  ");
    try p.record("");
    const top_list = try p.top(alloc, 10);
    try std.testing.expectEqual(@as(usize, 2), top_list.len);
    try std.testing.expectEqualStrings("fuel shortage", top_list[0].query);
    try std.testing.expectEqual(@as(u64, 3), top_list[0].count);
    try std.testing.expectEqualStrings("elections", top_list[1].query);
    try std.testing.expectEqual(@as(usize, 2), p.tracked());
}

test "popular evicts the lowest-count entry past the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = PopularSearches.init(alloc, 2);
    defer p.deinit();
    try p.record("a");
    try p.record("a");
    try p.record("b");
    try p.record("c");
    try std.testing.expectEqual(@as(usize, 2), p.tracked());
    const top_list = try p.top(alloc, 10);
    try std.testing.expectEqualStrings("a", top_list[0].query);
    try std.testing.expectEqual(@as(u64, 2), top_list[0].count);
    // b and c both had count 1; exactly one was evicted.
    try std.testing.expectEqual(@as(u64, 1), top_list[1].count);
}

test "popular save/load round-trips counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = PopularSearches.init(alloc, 100);
    defer p.deinit();
    try p.record("fuel shortage");
    try p.record("fuel shortage");
    try p.record("elections");
    const path = "/tmp/pulse-popular-test.json";
    try p.save(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var loaded = PopularSearches.load(alloc, std.testing.io, path, 100);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.tracked());
    const top_list = try loaded.top(alloc, 10);
    try std.testing.expectEqualStrings("fuel shortage", top_list[0].query);
    try std.testing.expectEqual(@as(u64, 2), top_list[0].count);
}

test "popular load of a missing file returns an empty tracker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = PopularSearches.load(alloc, std.testing.io, "/tmp/pulse-popular-does-not-exist.json", 100);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.tracked());
}

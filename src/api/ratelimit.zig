//! Per-key rate limiting (Roadmap 1.2): 100 requests/minute and 10,000/day
//! per API key by default (design-doc limits), fixed windows.
//! Single-threaded in Phase 1; no internal locking.

const std = @import("std");

pub const CheckResult = struct {
    allowed: bool,
    /// Seconds until the current minute window resets (0 when allowed).
    retry_after_s: u64,
};

const Entry = struct {
    minute_start_ms: i64,
    minute_count: u32,
    day_start_ms: i64,
    day_count: u32,
};

pub const RateLimiter = struct {
    alloc: std.mem.Allocator,
    per_minute: u32,
    per_day: u32,
    entries: std.StringHashMap(Entry),

    pub fn init(alloc: std.mem.Allocator, per_minute: u32, per_day: u32) RateLimiter {
        return .{
            .alloc = alloc,
            .per_minute = per_minute,
            .per_day = per_day,
            .entries = std.StringHashMap(Entry).init(alloc),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.entries.deinit();
    }

    /// `now_ms` is unix millis. Counts the request when allowed.
    pub fn check(self: *RateLimiter, key: []const u8, now_ms: i64) !CheckResult {
        const minute_start = now_ms - @mod(now_ms, 60_000);
        const day_start = now_ms - @mod(now_ms, 86_400_000);
        const entry = try self.entries.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.alloc.dupe(u8, key);
            entry.value_ptr.* = .{
                .minute_start_ms = minute_start,
                .minute_count = 0,
                .day_start_ms = day_start,
                .day_count = 0,
            };
        }
        var e = entry.value_ptr;
        if (e.minute_start_ms != minute_start) {
            e.minute_start_ms = minute_start;
            e.minute_count = 0;
        }
        if (e.day_start_ms != day_start) {
            e.day_start_ms = day_start;
            e.day_count = 0;
        }
        if (e.minute_count >= self.per_minute or e.day_count >= self.per_day) {
            const retry = @as(u64, @intCast(@divFloor(60_000 - @mod(now_ms, 60_000) + 999, 1000)));
            return .{ .allowed = false, .retry_after_s = @max(1, retry) };
        }
        e.minute_count += 1;
        e.day_count += 1;
        return .{ .allowed = true, .retry_after_s = 0 };
    }
};

test "rate limiter allows under the limit and blocks at it" {
    var rl = RateLimiter.init(std.testing.allocator, 2, 10);
    defer rl.deinit();
    const now: i64 = 1_800_000_000_000;
    try std.testing.expect((try rl.check("key-a", now)).allowed);
    try std.testing.expect((try rl.check("key-a", now)).allowed);
    const third = try rl.check("key-a", now);
    try std.testing.expect(!third.allowed);
    try std.testing.expect(third.retry_after_s >= 1);
    // A different key is unaffected.
    try std.testing.expect((try rl.check("key-b", now)).allowed);
}

test "rate limiter minute window rolls over" {
    var rl = RateLimiter.init(std.testing.allocator, 1, 10);
    defer rl.deinit();
    const now: i64 = 1_800_000_000_000;
    try std.testing.expect((try rl.check("k", now)).allowed);
    try std.testing.expect(!(try rl.check("k", now)).allowed);
    try std.testing.expect((try rl.check("k", now + 61_000)).allowed);
}

test "rate limiter day limit binds when minute limit is high" {
    var rl = RateLimiter.init(std.testing.allocator, 1000, 2);
    defer rl.deinit();
    const now: i64 = 1_800_000_000_000;
    try std.testing.expect((try rl.check("k", now)).allowed);
    try std.testing.expect((try rl.check("k", now)).allowed);
    try std.testing.expect(!(try rl.check("k", now)).allowed);
}

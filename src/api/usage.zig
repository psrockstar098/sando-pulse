//! API consumers, per-consumer quotas, and usage tracking (Roadmap 5.3).
//!
//! Consumers are named API clients (Sando is the first). The operator
//! registers them in PULSE_CONSUMERS:
//!   `sando:query,ingest:10000;partner:query:1000`
//! i.e. `name:scope,scope:quota_per_day`, semicolon-separated. Scopes:
//! `query`, `ingest`, `admin` (`*` means all three). A quota of 0 falls
//! back to the global PULSE_RATE_LIMIT_PER_DAY. With no PULSE_CONSUMERS
//! set there is a single implicit consumer, "default", with all scopes
//! and the global quota — the pre-5.3 behaviour.
//!
//! The caller identifies itself with the `X-Pulse-Consumer` header.
//! A missing header means "default"; an unknown name is 401; a scope
//! the consumer does not hold is 403. Usage is counted per consumer,
//! per kind (query/ingest), per UTC day — in Redis when configured
//! (`pulse:usage:<consumer>:<YYYY-MM-DD>:<kind>`, INCR + 48h TTL) and
//! in memory otherwise. Usage reads never consume quota.

const std = @import("std");
const redis = @import("../storage/redis.zig");
const format = @import("../common/format.zig");

pub const default_consumer_name: []const u8 = "default";

pub const Scope = enum { query, ingest, admin };

pub const Consumer = struct {
    name: []const u8,
    scopes: []const Scope,
    /// Daily quota for query+ingest calls. 0 = the global daily limit.
    quota_per_day: u32,
};

pub fn validConsumerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const lower = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!lower) return false;
    }
    return true;
}

fn parseScope(s: []const u8) ?Scope {
    if (std.mem.eql(u8, s, "query")) return .query;
    if (std.mem.eql(u8, s, "ingest")) return .ingest;
    if (std.mem.eql(u8, s, "admin")) return .admin;
    return null;
}

pub fn consumerHasScope(c: *const Consumer, scope: Scope) bool {
    for (c.scopes) |s| {
        if (s == scope) return true;
    }
    return false;
}

/// Parse a PULSE_CONSUMERS spec. Malformed entries are skipped (the
/// caller logs a warning); an empty spec yields an empty list, which
/// means "default consumer only".
pub fn parseConsumers(alloc: std.mem.Allocator, spec: []const u8) ![]Consumer {
    var out: std.ArrayList(Consumer) = .empty;
    var entries = std.mem.splitScalar(u8, spec, ';');
    while (entries.next()) |entry| {
        const e = std.mem.trim(u8, entry, " \t");
        if (e.len == 0) continue;
        var parts = std.mem.splitScalar(u8, e, ':');
        const name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const scopes_s = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const quota_s = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (!validConsumerName(name)) continue;
        if (parts.next() != null) continue; // too many fields
        const quota = std.fmt.parseInt(u32, quota_s, 10) catch continue;
        var scopes: std.ArrayList(Scope) = .empty;
        var it = std.mem.splitScalar(u8, scopes_s, ',');
        var ok = true;
        while (it.next()) |s| {
            const t = std.mem.trim(u8, s, " \t");
            if (std.mem.eql(u8, t, "*")) {
                try scopes.append(alloc, .query);
                try scopes.append(alloc, .ingest);
                try scopes.append(alloc, .admin);
                continue;
            }
            const sc = parseScope(t) orelse {
                ok = false;
                break;
            };
            try scopes.append(alloc, sc);
        }
        if (!ok or scopes.items.len == 0) {
            scopes.deinit(alloc);
            continue;
        }
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .scopes = try scopes.toOwnedSlice(alloc),
            .quota_per_day = quota,
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn findConsumer(consumers: []const Consumer, name: []const u8) ?*const Consumer {
    for (consumers) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// "YYYY-MM-DD" (UTC) for a Unix timestamp. Same civil-from-days math
/// as the other date helpers in the tree.
pub fn dayOf(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const days = @divFloor(ts, 86400);
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
    var buf: [11]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, m, 2);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, d, 2);
    return alloc.dupe(u8, w.buffered());
}

pub const UsageKind = enum { query, ingest };

/// One row of per-consumer daily usage (Roadmap 5.3): today's
/// counts for one consumer plus the quota it is measured against.
/// `remaining` is quota minus (queries + ingests), floored at 0.
pub const UsageRow = struct {
    consumer: []const u8,
    queries: u64,
    ingests: u64,
    quota_per_day: u32,
    remaining: u64,
};

fn kindName(kind: UsageKind) []const u8 {
    return switch (kind) {
        .query => "query",
        .ingest => "ingest",
    };
}

pub const UsageTracker = struct {
    alloc: std.mem.Allocator,
    redis_client: ?*redis.RedisClient,
    /// In-memory fallback when Redis is absent: "consumer|day|kind" -> count.
    mem: std.StringHashMap(u64),

    pub fn init(alloc: std.mem.Allocator, redis_client: ?*redis.RedisClient) UsageTracker {
        return .{
            .alloc = alloc,
            .redis_client = redis_client,
            .mem = std.StringHashMap(u64).init(alloc),
        };
    }

    pub fn deinit(self: *UsageTracker) void {
        var it = self.mem.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.mem.deinit();
    }

    fn redisKey(alloc: std.mem.Allocator, consumer: []const u8, kind: UsageKind, day: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "pulse:usage:{s}:{s}:{s}", .{ consumer, day, kindName(kind) });
    }

    fn memKey(alloc: std.mem.Allocator, consumer: []const u8, kind: UsageKind, day: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}|{s}|{s}", .{ consumer, day, kindName(kind) });
    }

    /// Count one completed call. Best-effort on the Redis leg: a Redis
    /// error falls back to the in-memory counter rather than failing
    /// the request.
    pub fn record(self: *UsageTracker, consumer: []const u8, kind: UsageKind, day: []const u8) !void {
        if (self.redis_client) |rc| {
            const key = try redisKey(self.alloc, consumer, kind, day);
            defer self.alloc.free(key);
            _ = rc.incr(self.alloc, key) catch {
                // Redis leg failed: fall through to memory.
                return self.recordMem(consumer, kind, day);
            };
            _ = rc.expire(self.alloc, key, 172800) catch {};
            return;
        }
        return self.recordMem(consumer, kind, day);
    }

    fn recordMem(self: *UsageTracker, consumer: []const u8, kind: UsageKind, day: []const u8) !void {
        self.pruneMem(day);
        const key = try memKey(self.alloc, consumer, kind, day);
        const entry = try self.mem.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        } else {
            self.alloc.free(key);
        }
        entry.value_ptr.* += 1;
    }

    /// Drop in-memory entries from any day other than `day` or the day
    /// before it (keeps the map bounded to two days of keys).
    fn pruneMem(self: *UsageTracker, day: []const u8) void {
        if (self.mem.count() < 10000) return;
        var it = self.mem.keyIterator();
        var stale: std.ArrayList([]const u8) = .empty;
        while (it.next()) |k| {
            // key shape "consumer|YYYY-MM-DD|kind" — the day is the
            // middle segment.
            const first = std.mem.indexOfScalar(u8, k.*, '|') orelse continue;
            const second = std.mem.indexOfScalarPos(u8, k.*, first + 1, '|') orelse continue;
            const key_day = k.*[first + 1 .. second];
            if (!std.mem.eql(u8, key_day, day)) {
                stale.append(self.alloc, k.*) catch continue;
            }
        }
        for (stale.items) |k| {
            if (self.mem.fetchRemove(k)) |kv| self.alloc.free(kv.key);
        }
        stale.deinit(self.alloc);
    }

    pub fn count(self: *UsageTracker, alloc: std.mem.Allocator, consumer: []const u8, kind: UsageKind, day: []const u8) u64 {
        if (self.redis_client) |rc| {
            const key = redisKey(alloc, consumer, kind, day) catch return 0;
            defer alloc.free(key);
            const raw = rc.get(alloc, key) catch return self.countMem(consumer, kind, day);
            const s = raw orelse return 0;
            return std.fmt.parseInt(u64, s, 10) catch 0;
        }
        return self.countMem(consumer, kind, day);
    }

    fn countMem(self: *UsageTracker, consumer: []const u8, kind: UsageKind, day: []const u8) u64 {
        const key = memKey(self.alloc, consumer, kind, day) catch return 0;
        defer self.alloc.free(key);
        return self.mem.get(key) orelse 0;
    }
};

test "usage: validConsumerName" {
    try std.testing.expect(validConsumerName("sando"));
    try std.testing.expect(validConsumerName("partner-1_x"));
    try std.testing.expect(!validConsumerName(""));
    try std.testing.expect(!validConsumerName("has space"));
    try std.testing.expect(!validConsumerName("has.dot"));
    try std.testing.expect(!validConsumerName("has/slash"));
    try std.testing.expect(!validConsumerName("UPPER"));
}

test "usage: parseConsumers" {
    const alloc = std.testing.allocator;
    const list = try parseConsumers(alloc, "sando:query,ingest:10000;partner:query:1000");
    defer {
        for (list) |c| {
            alloc.free(c.name);
            alloc.free(c.scopes);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("sando", list[0].name);
    try std.testing.expectEqual(@as(u32, 10000), list[0].quota_per_day);
    try std.testing.expect(consumerHasScope(&list[0], .query));
    try std.testing.expect(consumerHasScope(&list[0], .ingest));
    try std.testing.expect(!consumerHasScope(&list[0], .admin));
    try std.testing.expectEqualStrings("partner", list[1].name);
    try std.testing.expect(consumerHasScope(&list[1], .query));
    try std.testing.expect(!consumerHasScope(&list[1], .ingest));
    try std.testing.expect(findConsumer(list, "sando") != null);
    try std.testing.expect(findConsumer(list, "nobody") == null);
}

test "usage: parseConsumers star scope and bad entries skipped" {
    const alloc = std.testing.allocator;
    const list = try parseConsumers(alloc, "ops:*:0;bad name:query:5;nope:fly:10;empty::10;ok:admin:50");
    defer {
        for (list) |c| {
            alloc.free(c.name);
            alloc.free(c.scopes);
        }
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(consumerHasScope(&list[0], .admin));
    try std.testing.expectEqual(@as(u32, 0), list[0].quota_per_day);
    try std.testing.expectEqualStrings("ok", list[1].name);
}

test "usage: dayOf" {
    const alloc = std.testing.allocator;
    const d = try dayOf(alloc, 1794441600); // 2026-11-12 00:00 UTC
    defer alloc.free(d);
    try std.testing.expectEqualStrings("2026-11-12", d);
    const d2 = try dayOf(alloc, 1794540816); // 2026-11-13 03:33:36 UTC
    defer alloc.free(d2);
    try std.testing.expectEqualStrings("2026-11-13", d2);
}

test "usage: in-memory tracker counts per consumer and kind" {
    const alloc = std.testing.allocator;
    var tracker = UsageTracker.init(alloc, null);
    defer tracker.deinit();
    try tracker.record("sando", .query, "2026-11-13");
    try tracker.record("sando", .query, "2026-11-13");
    try tracker.record("sando", .ingest, "2026-11-13");
    try tracker.record("partner", .query, "2026-11-13");
    try std.testing.expectEqual(@as(u64, 2), tracker.count(alloc, "sando", .query, "2026-11-13"));
    try std.testing.expectEqual(@as(u64, 1), tracker.count(alloc, "sando", .ingest, "2026-11-13"));
    try std.testing.expectEqual(@as(u64, 1), tracker.count(alloc, "partner", .query, "2026-11-13"));
    try std.testing.expectEqual(@as(u64, 0), tracker.count(alloc, "sando", .query, "2026-11-12"));
    try std.testing.expectEqual(@as(u64, 0), tracker.count(alloc, "nobody", .query, "2026-11-13"));
}

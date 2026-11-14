//! Trust & Intelligence Engine, Phase 5: historical event store.
//!
//! Historical search over the persisted events (the R7.5 event
//! grouping, read back, not rebuilt): filter by free-text query,
//! by year, and by county, with a monthly timeline of the matches.
//!
//! The county of an event comes from its DOCUMENTS — the counties
//! their text mentions (entities.extract) — because events carry no
//! county field of their own. An event "is about" a county when at
//! least one of its documents mentions it. That is honest but
//! approximate: a story that mentions Nimba in passing counts as a
//! Nimba event. The response says so.
//!
//! Never grouped by person name alone: entity resolution is Phase 7,
//! so this module groups by topic and county only.

const std = @import("std");
const format = @import("../../common/format.zig");
const knowledge = @import("../../storage/knowledge.zig");

/// One event with the counties its documents mention. Built by the
/// caller (the handler) from listEvents + eventDocs + entity
/// extraction, so this module stays pure and testable.
pub const EventWithCounties = struct {
    event: knowledge.KnowledgeEvent,
    counties: []const []const u8,
};

/// Year (e.g. 2026) of a unix timestamp, UTC. Same civil-from-days
/// algorithm as query.formatIso.
pub fn yearOf(unix: i64) i64 {
    const days = @divFloor(unix, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m = if (mp < 10) mp + 3 else mp - 9;
    return if (m <= 2) y + 1 else y;
}

/// Month key ("2026-11") of a unix timestamp, UTC.
pub fn monthKey(alloc: std.mem.Allocator, unix: i64) ![]u8 {
    const days = @divFloor(unix, 86400);
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

pub const MonthBucket = struct {
    month: []const u8,
    count: usize,
};

/// Filter events by query (case-insensitive substring of the title
/// or topic), year (of first_seen), and county (mentioned by at
/// least one of the event's documents). All filters are optional;
/// an event must pass every filter that is set.
pub fn searchHistory(
    alloc: std.mem.Allocator,
    events: []const EventWithCounties,
    query: ?[]const u8,
    year: ?i64,
    county: ?[]const u8,
) ![]EventWithCounties {
    var out: std.ArrayList(EventWithCounties) = .empty;
    for (events) |e| {
        if (query) |q| {
            const lower_title = try std.ascii.allocLowerString(alloc, e.event.title);
            defer alloc.free(lower_title);
            const lower_topic = try std.ascii.allocLowerString(alloc, e.event.topic);
            defer alloc.free(lower_topic);
            const lower_q = try std.ascii.allocLowerString(alloc, q);
            defer alloc.free(lower_q);
            if (std.mem.indexOf(u8, lower_title, lower_q) == null and std.mem.indexOf(u8, lower_topic, lower_q) == null) continue;
        }
        if (year) |y| {
            if (yearOf(e.event.first_seen) != y) continue;
        }
        if (county) |c| {
            var hit = false;
            for (e.counties) |ec| {
                if (std.ascii.eqlIgnoreCase(ec, c)) hit = true;
            }
            if (!hit) continue;
        }
        try out.append(alloc, e);
    }
    return out.toOwnedSlice(alloc);
}

/// Monthly timeline of the given events (by first_seen), oldest
/// month first.
pub fn timelineByMonth(alloc: std.mem.Allocator, events: []const EventWithCounties) ![]MonthBucket {
    var buckets: std.ArrayList(MonthBucket) = .empty;
    for (events) |e| {
        const key = try monthKey(alloc, e.event.first_seen);
        var found: ?*MonthBucket = null;
        for (buckets.items) |*b| {
            if (std.mem.eql(u8, b.month, key)) found = b;
        }
        if (found) |b| {
            b.count += 1;
        } else {
            try buckets.append(alloc, .{ .month = key, .count = 1 });
        }
    }
    std.mem.sort(MonthBucket, buckets.items, {}, struct {
        fn less(_: void, a: MonthBucket, b: MonthBucket) bool {
            return std.mem.lessThan(u8, a.month, b.month);
        }
    }.less);
    return buckets.toOwnedSlice(alloc);
}

fn ev(id: []const u8, title: []const u8, topic: []const u8, first_seen: i64) knowledge.KnowledgeEvent {
    return .{
        .id = id,
        .title = title,
        .topic = topic,
        .first_seen = first_seen,
        .last_seen = first_seen,
        .doc_count = 1,
        .summary = null,
        .distinct_sources = 1,
        .status = "reported",
    };
}

test "yearOf and monthKey" {
    // 2026-11-14T00:00:00Z = 1794681600.
    try std.testing.expectEqual(@as(i64, 2026), yearOf(1794681600));
    try std.testing.expectEqual(@as(i64, 2025), yearOf(1794681600 - 365 * 86400));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("2026-11", try monthKey(alloc, 1794681600));
    try std.testing.expectEqualStrings("2026-01", try monthKey(alloc, 1794681600 - 317 * 86400));
}

test "searchHistory filters by query, year and county" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const events = [_]EventWithCounties{
        .{ .event = ev("e1", "Fuel shortage hits Monrovia", "energy", 1794681600), .counties = &.{"Montserrado"} },
        .{ .event = ev("e2", "County meet opens in Gbarnga", "sports", 1794681600), .counties = &.{"Bong"} },
        .{ .event = ev("e3", "Fuel prices rise again", "energy", 1794681600 - 400 * 86400), .counties = &.{"Montserrado"} },
    };
    const by_query = try searchHistory(alloc, &events, "fuel", null, null);
    try std.testing.expectEqual(@as(usize, 2), by_query.len);
    const by_year = try searchHistory(alloc, &events, null, 2026, null);
    try std.testing.expectEqual(@as(usize, 2), by_year.len);
    const by_county = try searchHistory(alloc, &events, null, null, "bong");
    try std.testing.expectEqual(@as(usize, 1), by_county.len);
    try std.testing.expectEqualStrings("e2", by_county[0].event.id);
    const combined = try searchHistory(alloc, &events, "fuel", 2026, "montserrado");
    try std.testing.expectEqual(@as(usize, 1), combined.len);
    const none = try searchHistory(alloc, &events, "fuel", 2025, "nimba");
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const all = try searchHistory(alloc, &events, null, null, null);
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "timelineByMonth buckets and sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const events = [_]EventWithCounties{
        .{ .event = ev("e1", "A", "energy", 1794681600), .counties = &.{} },
        .{ .event = ev("e2", "B", "energy", 1794681600 - 40 * 86400), .counties = &.{} },
        .{ .event = ev("e3", "C", "energy", 1794681600 - 5 * 86400), .counties = &.{} },
    };
    const buckets = try timelineByMonth(alloc, &events);
    try std.testing.expectEqual(@as(usize, 2), buckets.len);
    try std.testing.expectEqualStrings("2026-10", buckets[0].month);
    try std.testing.expectEqual(@as(usize, 1), buckets[0].count);
    try std.testing.expectEqualStrings("2026-11", buckets[1].month);
    try std.testing.expectEqual(@as(usize, 2), buckets[1].count);
}

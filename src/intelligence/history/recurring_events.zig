//! Trust & Intelligence Engine, Phase 5: recurring-event detection
//! and similar events.
//!
//! A recurring story is a (topic, county) signature that shows up in
//! two or more distinct months — the same kind of thing happening
//! again in the same place (a fuel shortage every few months, a
//! county meet every year). The signature is topic + county only:
//! grouping by person name alone is NOT done here (entity resolution
//! is Phase 7, and two people sharing a name are not the same story).
//! A group with events in only one month is not recurring — it is
//! just one story.
//!
//! Similar events for one event id: same-topic events in a shared
//! county, or titles similar enough (>= 0.5, the R7.5 grouping
//! threshold) to be the same story told again. Sorted most similar
//! first.

const std = @import("std");
const knowledge = @import("../../storage/knowledge.zig");
const event_store = @import("event_store.zig");
const fuzzy = @import("../../engine/fuzzy.zig");

/// One recurring signature: the topic, the county, the events that
/// carry it, and the months they span.
pub const RecurringGroup = struct {
    topic: []const u8,
    county: []const u8,
    event_ids: []const []const u8,
    months: []const []const u8,
    count: usize,
    first_seen: i64,
    last_seen: i64,
};

/// Detect recurring groups among the events. An event with several
/// counties joins one group per county. Groups spanning fewer than
/// two distinct months are dropped. Groups are sorted by count,
/// most events first.
pub fn detectRecurring(
    alloc: std.mem.Allocator,
    events: []const event_store.EventWithCounties,
) ![]RecurringGroup {
    const Key = struct {
        topic: []const u8,
        county: []const u8,
    };
    var groups: std.ArrayList(struct {
        key: Key,
        ids: std.ArrayList([]const u8),
        months: std.ArrayList([]const u8),
        first_seen: i64,
        last_seen: i64,
    }) = .empty;

    for (events) |e| {
        for (e.counties) |county| {
            var found: ?*std.meta.Child(@TypeOf(groups.items)) = null;
            for (groups.items) |*g| {
                if (std.mem.eql(u8, g.key.topic, e.event.topic) and std.mem.eql(u8, g.key.county, county)) found = g;
            }
            if (found == null) {
                try groups.append(alloc, .{
                    .key = .{ .topic = e.event.topic, .county = county },
                    .ids = .empty,
                    .months = .empty,
                    .first_seen = e.event.first_seen,
                    .last_seen = e.event.last_seen,
                });
                found = &groups.items[groups.items.len - 1];
            }
            const g = found.?;
            try g.ids.append(alloc, e.event.id);
            if (e.event.first_seen < g.first_seen) g.first_seen = e.event.first_seen;
            if (e.event.last_seen > g.last_seen) g.last_seen = e.event.last_seen;
            const month = try event_store.monthKey(alloc, e.event.first_seen);
            var seen = false;
            for (g.months.items) |m| {
                if (std.mem.eql(u8, m, month)) seen = true;
            }
            if (!seen) try g.months.append(alloc, month);
        }
    }

    var out: std.ArrayList(RecurringGroup) = .empty;
    for (groups.items) |g| {
        if (g.months.items.len < 2) continue;
        try out.append(alloc, .{
            .topic = g.key.topic,
            .county = g.key.county,
            .event_ids = g.ids.items,
            .months = g.months.items,
            .count = g.ids.items.len,
            .first_seen = g.first_seen,
            .last_seen = g.last_seen,
        });
    }
    std.mem.sort(RecurringGroup, out.items, {}, struct {
        fn less(_: void, a: RecurringGroup, b: RecurringGroup) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.topic, b.topic);
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

/// One similar event, with why it counts as similar.
pub const SimilarEvent = struct {
    event: knowledge.KnowledgeEvent,
    similarity: f64,
    reason: []const u8,
};

/// Events similar to `target`: title similarity >= 0.5, or the same
/// topic in a county the target also touches. The target itself is
/// excluded. Sorted most similar first. The `counties` map is the
/// same EventWithCounties list the caller built for the history
/// search, keyed by event id.
pub fn similarEvents(
    alloc: std.mem.Allocator,
    target: knowledge.KnowledgeEvent,
    target_counties: []const []const u8,
    events: []const event_store.EventWithCounties,
) ![]SimilarEvent {
    var out: std.ArrayList(SimilarEvent) = .empty;
    for (events) |e| {
        if (std.mem.eql(u8, e.event.id, target.id)) continue;
        const sim = fuzzy.similarity(alloc, e.event.title, target.title) catch 0;
        var shared_county = false;
        for (e.counties) |c| {
            for (target_counties) |tc| {
                if (std.ascii.eqlIgnoreCase(c, tc)) shared_county = true;
            }
        }
        if (sim >= 0.5) {
            try out.append(alloc, .{ .event = e.event, .similarity = sim, .reason = "title similar to the target event" });
        } else if (std.mem.eql(u8, e.event.topic, target.topic) and shared_county) {
            try out.append(alloc, .{ .event = e.event, .similarity = sim, .reason = "same topic in a shared county" });
        }
    }
    std.mem.sort(SimilarEvent, out.items, {}, struct {
        fn less(_: void, a: SimilarEvent, b: SimilarEvent) bool {
            return a.similarity > b.similarity;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

fn ev(id: []const u8, title: []const u8, topic: []const u8, first_seen: i64, last_seen: i64) knowledge.KnowledgeEvent {
    return .{
        .id = id,
        .title = title,
        .topic = topic,
        .first_seen = first_seen,
        .last_seen = last_seen,
        .doc_count = 1,
        .summary = null,
        .distinct_sources = 1,
        .status = "reported",
    };
}

test "detectRecurring needs two distinct months" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Nov 14 2026 = 1794681600; Oct 5 2026 = 1794681600 - 40d.
    const nov: i64 = 1794681600;
    const oct: i64 = 1794681600 - 40 * 86400;
    const events = [_]event_store.EventWithCounties{
        .{ .event = ev("e1", "Fuel shortage hits Monrovia", "energy", oct, oct), .counties = &.{"Montserrado"} },
        .{ .event = ev("e2", "Fuel shortage returns to Monrovia", "energy", nov, nov), .counties = &.{"Montserrado"} },
        .{ .event = ev("e3", "County meet opens in Gbarnga", "sports", nov, nov), .counties = &.{"Bong"} },
        .{ .event = ev("e4", "County meet finals in Gbarnga", "sports", nov, nov), .counties = &.{"Bong"} },
    };
    const groups = try detectRecurring(alloc, &events);
    // Only the energy/Montserrado pair spans two months; the two
    // sports events are both in November.
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqualStrings("energy", groups[0].topic);
    try std.testing.expectEqualStrings("Montserrado", groups[0].county);
    try std.testing.expectEqual(@as(usize, 2), groups[0].count);
    try std.testing.expectEqual(@as(usize, 2), groups[0].months.len);
}

test "similarEvents matches by title or by topic+county" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794681600;
    const target = ev("t", "Fuel shortage hits Monrovia", "energy", now, now);
    const events = [_]event_store.EventWithCounties{
        .{ .event = ev("a", "Fuel shortage hits Monrovia again", "energy", now, now), .counties = &.{"Montserrado"} },
        .{ .event = ev("b", "Power cuts across Bong County", "energy", now, now), .counties = &.{"Bong"} },
        .{ .event = ev("c", "County meet opens in Gbarnga", "sports", now, now), .counties = &.{"Bong"} },
    };
    const sims = try similarEvents(alloc, target, &.{"Montserrado"}, &events);
    // "a" matches by title; "b" matches by topic (energy) but shares
    // no county with the target; "c" matches neither.
    try std.testing.expectEqual(@as(usize, 1), sims.len);
    try std.testing.expectEqualStrings("a", sims[0].event.id);
    // Same topic + shared county matches even with a dissimilar title.
    const events2 = [_]event_store.EventWithCounties{
        .{ .event = ev("b", "Power cuts across Montserrado", "energy", now, now), .counties = &.{"Montserrado"} },
    };
    const sims2 = try similarEvents(alloc, target, &.{"Montserrado"}, &events2);
    try std.testing.expectEqual(@as(usize, 1), sims2.len);
    try std.testing.expectEqualStrings("same topic in a shared county", sims2[0].reason);
}

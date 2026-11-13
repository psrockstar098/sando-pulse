//! Breaking alerts (Roadmap 7.3): typed incident kinds, same-event
//! merging across sources on TITLE-clustered events, and delivery to
//! Sando over the Redis stream `pulse:alerts`.
//!
//! Kinds are classified rules-based from the reports' own words —
//! no invented labels. Merging groups events whose titles are
//! trigram-similar (>= 0.5) AND share an incident kind, so the same
//! incident reported by several outlets becomes one alert citing
//! every source. Nothing here sends SMS or email — no provider
//! exists; the stream is the channel, and its subscription shape is
//! documented in docs/OPERATIONS.md.

const std = @import("std");
const knowledge = @import("../storage/knowledge.zig");
const events_intel = @import("events.zig");
const fuzzy = @import("../engine/fuzzy.zig");
const redis = @import("../storage/redis.zig");

/// Redis stream Sando subscribes to for breaking alerts.
pub const alert_stream: []const u8 = "pulse:alerts";
/// Consumer group name Sando should use (documented, not created
/// here — XREADGROUP creates it on first read).
pub const alert_group: []const u8 = "sando";

pub const IncidentKind = enum {
    accident,
    protest,
    road_closure,
    emergency,
    announcement,
    community_event,
    unknown,

    pub fn toString(self: IncidentKind) []const u8 {
        return switch (self) {
            .accident => "accident",
            .protest => "protest",
            .road_closure => "road_closure",
            .emergency => "emergency",
            .announcement => "announcement",
            .community_event => "community_event",
            .unknown => "unknown",
        };
    }
};

const accident_words: []const []const u8 = &.{ "accident", "crash", "collision", "killed", "dies in", "died in", "injured", "fatal" };
const protest_words: []const []const u8 = &.{ "protest", "demonstration", "protesters", "march against", "strike" };
const road_words: []const []const u8 = &.{ "road closed", "road closure", "blocked road", "road blocked", "highway closed" };
const emergency_words: []const []const u8 = &.{ "emergency", "fire outbreak", "flood", "outbreak", "cholera", "ebola", "disaster" };
const announcement_words: []const []const u8 = &.{ "announces", "announcement", "launches", "unveils", "declares" };
const community_words: []const []const u8 = &.{ "festival", "celebration", "tournament", "concert", "marathon", "pageant" };

fn containsAny(lower: []const u8, words: []const []const u8) bool {
    for (words) |w| {
        if (std.mem.indexOf(u8, lower, w) != null) return true;
    }
    return false;
}

/// Rules-based classification from the report's own words. Order
/// matters: an accident on a closed road is an accident first;
/// a protest that blocks a road is a protest first.
pub fn classifyIncident(alloc: std.mem.Allocator, title: []const u8, text: []const u8) !IncidentKind {
    const combined = try std.mem.concat(alloc, u8, &.{ title, " ", text });
    defer alloc.free(combined);
    const lower = try std.ascii.allocLowerString(alloc, combined);
    defer alloc.free(lower);
    if (containsAny(lower, accident_words)) return .accident;
    if (containsAny(lower, protest_words)) return .protest;
    if (containsAny(lower, road_words)) return .road_closure;
    if (containsAny(lower, emergency_words)) return .emergency;
    if (containsAny(lower, announcement_words)) return .announcement;
    if (containsAny(lower, community_words)) return .community_event;
    return .unknown;
}

/// One event plus its documents, as the merger sees it.
pub const EventWithDocs = struct {
    event: knowledge.KnowledgeEvent,
    docs: []const knowledge.EventDoc,
};

/// One merged alert: every event in the group, every source cited.
pub const MergedAlert = struct {
    kind: IncidentKind,
    title: []const u8,
    event_ids: []const []const u8,
    source_ids: []const []const u8,
    first_seen: i64,
    last_seen: i64,
    doc_count: usize,
    importance: f64,
};

/// Merge breaking events into alerts: same kind + trigram-similar
/// titles (>= 0.5) join one alert. The representative title is the
/// largest event's title. Sources are the distinct source ids across
/// all grouped events' documents. `now` is Unix seconds (for the
/// importance score, same weights as the briefing).
pub fn mergeBreakingAlerts(alloc: std.mem.Allocator, events: []const EventWithDocs, now: i64) ![]MergedAlert {
    var groups: std.ArrayList(std.ArrayList(usize)) = .empty;
    var kinds: std.ArrayList(IncidentKind) = .empty;
    for (events, 0..) |ewd, i| {
        const kind = try classifyIncident(alloc, ewd.event.title, "");
        var placed = false;
        for (groups.items, 0..) |*g, gi| {
            if (kinds.items[gi] != kind) continue;
            const rep = events[g.items[0]];
            const sim = try fuzzy.similarity(alloc, ewd.event.title, rep.event.title);
            if (sim >= 0.5) {
                try g.append(alloc, i);
                placed = true;
                break;
            }
        }
        if (!placed) {
            var g: std.ArrayList(usize) = .empty;
            try g.append(alloc, i);
            try groups.append(alloc, g);
            try kinds.append(alloc, kind);
        }
    }
    var out: std.ArrayList(MergedAlert) = .empty;
    for (groups.items, 0..) |g, gi| {
        // Representative: the event with the most documents.
        var rep_idx = g.items[0];
        for (g.items) |idx| {
            if (events[idx].event.doc_count > events[rep_idx].event.doc_count) rep_idx = idx;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList([]const u8) = .empty;
        var first: i64 = events[rep_idx].event.first_seen;
        var last: i64 = events[rep_idx].event.last_seen;
        var docs: usize = 0;
        var distinct: usize = 0;
        for (g.items) |idx| {
            const e = events[idx].event;
            try ids.append(alloc, e.id);
            if (e.first_seen < first) first = e.first_seen;
            if (e.last_seen > last) last = e.last_seen;
            docs += e.doc_count;
            for (events[idx].docs) |d| {
                var seen = false;
                for (sources.items) |s| {
                    if (std.mem.eql(u8, s, d.source_id)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    try sources.append(alloc, d.source_id);
                    distinct += 1;
                }
            }
        }
        try out.append(alloc, .{
            .kind = kinds.items[gi],
            .title = events[rep_idx].event.title,
            .event_ids = try ids.toOwnedSlice(alloc),
            .source_ids = try sources.toOwnedSlice(alloc),
            .first_seen = first,
            .last_seen = last,
            .doc_count = docs,
            .importance = events_intel.importanceScore(docs, distinct, now - last),
        });
    }
    std.mem.sort(MergedAlert, out.items, {}, struct {
        fn less(_: void, a: MergedAlert, b: MergedAlert) bool {
            return a.importance > b.importance;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

/// Publish merged alerts to the Redis stream (one XADD per alert).
/// Returns the number published. A Redis failure is an error the
/// caller logs — the stream is best-effort, never a boot or
/// briefing failure.
pub fn publishAlerts(client: *redis.RedisClient, alloc: std.mem.Allocator, alerts: []const MergedAlert) !usize {
    var published: usize = 0;
    for (alerts) |a| {
        const ids = try std.mem.join(alloc, ",", a.event_ids);
        const srcs = try std.mem.join(alloc, ",", a.source_ids);
        var imp_buf: [32]u8 = undefined;
        const imp = try std.fmt.bufPrint(&imp_buf, "{d:.3}", .{a.importance});
        var docs_buf: [16]u8 = undefined;
        const docs = try std.fmt.bufPrint(&docs_buf, "{d}", .{a.doc_count});
        var ts_buf: [24]u8 = undefined;
        const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{a.last_seen});
        const fields = [_]redis.Field{
            .{ .name = "kind", .value = a.kind.toString() },
            .{ .name = "title", .value = a.title },
            .{ .name = "event_ids", .value = ids },
            .{ .name = "sources", .value = srcs },
            .{ .name = "doc_count", .value = docs },
            .{ .name = "importance", .value = imp },
            .{ .name = "ts", .value = ts },
        };
        _ = try client.xadd(alloc, alert_stream, &fields);
        published += 1;
    }
    return published;
}

test "classifyIncident names each kind from the report's own words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqual(IncidentKind.accident, try classifyIncident(alloc, "Two killed in road crash near Gbarnga", ""));
    try std.testing.expectEqual(IncidentKind.protest, try classifyIncident(alloc, "Students protest fee hike in Monrovia", ""));
    try std.testing.expectEqual(IncidentKind.road_closure, try classifyIncident(alloc, "Road closed after bridge collapse", ""));
    try std.testing.expectEqual(IncidentKind.emergency, try classifyIncident(alloc, "Fire outbreak destroys market stalls", ""));
    try std.testing.expectEqual(IncidentKind.announcement, try classifyIncident(alloc, "President announces new cabinet", ""));
    try std.testing.expectEqual(IncidentKind.community_event, try classifyIncident(alloc, "Music festival lights up Lofa", ""));
    try std.testing.expectEqual(IncidentKind.unknown, try classifyIncident(alloc, "Budget debate continues in Senate", ""));
    // Accident outranks road closure in the same headline.
    try std.testing.expectEqual(IncidentKind.accident, try classifyIncident(alloc, "Fatal crash closes road to Kakata", ""));
}

test "mergeBreakingAlerts groups same-kind similar titles, cites every source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const docs_a = [_]knowledge.EventDoc{
        .{ .id = "d1", .title = "Fuel shortage hits Monrovia", .source_id = "new-dawn", .source_name = "New Dawn", .published_at = now - 3600, .text = "" },
        .{ .id = "d2", .title = "Fuel shortage hits Monrovia", .source_id = "gnn", .source_name = "GNN", .published_at = now - 1800, .text = "" },
    };
    const docs_b = [_]knowledge.EventDoc{
        .{ .id = "d3", .title = "Fuel shortage continues in Monrovia today", .source_id = "daily-observer", .source_name = "Daily Observer", .published_at = now - 900, .text = "" },
    };
    const docs_c = [_]knowledge.EventDoc{
        .{ .id = "d4", .title = "Music festival lights up Lofa", .source_id = "new-dawn", .source_name = "New Dawn", .published_at = now - 900, .text = "" },
    };
    const events = [_]EventWithDocs{
        .{ .event = .{ .id = "e1", .title = "Fuel shortage hits Monrovia", .topic = "energy", .first_seen = now - 3600, .last_seen = now - 1800, .doc_count = 2 }, .docs = &docs_a },
        .{ .event = .{ .id = "e2", .title = "Fuel shortage continues in Monrovia today", .topic = "energy", .first_seen = now - 900, .last_seen = now - 900, .doc_count = 1 }, .docs = &docs_b },
        .{ .event = .{ .id = "e3", .title = "Music festival lights up Lofa", .topic = "culture", .first_seen = now - 900, .last_seen = now - 900, .doc_count = 1 }, .docs = &docs_c },
    };
    const alerts = try mergeBreakingAlerts(alloc, &events, now);
    try std.testing.expectEqual(@as(usize, 2), alerts.len);
    // The two fuel events merge: 3 docs, 3 sources, both event ids.
    var fuel: ?MergedAlert = null;
    for (alerts) |a| {
        if (std.mem.indexOf(u8, a.title, "Fuel shortage") != null) fuel = a;
    }
    try std.testing.expect(fuel != null);
    try std.testing.expectEqual(@as(usize, 3), fuel.?.doc_count);
    try std.testing.expectEqual(@as(usize, 3), fuel.?.source_ids.len);
    try std.testing.expectEqual(@as(usize, 2), fuel.?.event_ids.len);
    try std.testing.expectEqual(IncidentKind.unknown, fuel.?.kind);
    // The festival stands alone as its own kind.
    try std.testing.expectEqual(IncidentKind.community_event, alerts[1].kind);
}

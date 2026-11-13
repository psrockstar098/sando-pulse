//! Precomputed intelligence (Roadmap 4.4): the briefing bundle Pulse
//! prepares on a schedule so common reads are instant.
//!
//! The briefing answers the questions readers ask most, from the data
//! already in the store — no new collection, no invented content:
//! top stories today, top Geez (entertainment) today / this week /
//! last month, latest updates for Liberia, Lofa and Montserrado,
//! popular political and entertainment discussions, and breaking news
//! (fresh, important, not retracted). Pure computation over the
//! repository + knowledge store; the worker recomputes it on a schedule
//! and caches the rendered JSON in Redis (`pulse:briefing`, TTL from
//! config). The endpoint serves the cache when fresh and recomputes live
//! when Redis is absent, so the briefing is never stale by more than
//! one interval — and never unavailable because Redis is down.

const std = @import("std");
const types = @import("../common/types.zig");
const knowledge = @import("../storage/knowledge.zig");
const repository = @import("../storage/repository.zig");
const redis = @import("../storage/redis.zig");
const events_intel = @import("events.zig");
const trending = @import("trending.zig");
const entities_mod = @import("../engine/entities.zig");

pub const briefing_key: []const u8 = "pulse:briefing";
pub const default_interval_s: u64 = 3600;
pub const default_ttl_s: u64 = 3600;

/// Breaking news bar: importance at or above this, seen in the last
/// 6 hours, and not retracted by the publisher.
pub const breaking_importance: f64 = 0.5;
pub const breaking_window_s: i64 = 6 * 3600;

pub const DocRef = struct {
    id: []const u8,
    title: []const u8,
    source_id: []const u8,
    published_at: i64,
};

pub const EventRef = struct {
    id: []const u8,
    title: []const u8,
    topic: []const u8,
    doc_count: usize,
    distinct_sources: usize,
    status: []const u8,
    importance: f64,
};

pub const Briefing = struct {
    computed_at: i64,
    top_stories: []EventRef,
    top_geez_today: []trending.TopicTrend,
    top_geez_week: []trending.TopicTrend,
    top_geez_month: []trending.TopicCount,
    latest_liberia: []DocRef,
    latest_lofa: []DocRef,
    latest_montserrado: []DocRef,
    popular_political: []EventRef,
    popular_entertainment: []EventRef,
    breaking: []EventRef,
};

fn eventRef(event: knowledge.KnowledgeEvent, now: i64) EventRef {
    return .{
        .id = event.id,
        .title = event.title,
        .topic = event.topic,
        .doc_count = event.doc_count,
        .distinct_sources = event.distinct_sources,
        .status = event.status,
        .importance = events_intel.importanceScore(event.doc_count, event.distinct_sources, now - event.last_seen),
    };
}

fn docRef(doc: types.Document) DocRef {
    return .{
        .id = doc.id,
        .title = doc.title,
        .source_id = doc.source_id,
        .published_at = knowledge.docTs(doc),
    };
}

fn sortEventsByImportance(refs: []EventRef) void {
    std.mem.sort(EventRef, refs, {}, struct {
        fn less(_: void, a: EventRef, b: EventRef) bool {
            return a.importance > b.importance;
        }
    }.less);
}

fn sortEventsByDocs(refs: []EventRef) void {
    std.mem.sort(EventRef, refs, {}, struct {
        fn less(_: void, a: EventRef, b: EventRef) bool {
            return a.doc_count > b.doc_count;
        }
    }.less);
}

fn sortDocsNewest(refs: []DocRef) void {
    std.mem.sort(DocRef, refs, {}, struct {
        fn less(_: void, a: DocRef, b: DocRef) bool {
            return a.published_at > b.published_at;
        }
    }.less);
}

/// Compute the full briefing from the live store. `ks` may be null
/// (memory/dev without a knowledge store) — the event-based sections
/// are then empty and the doc-based sections still work.
pub fn computeBriefing(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    ks: ?knowledge.KnowledgeStore,
    now: i64,
) !Briefing {
    const day_start = now - @mod(now, 86400);
    var events: []knowledge.KnowledgeEvent = &.{};
    if (ks) |k| {
        events = try k.listEvents(alloc, 100);
    }
    var stories: std.ArrayList(EventRef) = .empty;
    var political: std.ArrayList(EventRef) = .empty;
    var entertainment: std.ArrayList(EventRef) = .empty;
    var breaking: std.ArrayList(EventRef) = .empty;
    for (events) |e| {
        const ref = eventRef(e, now);
        if (e.last_seen >= day_start) try stories.append(alloc, ref);
        if (std.mem.eql(u8, e.topic, "politics")) try political.append(alloc, ref);
        if (std.mem.eql(u8, e.topic, "culture")) try entertainment.append(alloc, ref);
        if (ref.importance >= breaking_importance and now - e.last_seen <= breaking_window_s and
            !std.mem.eql(u8, e.status, "retracted"))
        {
            try breaking.append(alloc, ref);
        }
    }
    sortEventsByImportance(stories.items);
    sortEventsByDocs(political.items);
    sortEventsByDocs(entertainment.items);
    sortEventsByImportance(breaking.items);

    const docs = try repo.scanDocuments(alloc, now, 5000);
    const trends_today = try trending.computeTrends(alloc, docs, now, 86400);
    const trends_week = try trending.computeTrends(alloc, docs, now, 7 * 86400);
    var latest_liberia: std.ArrayList(DocRef) = .empty;
    var latest_lofa: std.ArrayList(DocRef) = .empty;
    var latest_montserrado: std.ArrayList(DocRef) = .empty;
    for (docs) |doc| {
        const ref = docRef(doc);
        try latest_liberia.append(alloc, ref);
        const combined = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        defer alloc.free(combined);
        const ent = try entities_mod.extract(alloc, combined);
        defer entities_mod.freeEntities(alloc, ent);
        for (ent.counties) |county| {
            if (std.mem.eql(u8, county, "Lofa")) try latest_lofa.append(alloc, ref);
            if (std.mem.eql(u8, county, "Montserrado")) try latest_montserrado.append(alloc, ref);
        }
    }
    sortDocsNewest(latest_liberia.items);
    sortDocsNewest(latest_lofa.items);
    sortDocsNewest(latest_montserrado.items);

    // Top Geez last month: the latest month in the aggregates, culture
    // topic only. Empty when no aggregates exist yet.
    var geez_month: []trending.TopicCount = &.{};
    if (ks) |k| {
        const aggs = try k.listMonthlyAggregates(alloc, 200);
        var latest_month: ?[]const u8 = null;
        for (aggs) |row| {
            if (latest_month == null or std.mem.lessThan(u8, latest_month.?, row.year_month)) {
                latest_month = row.year_month;
            }
        }
        if (latest_month) |m| {
            const snap = try trending.snapshotFromAggregates(alloc, aggs, m);
            var kept: std.ArrayList(trending.TopicCount) = .empty;
            for (snap.topics) |t| {
                if (std.mem.eql(u8, t.topic, "culture")) try kept.append(alloc, t);
            }
            geez_month = try kept.toOwnedSlice(alloc);
        }
    }

    return .{
        .computed_at = now,
        .top_stories = try stories.toOwnedSlice(alloc),
        .top_geez_today = try trending.topGeez(alloc, trends_today, 5),
        .top_geez_week = try trending.topGeez(alloc, trends_week, 5),
        .top_geez_month = geez_month,
        .latest_liberia = try latest_liberia.toOwnedSlice(alloc),
        .latest_lofa = try latest_lofa.toOwnedSlice(alloc),
        .latest_montserrado = try latest_montserrado.toOwnedSlice(alloc),
        .popular_political = try political.toOwnedSlice(alloc),
        .popular_entertainment = try entertainment.toOwnedSlice(alloc),
        .breaking = try breaking.toOwnedSlice(alloc),
    };
}

/// Render the briefing as JSON (no request_id — the endpoint wraps it).
/// The worker stores this exact payload in Redis.
pub fn renderBriefing(alloc: std.mem.Allocator, b: Briefing) ![]u8 {
    var stories: std.ArrayList(struct {
        id: []const u8,
        title: []const u8,
        topic: []const u8,
        doc_count: usize,
        distinct_sources: usize,
        status: []const u8,
        importance: f64,
    }) = .empty;
    for (b.top_stories) |e| try stories.append(alloc, .{
        .id = e.id, .title = e.title, .topic = e.topic, .doc_count = e.doc_count,
        .distinct_sources = e.distinct_sources, .status = e.status, .importance = e.importance,
    });
    var political: std.ArrayList(@TypeOf(stories.items[0])) = .empty;
    for (b.popular_political) |e| try political.append(alloc, .{
        .id = e.id, .title = e.title, .topic = e.topic, .doc_count = e.doc_count,
        .distinct_sources = e.distinct_sources, .status = e.status, .importance = e.importance,
    });
    var entertainment: std.ArrayList(@TypeOf(stories.items[0])) = .empty;
    for (b.popular_entertainment) |e| try entertainment.append(alloc, .{
        .id = e.id, .title = e.title, .topic = e.topic, .doc_count = e.doc_count,
        .distinct_sources = e.distinct_sources, .status = e.status, .importance = e.importance,
    });
    var breaking: std.ArrayList(@TypeOf(stories.items[0])) = .empty;
    for (b.breaking) |e| try breaking.append(alloc, .{
        .id = e.id, .title = e.title, .topic = e.topic, .doc_count = e.doc_count,
        .distinct_sources = e.distinct_sources, .status = e.status, .importance = e.importance,
    });
    var trend_list: std.ArrayList(struct {
        topic: []const u8,
        category: []const u8,
        recent_count: usize,
        prior_count: usize,
        velocity: f64,
        score: f64,
    }) = .empty;
    for (b.top_geez_today) |t| try trend_list.append(alloc, .{
        .topic = t.topic, .category = t.category, .recent_count = t.recent_count,
        .prior_count = t.prior_count, .velocity = t.velocity, .score = t.score,
    });
    var trend_week: std.ArrayList(@TypeOf(trend_list.items[0])) = .empty;
    for (b.top_geez_week) |t| try trend_week.append(alloc, .{
        .topic = t.topic, .category = t.category, .recent_count = t.recent_count,
        .prior_count = t.prior_count, .velocity = t.velocity, .score = t.score,
    });
    var doc_list: std.ArrayList(struct {
        id: []const u8,
        title: []const u8,
        source_id: []const u8,
        published_at: i64,
    }) = .empty;
    for (b.latest_liberia) |d| try doc_list.append(alloc, .{
        .id = d.id, .title = d.title, .source_id = d.source_id, .published_at = d.published_at,
    });
    var lofa_list: std.ArrayList(@TypeOf(doc_list.items[0])) = .empty;
    for (b.latest_lofa) |d| try lofa_list.append(alloc, .{
        .id = d.id, .title = d.title, .source_id = d.source_id, .published_at = d.published_at,
    });
    var mont_list: std.ArrayList(@TypeOf(doc_list.items[0])) = .empty;
    for (b.latest_montserrado) |d| try mont_list.append(alloc, .{
        .id = d.id, .title = d.title, .source_id = d.source_id, .published_at = d.published_at,
    });
    return stringifyAlloc(alloc, .{
        .computed_at = b.computed_at,
        .top_stories = stories.items,
        .top_geez_today = trend_list.items,
        .top_geez_week = trend_week.items,
        .top_geez_month = b.top_geez_month,
        .latest_liberia = doc_list.items,
        .latest_lofa = lofa_list.items,
        .latest_montserrado = mont_list.items,
        .popular_political = political.items,
        .popular_entertainment = entertainment.items,
        .breaking = breaking.items,
    });
}

fn stringifyAlloc(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

/// Recompute the briefing and store the rendered JSON in Redis
/// (worker schedule). Returns false when there is no Redis client or
/// the store fails — the endpoint recomputes live in that case.
pub fn refreshBriefing(
    alloc: std.mem.Allocator,
    client: ?*redis.RedisClient,
    repo: repository.Repository,
    ks: ?knowledge.KnowledgeStore,
    now: i64,
    ttl_s: u64,
) bool {
    const c = client orelse return false;
    const b = computeBriefing(alloc, repo, ks, now) catch return false;
    const payload = renderBriefing(alloc, b) catch return false;
    c.setex(briefing_key, ttl_s, payload) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests (memory store + memory knowledge — no live services)
// ---------------------------------------------------------------------------

const testing = std.testing;
const memory = @import("../storage/memory.zig");

fn testDoc(id: []const u8, title: []const u8, topics: []const []const u8, ts: i64) types.Document {
    return .{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com",
        .title = title,
        .url = "https://thenewdawnliberia.com/x",
        .text = title,
        .published_at = ts,
        .fetched_at = ts,
        .reliability = 0.7,
        .topics = topics,
        .content_hash = id,
        .lang = "en",
    };
}

fn seedStore(alloc: std.mem.Allocator, now: i64) !struct { repo: repository.Repository, ks: knowledge.KnowledgeStore } {
    var mem = try alloc.create(memory.MemoryStore);
    mem.* = memory.MemoryStore.init(alloc);
    const repo = mem.asRepository();
    var mk = try alloc.create(knowledge.MemoryKnowledge);
    mk.* = knowledge.MemoryKnowledge.init(alloc);
    const ks = mk.asKnowledge();
    // now is late in the UTC day (22:13), so 12h-old docs are still
    // "today" for the top-stories section while old enough that their
    // importance sits clearly below the 0.5 breaking bar.
    const docs = [_]types.Document{
        // Two politics docs in Montserrado, 12h old: one 2-doc event.
        testDoc("d1", "Senate passes election law in Montserrado", &.{ "politics" }, now - 43200),
        testDoc("d2", "President Boakai addresses nation in Montserrado", &.{ "politics" }, now - 43200),
        // One culture doc in Lofa, fresh.
        testDoc("d3", "Music festival lights up Lofa", &.{ "culture" }, now - 1800),
        // One old sports doc: not a top story today, not breaking.
        testDoc("d4", "Lone Star wins friendly match", &.{ "sports" }, now - 3 * 86400),
    };
    for (docs) |doc| {
        try repo.insertDocument(doc);
        const combined = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        defer alloc.free(combined);
        const ent = try entities_mod.extract(alloc, combined);
        defer entities_mod.freeEntities(alloc, ent);
        _ = try ks.upsertEventForDoc(alloc, doc, ent);
        try ks.recordEntities(alloc, doc, ent);
    }
    try ks.recordMonthlyAggregate(alloc, "2026-11", "culture", 7);
    try ks.recordMonthlyAggregate(alloc, "2026-11", "politics", 4);
    try ks.recordMonthlyAggregate(alloc, "2026-10", "culture", 3);
    return .{ .repo = repo, .ks = ks };
}

test "computeBriefing: top stories, breaking, county latest, geez month" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795040000; // 22:13 UTC — 12h-old docs are still today.
    const seeded = try seedStore(alloc, now);
    const b = try computeBriefing(alloc, seeded.repo, seeded.ks, now);

    // Two events are fresh today: the 2-doc politics event and the
    // 1-doc culture event.
    try testing.expectEqual(@as(usize, 2), b.top_stories.len);
    // Breaking: the 2-doc, 1-source, 12h-old politics event scores
    // ~0.44 — clearly below the 0.5 bar. The bar is deliberately high:
    // breaking needs volume, not just freshness.
    try testing.expectEqual(@as(usize, 0), b.breaking.len);
    // County latest: Montserrado has the two politics docs, Lofa the
    // culture doc, Liberia all four newest-first.
    try testing.expectEqual(@as(usize, 2), b.latest_montserrado.len);
    try testing.expectEqual(@as(usize, 1), b.latest_lofa.len);
    try testing.expectEqualStrings("d3", b.latest_lofa[0].id);
    try testing.expectEqual(@as(usize, 4), b.latest_liberia.len);
    try testing.expectEqualStrings("d3", b.latest_liberia[0].id);
    // Popular political: the politics event (2 docs); entertainment:
    // the culture event (1 doc).
    try testing.expectEqual(@as(usize, 1), b.popular_political.len);
    try testing.expectEqual(@as(usize, 2), b.popular_political[0].doc_count);
    try testing.expectEqual(@as(usize, 1), b.popular_entertainment.len);
    // Geez today: the culture topic is the only entertainment trend.
    try testing.expectEqual(@as(usize, 1), b.top_geez_today.len);
    try testing.expectEqualStrings("culture", b.top_geez_today[0].topic);
    // Geez month: latest month (2026-11) culture count 7.
    try testing.expectEqual(@as(usize, 1), b.top_geez_month.len);
    try testing.expectEqualStrings("culture", b.top_geez_month[0].topic);
    try testing.expectEqual(@as(usize, 7), b.top_geez_month[0].doc_count);
}

test "computeBriefing: breaking needs volume, not just freshness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    var mem = try alloc.create(memory.MemoryStore);
    mem.* = memory.MemoryStore.init(alloc);
    const repo = mem.asRepository();
    var mk = try alloc.create(knowledge.MemoryKnowledge);
    mk.* = knowledge.MemoryKnowledge.init(alloc);
    const ks = mk.asKnowledge();
    // 12 fresh docs on one energy story from 3 sources: importance
    // clears 0.5 (coverage log(13)/log(21) ~ 0.84 * 0.4 + corroboration
    // 0.6 * 0.3 + recency ~1 * 0.3 ≈ 0.82).
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "b{d}", .{i});
        const src = if (i % 3 == 0) "new-dawn" else if (i % 3 == 1) "daily-observer" else "gnn";
        const doc = types.Document{
            .id = id,
            .source_id = src,
            .source_name = src,
            .source_url = "https://example.com",
            .title = "Fuel shortage grips Monrovia",
            .url = "https://example.com/x",
            .text = "Fuel shortage grips Monrovia",
            .published_at = now - 1800,
            .fetched_at = now - 1800,
            .reliability = 0.7,
            .topics = &.{"energy"},
            .content_hash = id,
            .lang = "en",
        };
        try repo.insertDocument(doc);
        const ent = try entities_mod.extract(alloc, doc.title);
        defer entities_mod.freeEntities(alloc, ent);
        _ = try ks.upsertEventForDoc(alloc, doc, ent);
    }
    const b = try computeBriefing(alloc, repo, ks, now);
    try testing.expectEqual(@as(usize, 1), b.breaking.len);
    try testing.expect(b.breaking[0].importance >= breaking_importance);
    try testing.expectEqual(@as(usize, 12), b.breaking[0].doc_count);
}

test "renderBriefing produces parseable JSON with all sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795040000; // same late-day fixture as the first test.
    const seeded = try seedStore(alloc, now);
    const b = try computeBriefing(alloc, seeded.repo, seeded.ks, now);
    const json = try renderBriefing(alloc, b);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try testing.expect(parsed == .object);
    for ([_][]const u8{ "computed_at", "top_stories", "top_geez_today", "top_geez_week", "top_geez_month", "latest_liberia", "latest_lofa", "latest_montserrado", "popular_political", "popular_entertainment", "breaking" }) |key| {
        try testing.expect(parsed.object.get(key) != null);
    }
    try testing.expectEqual(@as(usize, 2), parsed.object.get("top_stories").?.array.items.len);
}

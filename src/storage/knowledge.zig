//! Knowledge database (Roadmap 3.4): persisted events, entities, topics,
//! locations, facilities, statistics, source health, monthly aggregates.
//! One interface for the Postgres and in-memory backends. The Postgres
//! implementation lives in postgres_knowledge.zig (its own connection);
//! the memory implementation is in this file so the dev default works.
//!
//! Events are persisted incrementally: each ingested document finds the
//! most recent open event with the same primary topic (or a trigram-
//! similar title) within 72 hours, or starts a new one. This is the
//! archive view; the search-time clustering in engine/search.zig is a
//! separate in-response grouping over the ranked set.

const std = @import("std");
const types = @import("../common/types.zig");
const entities_mod = @import("../engine/entities.zig");
const fuzzy = @import("../engine/fuzzy.zig");

pub const KnowledgeEvent = struct {
    id: []const u8,
    title: []const u8,
    topic: []const u8,
    first_seen: i64,
    last_seen: i64,
    doc_count: usize,
    summary: ?[]const u8 = null,
};

pub const EntityRow = struct {
    name: []const u8,
    kind: []const u8, // county | city | organization | person | topic
    doc_count: usize,
    first_seen: i64,
};

pub const TopicRow = struct {
    name: []const u8,
    doc_count: usize,
};

pub const LocationRow = struct {
    name: []const u8,
    kind: []const u8, // county | district | city | neighborhood
    county: ?[]const u8 = null,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Census population when published for this place (2008 census
    /// for districts/cities); null when not published.
    population: ?i64 = null,
    source: []const u8 = "",
    verified_at: ?[]const u8 = null, // YYYY-MM-DD
};

pub const FacilityRow = struct {
    name: []const u8,
    kind: []const u8, // school | hospital | university | market | clinic | ...
    county: ?[]const u8 = null,
    city: ?[]const u8 = null,
    lat: ?f64 = null,
    lon: ?f64 = null,
    source: []const u8 = "",
    verified_at: ?[]const u8 = null,
};

pub const StatisticRow = struct {
    key: []const u8,
    value: f64,
    unit: []const u8 = "",
    period: []const u8 = "",
    source: []const u8 = "",
    verified_at: ?[]const u8 = null,
};

pub const SourceHealth = struct {
    source_id: []const u8,
    last_run_at: ?i64 = null,
    last_success_at: ?i64 = null,
    last_error: ?[]const u8 = null,
    consecutive_failures: usize = 0,
    docs_total: usize = 0,
};

pub const KnowledgeCounts = struct {
    events: usize = 0,
    entities: usize = 0,
    topics: usize = 0,
    locations: usize = 0,
    facilities: usize = 0,
    statistics: usize = 0,
};

/// A document's date for event logic: published_at, falling back to
/// fetched_at for manually ingested docs (published_at null).
pub fn docTs(doc: types.Document) i64 {
    return doc.published_at orelse doc.fetched_at;
}

pub fn primaryTopic(ent: entities_mod.Entities) []const u8 {
    return if (ent.topics.len > 0) ent.topics[0] else "";
}

/// One historical rollup row: how many documents about `topic` were
/// collected in `year_month` ("YYYY-MM"). Written by maintenance
/// aggregation (Roadmap 3.5); read by the trending engine (Roadmap 4.2).
pub const MonthlyAggregate = struct {
    year_month: []const u8,
    topic: []const u8,
    doc_count: usize,
};

pub const KnowledgeStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recordEntities: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror!void,
        /// Find-or-create the event for this document; returns the event id.
        upsertEventForDoc: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror![]u8,
        listEvents: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, limit: usize) anyerror![]KnowledgeEvent,
        recordSourceHealth: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, health: SourceHealth) anyerror!void,
        getSourceHealth: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, source_id: []const u8) anyerror!?SourceHealth,
        upsertLocation: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, row: LocationRow) anyerror!void,
        upsertFacility: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, row: FacilityRow) anyerror!void,
        upsertStatistic: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, row: StatisticRow) anyerror!void,
        listLocations: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) anyerror![]LocationRow,
        listFacilities: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) anyerror![]FacilityRow,
        listStatistics: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]StatisticRow,
        recordMonthlyAggregate: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, year_month: []const u8, topic: []const u8, count: usize) anyerror!void,
        /// Read monthly rollups, newest month first, most documents first.
        listMonthlyAggregates: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, limit: usize) anyerror![]MonthlyAggregate,
        /// Recompute every event's doc_count from its linked documents
        /// (run after retention deletes documents). Events that lost
        /// all their documents keep their row and summary — the
        /// historical record survives — with doc_count 0.
        recomputeEventCounts: *const fn (ptr: *anyopaque) anyerror!void,
        counts: *const fn (ptr: *anyopaque) KnowledgeCounts,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn recordEntities(self: KnowledgeStore, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) !void {
        return self.vtable.recordEntities(self.ptr, alloc, doc, ent);
    }

    pub fn upsertEventForDoc(self: KnowledgeStore, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) ![]u8 {
        return self.vtable.upsertEventForDoc(self.ptr, alloc, doc, ent);
    }

    pub fn listEvents(self: KnowledgeStore, alloc: std.mem.Allocator, limit: usize) ![]KnowledgeEvent {
        return self.vtable.listEvents(self.ptr, alloc, limit);
    }

    pub fn recordSourceHealth(self: KnowledgeStore, alloc: std.mem.Allocator, health: SourceHealth) !void {
        return self.vtable.recordSourceHealth(self.ptr, alloc, health);
    }

    pub fn getSourceHealth(self: KnowledgeStore, alloc: std.mem.Allocator, source_id: []const u8) !?SourceHealth {
        return self.vtable.getSourceHealth(self.ptr, alloc, source_id);
    }

    pub fn upsertLocation(self: KnowledgeStore, alloc: std.mem.Allocator, row: LocationRow) !void {
        return self.vtable.upsertLocation(self.ptr, alloc, row);
    }

    pub fn upsertFacility(self: KnowledgeStore, alloc: std.mem.Allocator, row: FacilityRow) !void {
        return self.vtable.upsertFacility(self.ptr, alloc, row);
    }

    pub fn upsertStatistic(self: KnowledgeStore, alloc: std.mem.Allocator, row: StatisticRow) !void {
        return self.vtable.upsertStatistic(self.ptr, alloc, row);
    }

    pub fn listLocations(self: KnowledgeStore, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) ![]LocationRow {
        return self.vtable.listLocations(self.ptr, alloc, kind, limit);
    }

    pub fn listFacilities(self: KnowledgeStore, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) ![]FacilityRow {
        return self.vtable.listFacilities(self.ptr, alloc, kind, limit);
    }

    pub fn listStatistics(self: KnowledgeStore, alloc: std.mem.Allocator) ![]StatisticRow {
        return self.vtable.listStatistics(self.ptr, alloc);
    }

    pub fn recordMonthlyAggregate(self: KnowledgeStore, alloc: std.mem.Allocator, year_month: []const u8, topic: []const u8, count: usize) !void {
        return self.vtable.recordMonthlyAggregate(self.ptr, alloc, year_month, topic, count);
    }

    pub fn listMonthlyAggregates(self: KnowledgeStore, alloc: std.mem.Allocator, limit: usize) ![]MonthlyAggregate {
        return self.vtable.listMonthlyAggregates(self.ptr, alloc, limit);
    }

    pub fn recomputeEventCounts(self: KnowledgeStore) !void {
        return self.vtable.recomputeEventCounts(self.ptr);
    }

    pub fn counts(self: KnowledgeStore) KnowledgeCounts {
        return self.vtable.counts(self.ptr);
    }

    pub fn deinit(self: KnowledgeStore) void {
        self.vtable.deinit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// In-memory implementation
// ---------------------------------------------------------------------------

pub const MemoryKnowledge = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(KnowledgeEvent),
    event_sources: std.ArrayList(struct { event_id: []const u8, source_id: []const u8, doc_count: usize }),
    entities: std.ArrayList(EntityRow),
    topics: std.ArrayList(TopicRow),
    locations: std.ArrayList(LocationRow),
    facilities: std.ArrayList(FacilityRow),
    statistics: std.ArrayList(StatisticRow),
    health: std.ArrayList(SourceHealth),
    aggregates: std.ArrayList(struct { year_month: []const u8, topic: []const u8, count: usize }),

    pub fn init(alloc: std.mem.Allocator) MemoryKnowledge {
        return .{
            .alloc = alloc,
            .events = .empty,
            .event_sources = .empty,
            .entities = .empty,
            .topics = .empty,
            .locations = .empty,
            .facilities = .empty,
            .statistics = .empty,
            .health = .empty,
            .aggregates = .empty,
        };
    }

    pub fn deinit(self: *MemoryKnowledge) void {
        const a = self.alloc;
        for (self.events.items) |e| {
            a.free(e.id);
            a.free(e.title);
            a.free(e.topic);
            if (e.summary) |s| a.free(s);
        }
        self.events.deinit(a);
        for (self.event_sources.items) |es| {
            a.free(es.event_id);
            a.free(es.source_id);
        }
        self.event_sources.deinit(a);
        for (self.entities.items) |e| {
            a.free(e.name);
            a.free(e.kind);
        }
        self.entities.deinit(a);
        for (self.topics.items) |t| a.free(t.name);
        self.topics.deinit(a);
        for (self.locations.items) |l| {
            a.free(l.name);
            a.free(l.kind);
            if (l.county) |c| a.free(c);
            a.free(l.source);
            if (l.verified_at) |v| a.free(v);
        }
        self.locations.deinit(a);
        for (self.facilities.items) |f| {
            a.free(f.name);
            a.free(f.kind);
            if (f.county) |c| a.free(c);
            if (f.city) |c| a.free(c);
            a.free(f.source);
            if (f.verified_at) |v| a.free(v);
        }
        self.facilities.deinit(a);
        for (self.statistics.items) |s| {
            a.free(s.key);
            a.free(s.unit);
            a.free(s.period);
            a.free(s.source);
            if (s.verified_at) |v| a.free(v);
        }
        self.statistics.deinit(a);
        for (self.health.items) |h| {
            a.free(h.source_id);
            if (h.last_error) |e| a.free(e);
        }
        self.health.deinit(a);
        for (self.aggregates.items) |ag| {
            a.free(ag.year_month);
            a.free(ag.topic);
        }
        self.aggregates.deinit(a);
    }

    pub fn asKnowledge(self: *MemoryKnowledge) KnowledgeStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = KnowledgeStore.VTable{
        .recordEntities = recordEntities,
        .upsertEventForDoc = upsertEventForDoc,
        .listEvents = listEvents,
        .recordSourceHealth = recordSourceHealth,
        .getSourceHealth = getSourceHealth,
        .upsertLocation = upsertLocation,
        .upsertFacility = upsertFacility,
        .upsertStatistic = upsertStatistic,
        .listLocations = listLocations,
        .listFacilities = listFacilities,
        .listStatistics = listStatistics,
        .recordMonthlyAggregate = recordMonthlyAggregate,
        .listMonthlyAggregates = listMonthlyAggregates,
        .recomputeEventCounts = recomputeEventCounts,
        .counts = counts,
        .deinit = deinitErased,
    };

    fn bumpEntity(self: *MemoryKnowledge, name: []const u8, kind: []const u8, ts: i64) !void {
        for (self.entities.items) |*e| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.kind, kind)) {
                e.doc_count += 1;
                return;
            }
        }
        try self.entities.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .kind = try self.alloc.dupe(u8, kind),
            .doc_count = 1,
            .first_seen = ts,
        });
    }

    fn bumpTopic(self: *MemoryKnowledge, name: []const u8) !void {
        for (self.topics.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) {
                t.doc_count += 1;
                return;
            }
        }
        try self.topics.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .doc_count = 1,
        });
    }

    fn recordEntities(ptr: *anyopaque, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        const ts = docTs(doc);
        for (ent.counties) |c| try self.bumpEntity(c, "county", ts);
        for (ent.cities) |c| try self.bumpEntity(c, "city", ts);
        for (ent.organizations) |o| try self.bumpEntity(o, "organization", ts);
        for (ent.people) |p| try self.bumpEntity(p, "person", ts);
        for (ent.topics) |t| try self.bumpTopic(t);
    }

    fn upsertEventForDoc(ptr: *anyopaque, alloc: std.mem.Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror![]u8 {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        const ts = docTs(doc);
        const topic = primaryTopic(ent);
        const title_lower = try entities_mod.lowerCopy(alloc, doc.title);
        // Most recent open event first: same topic (when named) or a
        // trigram-similar title, within 72h of the event window.
        var i: usize = self.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.events.items[i];
            const same_topic = topic.len > 0 and std.mem.eql(u8, topic, e.topic);
            const e_title_lower = try entities_mod.lowerCopy(alloc, e.title);
            const title_sim = try fuzzy.similarity(alloc, title_lower, e_title_lower);
            const time_close = ts >= e.first_seen - 72 * 3600 and ts <= e.last_seen + 72 * 3600;
            if ((same_topic or title_sim >= 0.5) and time_close) {
                e.doc_count += 1;
                if (ts < e.first_seen) e.first_seen = ts;
                if (ts > e.last_seen) e.last_seen = ts;
                // Concise event summary (3.5): an event that has none
                // takes the joining document's summary, so the summary
                // fills in as coverage arrives.
                if (e.summary == null) {
                    if (doc.summary) |s| {
                        e.summary = try self.alloc.dupe(u8, s);
                    }
                }
                try self.bumpEventSource(e.id, doc.source_id);
                return alloc.dupe(u8, e.id);
            }
        }
        const id = try alloc.dupe(u8, doc.content_hash);
        try self.events.append(self.alloc, .{
            .id = try self.alloc.dupe(u8, id),
            .title = try self.alloc.dupe(u8, doc.title),
            .topic = try self.alloc.dupe(u8, topic),
            .first_seen = ts,
            .last_seen = ts,
            .doc_count = 1,
            .summary = if (doc.summary) |s| try self.alloc.dupe(u8, s) else null,
        });
        try self.bumpEventSource(id, doc.source_id);
        return id;
    }

    fn bumpEventSource(self: *MemoryKnowledge, event_id: []const u8, source_id: []const u8) !void {
        for (self.event_sources.items) |*es| {
            if (std.mem.eql(u8, es.event_id, event_id) and std.mem.eql(u8, es.source_id, source_id)) {
                es.doc_count += 1;
                return;
            }
        }
        try self.event_sources.append(self.alloc, .{
            .event_id = try self.alloc.dupe(u8, event_id),
            .source_id = try self.alloc.dupe(u8, source_id),
            .doc_count = 1,
        });
    }

    fn listEvents(ptr: *anyopaque, alloc: std.mem.Allocator, limit: usize) anyerror![]KnowledgeEvent {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        const n = @min(limit, self.events.items.len);
        var out: std.ArrayList(KnowledgeEvent) = .empty;
        // Newest first.
        var i: usize = self.events.items.len;
        while (i > 0 and out.items.len < n) {
            i -= 1;
            const e = self.events.items[i];
            try out.append(alloc, .{
                .id = try alloc.dupe(u8, e.id),
                .title = try alloc.dupe(u8, e.title),
                .topic = try alloc.dupe(u8, e.topic),
                .first_seen = e.first_seen,
                .last_seen = e.last_seen,
                .doc_count = e.doc_count,
                .summary = if (e.summary) |s| try alloc.dupe(u8, s) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordSourceHealth(ptr: *anyopaque, alloc: std.mem.Allocator, health: SourceHealth) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.health.items) |*h| {
            if (std.mem.eql(u8, h.source_id, health.source_id)) {
                if (h.last_error) |e| self.alloc.free(e);
                h.* = .{
                    .source_id = h.source_id,
                    .last_run_at = health.last_run_at,
                    .last_success_at = health.last_success_at,
                    .last_error = if (health.last_error) |e| try self.alloc.dupe(u8, e) else null,
                    .consecutive_failures = health.consecutive_failures,
                    .docs_total = health.docs_total,
                };
                return;
            }
        }
        try self.health.append(self.alloc, .{
            .source_id = try self.alloc.dupe(u8, health.source_id),
            .last_run_at = health.last_run_at,
            .last_success_at = health.last_success_at,
            .last_error = if (health.last_error) |e| try self.alloc.dupe(u8, e) else null,
            .consecutive_failures = health.consecutive_failures,
            .docs_total = health.docs_total,
        });
    }

    fn getSourceHealth(ptr: *anyopaque, alloc: std.mem.Allocator, source_id: []const u8) anyerror!?SourceHealth {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.health.items) |h| {
            if (std.mem.eql(u8, h.source_id, source_id)) {
                return .{
                    .source_id = try alloc.dupe(u8, h.source_id),
                    .last_run_at = h.last_run_at,
                    .last_success_at = h.last_success_at,
                    .last_error = if (h.last_error) |e| try alloc.dupe(u8, e) else null,
                    .consecutive_failures = h.consecutive_failures,
                    .docs_total = h.docs_total,
                };
            }
        }
        return null;
    }

    fn upsertLocation(ptr: *anyopaque, alloc: std.mem.Allocator, row: LocationRow) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.locations.items) |*l| {
            // Identity is (name, kind, county): Liberia has same-named
            // districts in different counties (Commonwealth x3).
            const county_eq = if (l.county) |a|
                if (row.county) |b| std.mem.eql(u8, a, b) else false
            else
                row.county == null;
            if (std.mem.eql(u8, l.name, row.name) and std.mem.eql(u8, l.kind, row.kind) and county_eq) {
                l.* = .{
                    .name = l.name,
                    .kind = l.kind,
                    .county = if (row.county) |c| try self.alloc.dupe(u8, c) else l.county,
                    .lat = row.lat orelse l.lat,
                    .lon = row.lon orelse l.lon,
                    .population = row.population orelse l.population,
                    .source = try self.alloc.dupe(u8, row.source),
                    .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else l.verified_at,
                };
                return;
            }
        }
        try self.locations.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, row.name),
            .kind = try self.alloc.dupe(u8, row.kind),
            .county = if (row.county) |c| try self.alloc.dupe(u8, c) else null,
            .lat = row.lat,
            .lon = row.lon,
            .population = row.population,
            .source = try self.alloc.dupe(u8, row.source),
            .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else null,
        });
    }

    fn upsertFacility(ptr: *anyopaque, alloc: std.mem.Allocator, row: FacilityRow) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.facilities.items) |*f| {
            const same_county = if (f.county) |fc| (if (row.county) |rc| std.mem.eql(u8, fc, rc) else false) else row.county == null;
            if (std.mem.eql(u8, f.name, row.name) and std.mem.eql(u8, f.kind, row.kind) and same_county) {
                f.* = .{
                    .name = f.name,
                    .kind = f.kind,
                    .county = if (row.county) |c| try self.alloc.dupe(u8, c) else f.county,
                    .city = if (row.city) |c| try self.alloc.dupe(u8, c) else f.city,
                    .lat = row.lat orelse f.lat,
                    .lon = row.lon orelse f.lon,
                    .source = try self.alloc.dupe(u8, row.source),
                    .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else f.verified_at,
                };
                return;
            }
        }
        try self.facilities.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, row.name),
            .kind = try self.alloc.dupe(u8, row.kind),
            .county = if (row.county) |c| try self.alloc.dupe(u8, c) else null,
            .city = if (row.city) |c| try self.alloc.dupe(u8, c) else null,
            .lat = row.lat,
            .lon = row.lon,
            .source = try self.alloc.dupe(u8, row.source),
            .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else null,
        });
    }

    fn upsertStatistic(ptr: *anyopaque, alloc: std.mem.Allocator, row: StatisticRow) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.statistics.items) |*s| {
            if (std.mem.eql(u8, s.key, row.key)) {
                s.* = .{
                    .key = s.key,
                    .value = row.value,
                    .unit = try self.alloc.dupe(u8, row.unit),
                    .period = try self.alloc.dupe(u8, row.period),
                    .source = try self.alloc.dupe(u8, row.source),
                    .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else s.verified_at,
                };
                return;
            }
        }
        try self.statistics.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, row.key),
            .value = row.value,
            .unit = try self.alloc.dupe(u8, row.unit),
            .period = try self.alloc.dupe(u8, row.period),
            .source = try self.alloc.dupe(u8, row.source),
            .verified_at = if (row.verified_at) |v| try self.alloc.dupe(u8, v) else null,
        });
    }

    fn listLocations(ptr: *anyopaque, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) anyerror![]LocationRow {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(LocationRow) = .empty;
        for (self.locations.items) |l| {
            if (out.items.len >= limit) break;
            if (kind) |k| {
                if (!std.mem.eql(u8, l.kind, k)) continue;
            }
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, l.name),
                .kind = try alloc.dupe(u8, l.kind),
                .county = if (l.county) |c| try alloc.dupe(u8, c) else null,
                .lat = l.lat,
                .lon = l.lon,
                .population = l.population,
                .source = try alloc.dupe(u8, l.source),
                .verified_at = if (l.verified_at) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn listFacilities(ptr: *anyopaque, alloc: std.mem.Allocator, kind: ?[]const u8, limit: usize) anyerror![]FacilityRow {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(FacilityRow) = .empty;
        for (self.facilities.items) |f| {
            if (out.items.len >= limit) break;
            if (kind) |k| {
                if (!std.mem.eql(u8, f.kind, k)) continue;
            }
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, f.name),
                .kind = try alloc.dupe(u8, f.kind),
                .county = if (f.county) |c| try alloc.dupe(u8, c) else null,
                .city = if (f.city) |c| try alloc.dupe(u8, c) else null,
                .lat = f.lat,
                .lon = f.lon,
                .source = try alloc.dupe(u8, f.source),
                .verified_at = if (f.verified_at) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn listStatistics(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]StatisticRow {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(StatisticRow) = .empty;
        for (self.statistics.items) |s| {
            try out.append(alloc, .{
                .key = try alloc.dupe(u8, s.key),
                .value = s.value,
                .unit = try alloc.dupe(u8, s.unit),
                .period = try alloc.dupe(u8, s.period),
                .source = try alloc.dupe(u8, s.source),
                .verified_at = if (s.verified_at) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordMonthlyAggregate(ptr: *anyopaque, alloc: std.mem.Allocator, year_month: []const u8, topic: []const u8, count: usize) anyerror!void {
        _ = alloc;
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.aggregates.items) |*ag| {
            if (std.mem.eql(u8, ag.year_month, year_month) and std.mem.eql(u8, ag.topic, topic)) {
                ag.count = count;
                return;
            }
        }
        try self.aggregates.append(self.alloc, .{
            .year_month = try self.alloc.dupe(u8, year_month),
            .topic = try self.alloc.dupe(u8, topic),
            .count = count,
        });
    }

    fn listMonthlyAggregates(ptr: *anyopaque, alloc: std.mem.Allocator, limit: usize) anyerror![]MonthlyAggregate {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(MonthlyAggregate) = .empty;
        for (self.aggregates.items) |ag| {
            try out.append(alloc, .{
                .year_month = try alloc.dupe(u8, ag.year_month),
                .topic = try alloc.dupe(u8, ag.topic),
                .doc_count = ag.count,
            });
        }
        std.mem.sort(MonthlyAggregate, out.items, {}, struct {
            fn lt(_: void, a: MonthlyAggregate, b: MonthlyAggregate) bool {
                const cmp = std.mem.order(u8, b.year_month, a.year_month); // newest first
                if (cmp != .eq) return cmp == .lt;
                return a.doc_count > b.doc_count;
            }
        }.lt);
        if (out.items.len > limit) {
            for (out.items[limit..]) |ag| {
                alloc.free(ag.year_month);
                alloc.free(ag.topic);
            }
            out.items.len = limit;
        }
        return out.toOwnedSlice(alloc);
    }

    fn recomputeEventCounts(ptr: *anyopaque) anyerror!void {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        for (self.events.items) |*e| {
            var total: usize = 0;
            for (self.event_sources.items) |es| {
                if (std.mem.eql(u8, es.event_id, e.id)) total += es.doc_count;
            }
            e.doc_count = total;
        }
    }

    fn counts(ptr: *anyopaque) KnowledgeCounts {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        return .{
            .events = self.events.items.len,
            .entities = self.entities.items.len,
            .topics = self.topics.items.len,
            .locations = self.locations.items.len,
            .facilities = self.facilities.items.len,
            .statistics = self.statistics.items.len,
        };
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *MemoryKnowledge = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "memory knowledge: entities, events, health, seed rows" {
    var k = MemoryKnowledge.init(std.testing.allocator);
    defer k.deinit();
    const ks = k.asKnowledge();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794484800;
    const ent = try entities_mod.extract(alloc, "Fuel shortage hits Monrovia");
    const doc = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = ent.topics,
        .content_hash = "d1",
    };
    try ks.recordEntities(alloc, doc, ent);
    const ev1 = try ks.upsertEventForDoc(alloc, doc, ent);
    defer alloc.free(ev1);
    try std.testing.expectEqualStrings("d1", ev1);
    // A second similar doc joins the same event.
    var doc2 = doc;
    doc2.id = "d2";
    doc2.url = "https://example.com/2";
    doc2.content_hash = "d2";
    doc2.title = "Fuel shortage continues in Monrovia";
    doc2.text = "The fuel shortage in Monrovia continues.";
    doc2.published_at = now - 1800;
    const ev2 = try ks.upsertEventForDoc(alloc, doc2, ent);
    defer alloc.free(ev2);
    try std.testing.expectEqualStrings("d1", ev2);
    const events = try ks.listEvents(alloc, 10);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(usize, 2), events[0].doc_count);
    // An unrelated doc starts its own event.
    const ent3 = try entities_mod.extract(alloc, "Budget debate in Gbarnga");
    var doc3 = doc;
    doc3.id = "d3";
    doc3.url = "https://example.com/3";
    doc3.content_hash = "d3";
    doc3.title = "Budget debate in Gbarnga";
    doc3.text = "The budget debate in Gbarnga continues.";
    doc3.topics = ent3.topics;
    try ks.recordEntities(alloc, doc3, ent3);
    const ev3 = try ks.upsertEventForDoc(alloc, doc3, ent3);
    defer alloc.free(ev3);
    try std.testing.expectEqualStrings("d3", ev3);
    try std.testing.expectEqual(@as(usize, 2), (try ks.listEvents(alloc, 10)).len);
    // Health + seed rows + counts. Fixture values are synthetic (test
    // only) — real seeded data lives in src/seed/ with provenance.
    try ks.recordSourceHealth(alloc, .{ .source_id = "new-dawn", .last_run_at = now, .last_success_at = now, .docs_total = 2 });
    const h = (try ks.getSourceHealth(alloc, "new-dawn")).?;
    try std.testing.expectEqual(@as(usize, 2), h.docs_total);
    try ks.upsertLocation(alloc, .{ .name = "Testville", .kind = "city", .county = "Test County", .lat = 1.5, .lon = -2.5, .source = "test fixture", .verified_at = "2026-11-12" });
    try ks.upsertFacility(alloc, .{ .name = "Test Hospital", .kind = "hospital", .county = "Test County", .city = "Testville", .lat = 1.5, .lon = -2.5, .source = "test fixture", .verified_at = "2026-11-12" });
    try ks.upsertStatistic(alloc, .{ .key = "test_population", .value = 12345, .unit = "people", .period = "2022", .source = "test fixture", .verified_at = "2026-11-12" });
    const c = ks.counts();
    try std.testing.expectEqual(@as(usize, 2), c.events);
    try std.testing.expect(c.entities >= 2);
    try std.testing.expect(c.topics >= 1);
    try std.testing.expectEqual(@as(usize, 1), c.locations);
    try std.testing.expectEqual(@as(usize, 1), c.facilities);
    try std.testing.expectEqual(@as(usize, 1), c.statistics);
    const locs = try ks.listLocations(alloc, "city", 10);
    try std.testing.expectEqual(@as(usize, 1), locs.len);
    try std.testing.expectEqualStrings("Testville", locs[0].name);
    const stats = try ks.listStatistics(alloc);
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(f64, 12345), stats[0].value);
}

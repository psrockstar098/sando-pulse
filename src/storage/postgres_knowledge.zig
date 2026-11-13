//! Postgres knowledge store (Roadmap 3.4): the KnowledgeStore vtable
//! backed by the reconciled 001/004/005 tables (see migrations/
//! 005_reconcile_knowledge.sql — 001 already owned events, entities,
//! topics and locations with different shapes). Own connection + mutex
//! (separate from the document store's connection, same pattern as the
//! migration runner). All SQL is built with escapeLiteral; no user input
//! ever reaches a query unescaped.

const std = @import("std");
const types = @import("../common/types.zig");
const entities_mod = @import("../engine/entities.zig");
const fuzzy = @import("../engine/fuzzy.zig");
const knowledge = @import("knowledge.zig");
const pg = @import("postgres.zig");

const Allocator = std.mem.Allocator;

pub const PostgresKnowledge = struct {
    alloc: Allocator,
    io: std.Io,
    conninfo: []const u8,
    client: ?pg.PgClient = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: Allocator, io: std.Io, conninfo: []const u8) !PostgresKnowledge {
        var self = PostgresKnowledge{
            .alloc = alloc,
            .io = io,
            .conninfo = try alloc.dupe(u8, conninfo),
        };
        errdefer alloc.free(self.conninfo);
        self.client = try pg.PgClient.connect(alloc, io, conninfo);
        return self;
    }

    pub fn deinit(self: *PostgresKnowledge) void {
        if (self.client) |*c| c.close();
        self.alloc.free(self.conninfo);
    }

    pub fn asKnowledge(self: *PostgresKnowledge) knowledge.KnowledgeStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn ensureClient(self: *PostgresKnowledge) !*pg.PgClient {
        if (self.client == null) {
            self.client = try pg.PgClient.connect(self.alloc, self.io, self.conninfo);
        }
        return &self.client.?;
    }

    fn dropClient(self: *PostgresKnowledge) void {
        if (self.client) |*c| {
            c.close();
            self.client = null;
        }
    }

    const vtable = knowledge.KnowledgeStore.VTable{
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

    fn lock(self: *PostgresKnowledge) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *PostgresKnowledge) void {
        self.mutex.unlock(self.io);
    }

    fn execLocked(self: *PostgresKnowledge, alloc: Allocator, sql: []const u8) !void {
        const client = self.ensureClient() catch |err| return err;
        client.exec(alloc, sql) catch |err| {
            self.dropClient();
            return err;
        };
    }

    fn queryLocked(self: *PostgresKnowledge, alloc: Allocator, sql: []const u8) !pg.QueryResult {
        const client = self.ensureClient() catch |err| return err;
        return client.query(alloc, sql) catch |err| {
            self.dropClient();
            return err;
        };
    }

    fn tsLit(alloc: Allocator, ts: i64) ![]u8 {
        return std.fmt.allocPrint(alloc, "to_timestamp({d})", .{ts});
    }

    fn optLit(alloc: Allocator, v: ?[]const u8) ![]u8 {
        if (v) |s| return pg.escapeLiteral(alloc, s);
        return alloc.dupe(u8, "NULL");
    }

    fn optFloat(alloc: Allocator, v: ?f64) ![]u8 {
        if (v) |f| return std.fmt.allocPrint(alloc, "{d}", .{f});
        return alloc.dupe(u8, "NULL");
    }

    /// Deterministic row id from a name: "<kind>:<slug>" — e.g.
    /// "city:monrovia". Lowercase alphanumerics, separators become "_".
    /// The kind prefix keeps two kinds with the same slug distinct.
    /// Location id: kind:name[:county]. The county suffix is part of
    /// the identity — Liberia has same-named districts in different
    /// counties (Commonwealth in Grand Bassa, Grand Cape Mount and
    /// Montserrado). Counties themselves have no county field, so
    /// their ids are unchanged (county:bomi) and match migration 007's
    /// rename of the 001 seed ids.
    fn slugId(alloc: Allocator, kind: []const u8, name: []const u8, county: ?[]const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, kind);
        try out.append(alloc, ':');
        for (name) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try out.append(alloc, std.ascii.toLower(c));
            } else if (c == ' ' or c == '-' or c == '_') {
                try out.append(alloc, '_');
            }
        }
        if (county) |co| {
            try out.append(alloc, ':');
            for (co) |c| {
                if (std.ascii.isAlphanumeric(c)) {
                    try out.append(alloc, std.ascii.toLower(c));
                } else if (c == ' ' or c == '-' or c == '_') {
                    try out.append(alloc, '_');
                }
            }
        }
        return out.toOwnedSlice(alloc);
    }

    fn bumpEntityLocked(self: *PostgresKnowledge, alloc: Allocator, name: []const u8, kind: []const u8, ts: i64) !void {
        const id = try slugId(alloc, kind, name, null);
        defer alloc.free(id);
        const esc_id = try pg.escapeLiteral(alloc, id);
        defer alloc.free(esc_id);
        const esc_name = try pg.escapeLiteral(alloc, name);
        defer alloc.free(esc_name);
        const esc_kind = try pg.escapeLiteral(alloc, kind);
        defer alloc.free(esc_kind);
        const ts_s = try tsLit(alloc, ts);
        defer alloc.free(ts_s);
        // 001's UNIQUE is (kind, name) — the conflict target must match.
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO entities (id, name, kind, first_seen, doc_count)
            \\VALUES ({s}, {s}, {s}, {s}, 1)
            \\ON CONFLICT (kind, name) DO UPDATE SET
            \\  doc_count = entities.doc_count + 1,
            \\  first_seen = LEAST(entities.first_seen, EXCLUDED.first_seen)
        , .{ esc_id, esc_name, esc_kind, ts_s });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn recordEntities(ptr: *anyopaque, alloc: Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const ts = knowledge.docTs(doc);
        for (ent.counties) |c| try self.bumpEntityLocked(alloc, c, "county", ts);
        for (ent.cities) |c| try self.bumpEntityLocked(alloc, c, "city", ts);
        for (ent.organizations) |o| try self.bumpEntityLocked(alloc, o, "organization", ts);
        for (ent.people) |p| try self.bumpEntityLocked(alloc, p, "person", ts);
        for (ent.topics) |t| {
            const esc = try pg.escapeLiteral(alloc, t);
            defer alloc.free(esc);
            // 001's topics: id is the name itself (seed rows do this).
            const sql = try std.fmt.allocPrint(alloc,
                \\INSERT INTO topics (id, name, doc_count) VALUES ({s}, {s}, 1)
                \\ON CONFLICT (name) DO UPDATE SET doc_count = topics.doc_count + 1
            , .{ esc, esc });
            defer alloc.free(sql);
            try self.execLocked(alloc, sql);
        }
    }

    fn upsertEventForDoc(ptr: *anyopaque, alloc: Allocator, doc: types.Document, ent: entities_mod.Entities) anyerror![]u8 {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const ts = knowledge.docTs(doc);
        const topic = knowledge.primaryTopic(ent);
        // Recent events with the same topic (when named) for the title check.
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc,
            \\SELECT id, title FROM events WHERE last_seen_at >=
        );
        const from_s = try tsLit(alloc, ts - 72 * 3600);
        defer alloc.free(from_s);
        try sql.appendSlice(alloc, from_s);
        try sql.appendSlice(alloc, " AND first_seen_at <= ");
        const to_s = try tsLit(alloc, ts + 72 * 3600);
        defer alloc.free(to_s);
        try sql.appendSlice(alloc, to_s);
        if (topic.len > 0) {
            try sql.appendSlice(alloc, " AND topic = ");
            const esc_topic = try pg.escapeLiteral(alloc, topic);
            defer alloc.free(esc_topic);
            try sql.appendSlice(alloc, esc_topic);
        }
        try sql.appendSlice(alloc, " ORDER BY last_seen_at DESC LIMIT 5");
        var res = try self.queryLocked(alloc, sql.items);
        defer res.deinit(alloc);
        const title_lower = try entities_mod.lowerCopy(alloc, doc.title);
        var matched_id: ?[]const u8 = null;
        for (res.rows) |row| {
            const cand_title = row.cols[1] orelse continue;
            const cand_lower = try entities_mod.lowerCopy(alloc, cand_title);
            const sim = try fuzzy.similarity(alloc, title_lower, cand_lower);
            const cand_topic_match = topic.len > 0; // SQL already filtered by topic
            // Same topic (SQL filter) OR title similar >= 0.5, mirroring
            // the memory implementation's rule.
            if (cand_topic_match or sim >= 0.5) {
                matched_id = row.cols[0];
                break;
            }
        }
        const esc_id = try pg.escapeLiteral(alloc, doc.content_hash);
        defer alloc.free(esc_id);
        // 001's event_sources links events to DOCUMENTS (evidence). The
        // document row must already exist (the pipeline inserts the
        // document before recording knowledge); the FK enforces it.
        const esc_doc_id = try pg.escapeLiteral(alloc, doc.id);
        defer alloc.free(esc_doc_id);
        if (matched_id) |mid| {
            const esc_mid = try pg.escapeLiteral(alloc, mid);
            defer alloc.free(esc_mid);
            // Link first: the source_count recompute below counts it.
            const link = try std.fmt.allocPrint(alloc,
                \\INSERT INTO event_sources (event_id, document_id)
                \\VALUES ({s}, {s})
                \\ON CONFLICT DO NOTHING
            , .{ esc_mid, esc_doc_id });
            defer alloc.free(link);
            try self.execLocked(alloc, link);
            const upd = try std.fmt.allocPrint(alloc,
                \\UPDATE events SET doc_count = doc_count + 1,
                \\  first_seen_at = LEAST(first_seen_at, {s}),
                \\  last_seen_at = GREATEST(last_seen_at, {s}),
                \\  summary = COALESCE(summary, {s}),
                \\  source_count = (SELECT count(DISTINCT d.source_id)
                \\    FROM event_sources es JOIN documents d ON d.id = es.document_id
                \\    WHERE es.event_id = events.id)
                \\WHERE id = {s}
            , .{ try tsLit(alloc, ts), try tsLit(alloc, ts), try optLit(alloc, doc.summary), esc_mid });
            defer alloc.free(upd);
            try self.execLocked(alloc, upd);
            return alloc.dupe(u8, mid);
        }
        // New event: id is the first document's content hash.
        // `category` mirrors `topic` (001's design); source_count is 1
        // (one document, one source, so far).
        const esc_title = try pg.escapeLiteral(alloc, doc.title);
        defer alloc.free(esc_title);
        const esc_topic = try pg.escapeLiteral(alloc, topic);
        defer alloc.free(esc_topic);
        const esc_summary = try optLit(alloc, doc.summary);
        defer alloc.free(esc_summary);
        const ins = try std.fmt.allocPrint(alloc,
            \\INSERT INTO events (id, title, category, topic, first_seen_at, last_seen_at, doc_count, summary, source_count)
            \\VALUES ({s}, {s}, {s}, {s}, {s}, {s}, 1, {s}, 1)
            \\ON CONFLICT (id) DO NOTHING
        , .{ esc_id, esc_title, esc_topic, esc_topic, try tsLit(alloc, ts), try tsLit(alloc, ts), esc_summary });
        defer alloc.free(ins);
        try self.execLocked(alloc, ins);
        const link = try std.fmt.allocPrint(alloc,
            \\INSERT INTO event_sources (event_id, document_id)
            \\VALUES ({s}, {s})
            \\ON CONFLICT DO NOTHING
        , .{ esc_id, esc_doc_id });
        defer alloc.free(link);
        try self.execLocked(alloc, link);
        return alloc.dupe(u8, doc.content_hash);
    }

    fn listEvents(ptr: *anyopaque, alloc: Allocator, limit: usize) anyerror![]knowledge.KnowledgeEvent {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const sql = try std.fmt.allocPrint(alloc,
            \\SELECT id, title, topic,
            \\  extract(epoch from first_seen_at)::bigint,
            \\  extract(epoch from last_seen_at)::bigint,
            \\  doc_count, summary FROM events
            \\ORDER BY last_seen_at DESC LIMIT {d}
        , .{@min(limit, 100)});
        defer alloc.free(sql);
        var res = try self.queryLocked(alloc, sql);
        defer res.deinit(alloc);
        var out: std.ArrayList(knowledge.KnowledgeEvent) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 7) return error.ProtocolError;
            const c = row.cols;
            try out.append(alloc, .{
                .id = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
                .title = try alloc.dupe(u8, c[1] orelse return error.ProtocolError),
                .topic = try alloc.dupe(u8, c[2] orelse ""),
                .first_seen = try std.fmt.parseInt(i64, c[3] orelse return error.ProtocolError, 10),
                .last_seen = try std.fmt.parseInt(i64, c[4] orelse return error.ProtocolError, 10),
                .doc_count = try std.fmt.parseInt(usize, c[5] orelse return error.ProtocolError, 10),
                .summary = if (c[6]) |s| try alloc.dupe(u8, s) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordSourceHealth(ptr: *anyopaque, alloc: Allocator, health: knowledge.SourceHealth) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const esc_id = try pg.escapeLiteral(alloc, health.source_id);
        defer alloc.free(esc_id);
        const run_s = if (health.last_run_at) |t| try tsLit(alloc, t) else try alloc.dupe(u8, "NULL");
        defer alloc.free(run_s);
        const ok_s = if (health.last_success_at) |t| try tsLit(alloc, t) else try alloc.dupe(u8, "NULL");
        defer alloc.free(ok_s);
        const err_s = try optLit(alloc, health.last_error);
        defer alloc.free(err_s);
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO source_health (source_id, last_run_at, last_success_at, last_error, consecutive_failures, docs_total, updated_at)
            \\VALUES ({s}, {s}, {s}, {s}, {d}, {d}, now())
            \\ON CONFLICT (source_id) DO UPDATE SET
            \\  last_run_at = EXCLUDED.last_run_at,
            \\  last_success_at = EXCLUDED.last_success_at,
            \\  last_error = EXCLUDED.last_error,
            \\  consecutive_failures = EXCLUDED.consecutive_failures,
            \\  docs_total = EXCLUDED.docs_total,
            \\  updated_at = now()
        , .{ esc_id, run_s, ok_s, err_s, health.consecutive_failures, health.docs_total });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn getSourceHealth(ptr: *anyopaque, alloc: Allocator, source_id: []const u8) anyerror!?knowledge.SourceHealth {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const esc = try pg.escapeLiteral(alloc, source_id);
        defer alloc.free(esc);
        const sql = try std.fmt.allocPrint(alloc,
            \\SELECT source_id,
            \\  extract(epoch from last_run_at)::bigint,
            \\  extract(epoch from last_success_at)::bigint,
            \\  last_error, consecutive_failures, docs_total
            \\FROM source_health WHERE source_id = {s}
        , .{esc});
        defer alloc.free(sql);
        var res = try self.queryLocked(alloc, sql);
        defer res.deinit(alloc);
        if (res.rows.len == 0) return null;
        const c = res.rows[0].cols;
        if (c.len != 6) return error.ProtocolError;
        return .{
            .source_id = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
            .last_run_at = if (c[1]) |v| try std.fmt.parseInt(i64, v, 10) else null,
            .last_success_at = if (c[2]) |v| try std.fmt.parseInt(i64, v, 10) else null,
            .last_error = if (c[3]) |v| try alloc.dupe(u8, v) else null,
            .consecutive_failures = try std.fmt.parseInt(usize, c[4] orelse return error.ProtocolError, 10),
            .docs_total = try std.fmt.parseInt(usize, c[5] orelse return error.ProtocolError, 10),
        };
    }

    fn upsertLocation(ptr: *anyopaque, alloc: Allocator, row: knowledge.LocationRow) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const id = try slugId(alloc, row.kind, row.name, row.county);
        defer alloc.free(id);
        const esc_id = try pg.escapeLiteral(alloc, id);
        defer alloc.free(esc_id);
        const esc_name = try pg.escapeLiteral(alloc, row.name);
        defer alloc.free(esc_name);
        const esc_kind = try pg.escapeLiteral(alloc, row.kind);
        defer alloc.free(esc_kind);
        const esc_county = try optLit(alloc, row.county);
        defer alloc.free(esc_county);
        const lat_s = try optFloat(alloc, row.lat);
        defer alloc.free(lat_s);
        const lon_s = try optFloat(alloc, row.lon);
        defer alloc.free(lon_s);
        const esc_src = try pg.escapeLiteral(alloc, row.source);
        defer alloc.free(esc_src);
        const esc_ver = try optLit(alloc, row.verified_at);
        defer alloc.free(esc_ver);
        const pop_s = if (row.population) |p| try std.fmt.allocPrint(alloc, "{d}", .{p}) else try alloc.dupe(u8, "NULL");
        defer alloc.free(pop_s);
        // Parent link: a non-county place points at its county row when
        // the county is already seeded (counties are seeded first, so
        // this resolves for real seed data; NULL otherwise).
        const parent_s: []u8 = if (row.county != null and !std.mem.eql(u8, row.kind, "county")) blk: {
            const esc_parent_county = try pg.escapeLiteral(alloc, row.county.?);
            defer alloc.free(esc_parent_county);
            break :blk try std.fmt.allocPrint(alloc, "(SELECT id FROM locations WHERE name = {s} AND kind = 'county')", .{esc_parent_county});
        } else try alloc.dupe(u8, "NULL");
        defer alloc.free(parent_s);
        // The id carries the full identity (kind:name[:county], see
        // slugId) and migration 007 renamed the 001 county ids to
        // this form, so ON CONFLICT (id) merges with the 001 seed
        // instead of duplicating it.
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO locations (id, name, kind, county, latitude, longitude, population, source, verified_at, parent_id)
            \\VALUES ({s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s})
            \\ON CONFLICT (id) DO UPDATE SET
            \\  county = COALESCE(EXCLUDED.county, locations.county),
            \\  latitude = COALESCE(EXCLUDED.latitude, locations.latitude),
            \\  longitude = COALESCE(EXCLUDED.longitude, locations.longitude),
            \\  population = COALESCE(EXCLUDED.population, locations.population),
            \\  source = EXCLUDED.source,
            \\  verified_at = COALESCE(EXCLUDED.verified_at, locations.verified_at)
        , .{ esc_id, esc_name, esc_kind, esc_county, lat_s, lon_s, pop_s, esc_src, esc_ver, parent_s });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn upsertFacility(ptr: *anyopaque, alloc: Allocator, row: knowledge.FacilityRow) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const esc_name = try pg.escapeLiteral(alloc, row.name);
        defer alloc.free(esc_name);
        const esc_kind = try pg.escapeLiteral(alloc, row.kind);
        defer alloc.free(esc_kind);
        const esc_county = try optLit(alloc, row.county);
        defer alloc.free(esc_county);
        const esc_city = try optLit(alloc, row.city);
        defer alloc.free(esc_city);
        const lat_s = try optFloat(alloc, row.lat);
        defer alloc.free(lat_s);
        const lon_s = try optFloat(alloc, row.lon);
        defer alloc.free(lon_s);
        const esc_src = try pg.escapeLiteral(alloc, row.source);
        defer alloc.free(esc_src);
        const esc_ver = try optLit(alloc, row.verified_at);
        defer alloc.free(esc_ver);
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO facilities (name, kind, county, city, lat, lon, source, verified_at)
            \\VALUES ({s}, {s}, {s}, {s}, {s}, {s}, {s}, {s})
            \\ON CONFLICT (name, kind, county) DO UPDATE SET
            \\  city = COALESCE(EXCLUDED.city, facilities.city),
            \\  lat = COALESCE(EXCLUDED.lat, facilities.lat),
            \\  lon = COALESCE(EXCLUDED.lon, facilities.lon),
            \\  source = EXCLUDED.source,
            \\  verified_at = COALESCE(EXCLUDED.verified_at, facilities.verified_at)
        , .{ esc_name, esc_kind, esc_county, esc_city, lat_s, lon_s, esc_src, esc_ver });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn upsertStatistic(ptr: *anyopaque, alloc: Allocator, row: knowledge.StatisticRow) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const esc_key = try pg.escapeLiteral(alloc, row.key);
        defer alloc.free(esc_key);
        const esc_unit = try pg.escapeLiteral(alloc, row.unit);
        defer alloc.free(esc_unit);
        const esc_period = try pg.escapeLiteral(alloc, row.period);
        defer alloc.free(esc_period);
        const esc_src = try pg.escapeLiteral(alloc, row.source);
        defer alloc.free(esc_src);
        const esc_ver = try optLit(alloc, row.verified_at);
        defer alloc.free(esc_ver);
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO statistics (key, value, unit, period, source, verified_at)
            \\VALUES ({s}, {d}, {s}, {s}, {s}, {s})
            \\ON CONFLICT (key) DO UPDATE SET
            \\  value = EXCLUDED.value, unit = EXCLUDED.unit,
            \\  period = EXCLUDED.period, source = EXCLUDED.source,
            \\  verified_at = EXCLUDED.verified_at
        , .{ esc_key, row.value, esc_unit, esc_period, esc_src, esc_ver });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn listLocations(ptr: *anyopaque, alloc: Allocator, kind: ?[]const u8, limit: usize) anyerror![]knowledge.LocationRow {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc, "SELECT name, kind, county, latitude, longitude, population, source, verified_at::text FROM locations");
        if (kind) |k| {
            try sql.appendSlice(alloc, " WHERE kind = ");
            try sql.appendSlice(alloc, try pg.escapeLiteral(alloc, k));
        }
        const tail = try std.fmt.allocPrint(alloc, " ORDER BY name LIMIT {d}", .{@min(limit, 500)});
        defer alloc.free(tail);
        try sql.appendSlice(alloc, tail);
        var res = try self.queryLocked(alloc, sql.items);
        defer res.deinit(alloc);
        var out: std.ArrayList(knowledge.LocationRow) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 8) return error.ProtocolError;
            const c = row.cols;
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
                .kind = try alloc.dupe(u8, c[1] orelse return error.ProtocolError),
                .county = if (c[2]) |v| try alloc.dupe(u8, v) else null,
                .lat = if (c[3]) |v| try std.fmt.parseFloat(f64, v) else null,
                .lon = if (c[4]) |v| try std.fmt.parseFloat(f64, v) else null,
                .population = if (c[5]) |v| try std.fmt.parseInt(i64, v, 10) else null,
                .source = try alloc.dupe(u8, c[6] orelse ""),
                .verified_at = if (c[7]) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn listFacilities(ptr: *anyopaque, alloc: Allocator, kind: ?[]const u8, limit: usize) anyerror![]knowledge.FacilityRow {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc, "SELECT name, kind, county, city, lat, lon, source, verified_at::text FROM facilities");
        if (kind) |k| {
            try sql.appendSlice(alloc, " WHERE kind = ");
            try sql.appendSlice(alloc, try pg.escapeLiteral(alloc, k));
        }
        const tail = try std.fmt.allocPrint(alloc, " ORDER BY name LIMIT {d}", .{@min(limit, 500)});
        defer alloc.free(tail);
        try sql.appendSlice(alloc, tail);
        var res = try self.queryLocked(alloc, sql.items);
        defer res.deinit(alloc);
        var out: std.ArrayList(knowledge.FacilityRow) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 8) return error.ProtocolError;
            const c = row.cols;
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
                .kind = try alloc.dupe(u8, c[1] orelse return error.ProtocolError),
                .county = if (c[2]) |v| try alloc.dupe(u8, v) else null,
                .city = if (c[3]) |v| try alloc.dupe(u8, v) else null,
                .lat = if (c[4]) |v| try std.fmt.parseFloat(f64, v) else null,
                .lon = if (c[5]) |v| try std.fmt.parseFloat(f64, v) else null,
                .source = try alloc.dupe(u8, c[6] orelse ""),
                .verified_at = if (c[7]) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn listStatistics(ptr: *anyopaque, alloc: Allocator) anyerror![]knowledge.StatisticRow {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        var res = try self.queryLocked(alloc, "SELECT key, value, unit, period, source, verified_at::text FROM statistics ORDER BY key");
        defer res.deinit(alloc);
        var out: std.ArrayList(knowledge.StatisticRow) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 6) return error.ProtocolError;
            const c = row.cols;
            try out.append(alloc, .{
                .key = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
                .value = try std.fmt.parseFloat(f64, c[1] orelse return error.ProtocolError),
                .unit = try alloc.dupe(u8, c[2] orelse ""),
                .period = try alloc.dupe(u8, c[3] orelse ""),
                .source = try alloc.dupe(u8, c[4] orelse ""),
                .verified_at = if (c[5]) |v| try alloc.dupe(u8, v) else null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordMonthlyAggregate(ptr: *anyopaque, alloc: Allocator, year_month: []const u8, topic: []const u8, count: usize) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const esc_ym = try pg.escapeLiteral(alloc, year_month);
        defer alloc.free(esc_ym);
        const esc_topic = try pg.escapeLiteral(alloc, topic);
        defer alloc.free(esc_topic);
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO monthly_aggregates (year_month, topic, doc_count)
            \\VALUES ({s}, {s}, {d})
            \\ON CONFLICT (year_month, topic) DO UPDATE SET doc_count = EXCLUDED.doc_count
        , .{ esc_ym, esc_topic, count });
        defer alloc.free(sql);
        try self.execLocked(alloc, sql);
    }

    fn listMonthlyAggregates(ptr: *anyopaque, alloc: Allocator, limit: usize) anyerror![]knowledge.MonthlyAggregate {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const sql = try std.fmt.allocPrint(alloc,
            \\SELECT year_month, topic, doc_count FROM monthly_aggregates
            \\ORDER BY year_month DESC, doc_count DESC LIMIT {d}
        , .{@min(limit, 500)});
        defer alloc.free(sql);
        var res = try self.queryLocked(alloc, sql);
        defer res.deinit(alloc);
        var out: std.ArrayList(knowledge.MonthlyAggregate) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 3) return error.ProtocolError;
            const c = row.cols;
            try out.append(alloc, .{
                .year_month = try alloc.dupe(u8, c[0] orelse return error.ProtocolError),
                .topic = try alloc.dupe(u8, c[1] orelse return error.ProtocolError),
                .doc_count = try std.fmt.parseInt(usize, c[2] orelse return error.ProtocolError, 10),
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn recomputeEventCounts(ptr: *anyopaque) anyerror!void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        try self.execLocked(self.alloc,
            \\UPDATE events SET doc_count =
            \\  (SELECT count(*) FROM event_sources
            \\   WHERE event_sources.event_id = events.id)
        );
    }

    fn counts(ptr: *anyopaque) knowledge.KnowledgeCounts {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        var res = self.queryLocked(self.alloc,
            \\SELECT (SELECT count(*) FROM events),
            \\  (SELECT count(*) FROM entities),
            \\  (SELECT count(*) FROM topics),
            \\  (SELECT count(*) FROM locations),
            \\  (SELECT count(*) FROM facilities),
            \\  (SELECT count(*) FROM statistics)
        ) catch return .{};
        defer res.deinit(self.alloc);
        if (res.rows.len == 0 or res.rows[0].cols.len != 6) return .{};
        const c = res.rows[0].cols;
        const n = struct {
            fn p(v: ?[]const u8) usize {
                if (v) |s| return std.fmt.parseInt(usize, s, 10) catch 0;
                return 0;
            }
        }.p;
        return .{
            .events = n(c[0]),
            .entities = n(c[1]),
            .topics = n(c[2]),
            .locations = n(c[3]),
            .facilities = n(c[4]),
            .statistics = n(c[5]),
        };
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *PostgresKnowledge = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "postgres knowledge: live" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try @import("postgres.zig").getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);
    try pg.runMigrations(alloc, io, url, "/home/hatch/workspace/pulse/migrations");
    // Rerun-safe: the event/documents from a previous run (or an
    // interrupted one) are removed first and again at the end, so the
    // doc_count assertions hold on every run.
    const cleanup_sql = "DELETE FROM event_sources WHERE event_id = 'kt1-hash-test'; " ++
        "DELETE FROM events WHERE id = 'kt1-hash-test'; " ++
        "DELETE FROM documents WHERE id IN ('kt1', 'kt2');";
    var cc = try pg.PgClient.connect(alloc, io, url);
    defer cc.close();
    try cc.exec(alloc, cleanup_sql);
    defer cc.exec(alloc, cleanup_sql) catch {};
    var store = try pg.PostgresStore.init(alloc, io, url);
    defer store.deinit();
    var k = try PostgresKnowledge.init(alloc, io, url);
    defer k.deinit();
    const ks = k.asKnowledge();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // Synthetic timestamp (2023-11-14): far from real worker data, so
    // the 72h event window never absorbs a real ingested event.
    const now: i64 = 1700000000;
    const ent = try entities_mod.extract(a, "Fuel shortage hits Monrovia");
    const doc = types.Document{
        .id = "kt1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/kt1",
        .text = "Fuel stations in Monrovia report long queues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = ent.topics,
        .content_hash = "kt1-hash-test",
    };
    // The document row must exist first: event_sources references it.
    try store.insertDocument(doc);
    try ks.recordEntities(a, doc, ent);
    const ev1 = try ks.upsertEventForDoc(a, doc, ent);
    defer a.free(ev1);
    try std.testing.expectEqualStrings("kt1-hash-test", ev1);
    var doc2 = doc;
    doc2.id = "kt2";
    doc2.url = "https://example.com/kt2";
    doc2.content_hash = "kt2-hash-test";
    doc2.title = "Fuel shortage continues in Monrovia";
    doc2.text = "The fuel shortage in Monrovia continues.";
    doc2.published_at = now - 1800;
    try store.insertDocument(doc2);
    const ev2 = try ks.upsertEventForDoc(a, doc2, ent);
    defer a.free(ev2);
    try std.testing.expectEqualStrings("kt1-hash-test", ev2);
    const events = try ks.listEvents(a, 10);
    var found = false;
    for (events) |e| {
        if (std.mem.eql(u8, e.id, "kt1-hash-test")) {
            found = true;
            try std.testing.expectEqual(@as(usize, 2), e.doc_count);
        }
    }
    try std.testing.expect(found);
    try ks.recordSourceHealth(a, .{ .source_id = "new-dawn", .last_run_at = now, .last_success_at = now, .docs_total = 2 });
    const h = (try ks.getSourceHealth(a, "new-dawn")).?;
    try std.testing.expectEqual(@as(usize, 2), h.docs_total);
    try ks.upsertLocation(a, .{ .name = "Testville", .kind = "city", .county = "Test County", .lat = 1.5, .lon = -2.5, .source = "test fixture", .verified_at = "2026-11-12" });
    try ks.upsertFacility(a, .{ .name = "Test Hospital", .kind = "hospital", .county = "Test County", .city = "Testville", .source = "test fixture", .verified_at = "2026-11-12" });
    try ks.upsertStatistic(a, .{ .key = "test_population", .value = 12345, .unit = "people", .period = "2022", .source = "test fixture", .verified_at = "2026-11-12" });
    try ks.recordMonthlyAggregate(a, "2026-11", "energy", 7);
    const locs = try ks.listLocations(a, "city", 10);
    var saw_testville = false;
    for (locs) |l| {
        if (std.mem.eql(u8, l.name, "Testville")) saw_testville = true;
    }
    try std.testing.expect(saw_testville);
    const stats = try ks.listStatistics(a);
    var saw_stat = false;
    for (stats) |s| {
        if (std.mem.eql(u8, s.key, "test_population")) saw_stat = true;
    }
    try std.testing.expect(saw_stat);
    const c = ks.counts();
    try std.testing.expect(c.events >= 1);
    try std.testing.expect(c.entities >= 1);
    try std.testing.expect(c.locations >= 1);
    try std.testing.expect(c.statistics >= 1);
}

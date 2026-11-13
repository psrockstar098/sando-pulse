//! In-memory repository: the dev default and the fallback when no
//! DATABASE_URL is configured. Owns deep copies of every document it stores.
//! Single-threaded in Phase 1 (same as the server); no internal locking.
//! Implements the repository.Repository vtable.

const std = @import("std");
const types = @import("../common/types.zig");
const repository = @import("repository.zig");
const entities = @import("../engine/entities.zig");
const fuzzy = @import("../engine/fuzzy.zig");
const geo = @import("../engine/geo.zig");

pub const MemoryStore = struct {
    alloc: std.mem.Allocator,
    docs: std.ArrayList(types.Document),

    pub fn init(alloc: std.mem.Allocator) MemoryStore {
        return .{ .alloc = alloc, .docs = .empty };
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.docs.items) |d| freeDocument(self.alloc, d);
        self.docs.deinit(self.alloc);
    }

    pub fn asRepository(self: *MemoryStore) repository.Repository {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = repository.Repository.VTable{
        .insertDocument = insertDocument,
        .search = search,
        .countDocuments = countDocuments,
        .countBySource = countBySource,
        .scanDocuments = scanDocuments,
        .getDocument = getDocument,
        .deleteDocuments = deleteDocuments,
        .analyze = analyze,
        .deinit = deinitErased,
    };

    fn freeDocument(alloc: std.mem.Allocator, d: types.Document) void {
        alloc.free(d.id);
        alloc.free(d.source_id);
        alloc.free(d.source_name);
        alloc.free(d.source_url);
        alloc.free(d.title);
        alloc.free(d.url);
        alloc.free(d.text);
        for (d.topics) |t| alloc.free(t);
        alloc.free(d.topics);
        alloc.free(d.content_hash);
        if (d.embedding) |e| alloc.free(e);
        if (d.summary) |s| alloc.free(s);
        alloc.free(d.lang);
    }

    fn dupeDocument(alloc: std.mem.Allocator, d: types.Document) !types.Document {
        var topics: std.ArrayList([]const u8) = .empty;
        for (d.topics) |t| try topics.append(alloc, try alloc.dupe(u8, t));
        return .{
            .id = try alloc.dupe(u8, d.id),
            .source_id = try alloc.dupe(u8, d.source_id),
            .source_name = try alloc.dupe(u8, d.source_name),
            .source_url = try alloc.dupe(u8, d.source_url),
            .title = try alloc.dupe(u8, d.title),
            .url = try alloc.dupe(u8, d.url),
            .text = try alloc.dupe(u8, d.text),
            .published_at = d.published_at,
            .fetched_at = d.fetched_at,
            .reliability = d.reliability,
            .topics = try topics.toOwnedSlice(alloc),
            .content_hash = try alloc.dupe(u8, d.content_hash),
            .lat = d.lat,
            .lon = d.lon,
            .embedding = if (d.embedding) |e| try alloc.dupe(f32, e) else null,
            .summary = if (d.summary) |s| try alloc.dupe(u8, s) else null,
            .lang = try alloc.dupe(u8, d.lang),
        };
    }

    fn insertDocument(ptr: *anyopaque, doc: types.Document) anyerror!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        for (self.docs.items) |existing| {
            if (std.mem.eql(u8, existing.id, doc.id)) return; // idempotent
        }
        const owned = try dupeDocument(self.alloc, doc);
        try self.docs.append(self.alloc, owned);
    }

    /// True when `term` is trigram-similar (>= 0.5) to any word in `text`.
    /// Used for fuzzy matching; exact-substring matches are checked first
    /// by the caller, so this only runs on the typo path.
    fn fuzzyTermMatches(alloc: std.mem.Allocator, term: []const u8, text_lower: []const u8) !bool {
        var it = std.mem.tokenizeAny(u8, text_lower, " \t\n\r.,;:!?\"'()[]{}<>/-_");
        while (it.next()) |word| {
            if (word.len < 3) continue;
            if (try fuzzy.isSimilar(alloc, term, word, 0.5)) return true;
        }
        return false;
    }

    fn docMatches(alloc: std.mem.Allocator, doc: types.Document, q: types.SearchQuery) !bool {
        // Time window: a document's date is published_at, falling back to
        // fetched_at for manually ingested docs (published_at null).
        // The window is half-open [from_ts, to_ts).
        if (q.from_ts != null or q.to_ts != null) {
            const ts = doc.published_at orelse doc.fetched_at;
            if (q.from_ts) |from| {
                if (ts < from) return false;
            }
            if (q.to_ts) |to| {
                if (ts >= to) return false;
            }
        }
        // Geo radius: only documents with coordinates can match, and they
        // must sit within radius_km of the filter point (haversine).
        if (q.geo) |g| {
            const lat = doc.lat orelse return false;
            const lon = doc.lon orelse return false;
            if (geo.haversineKm(g.lat, g.lon, lat, lon) > g.radius_km) return false;
        }
        // Term match: any term in title or text. With q.fuzzy, a term also
        // matches a trigram-similar word (typo-tolerant, threshold 0.5).
        var term_ok = q.terms.len == 0;
        if (q.terms.len > 0) {
            const title_lower = try entities.lowerCopy(alloc, doc.title);
            const text_lower = try entities.lowerCopy(alloc, doc.text);
            for (q.terms) |t| {
                if (std.mem.indexOf(u8, title_lower, t) != null or std.mem.indexOf(u8, text_lower, t) != null) {
                    term_ok = true;
                    break;
                }
                if (q.fuzzy) {
                    if (try fuzzyTermMatches(alloc, t, title_lower) or try fuzzyTermMatches(alloc, t, text_lower)) {
                        term_ok = true;
                        break;
                    }
                }
            }
        }
        if (!term_ok) return false;
        // Entity/topic filters: at least one must match when filters are set.
        const filter_total = q.counties.len + q.organizations.len + q.topics.len;
        if (filter_total == 0) return true;
        const hay = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
        const hay_lower = try entities.lowerCopy(alloc, hay);
        for (q.counties) |c| {
            const cl = try entities.lowerCopy(alloc, c);
            if (entities.containsWord(hay_lower, cl)) return true;
        }
        for (q.organizations) |o| {
            const ol = try entities.lowerCopy(alloc, o);
            if (entities.containsWord(hay_lower, ol)) return true;
        }
        for (q.topics) |t| {
            for (doc.topics) |dt| {
                if (std.mem.eql(u8, dt, t)) return true;
            }
        }
        return false;
    }

    fn search(ptr: *anyopaque, alloc: std.mem.Allocator, q: types.SearchQuery) anyerror![]types.Document {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(types.Document) = .empty;
        for (self.docs.items) |doc| {
            if (out.items.len >= q.limit) break;
            if (try docMatches(alloc, doc, q)) {
                try out.append(alloc, try dupeDocument(alloc, doc));
            }
        }
        return out.toOwnedSlice(alloc);
    }

    fn getDocument(ptr: *anyopaque, alloc: std.mem.Allocator, id: []const u8) anyerror!?types.Document {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        for (self.docs.items) |doc| {
            if (std.mem.eql(u8, doc.id, id)) return try dupeDocument(alloc, doc);
        }
        return null;
    }

    fn countDocuments(ptr: *anyopaque) usize {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        return self.docs.items.len;
    }

    fn countBySource(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]types.SourceCount {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var map = std.StringHashMap(usize).init(alloc);
        defer map.deinit();
        for (self.docs.items) |doc| {
            const e = try map.getOrPut(doc.source_id);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
        var out: std.ArrayList(types.SourceCount) = .empty;
        var it = map.iterator();
        while (it.next()) |kv| {
            try out.append(alloc, .{
                .source_id = try alloc.dupe(u8, kv.key_ptr.*),
                .count = kv.value_ptr.*,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn scanDocuments(ptr: *anyopaque, alloc: std.mem.Allocator, before_ts: ?i64, limit: usize) anyerror![]types.Document {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(types.Document) = .empty;
        for (self.docs.items) |doc| {
            if (before_ts) |cut| {
                if (doc.fetched_at > cut) continue;
            }
            try out.append(alloc, try dupeDocument(alloc, doc));
        }
        std.mem.sort(types.Document, out.items, {}, struct {
            fn lt(_: void, a: types.Document, b: types.Document) bool {
                return a.fetched_at > b.fetched_at;
            }
        }.lt);
        if (out.items.len > limit) {
            for (out.items[limit..]) |d| freeDocument(alloc, d);
            out.items.len = limit;
        }
        return out.toOwnedSlice(alloc);
    }

    fn deleteDocuments(ptr: *anyopaque, ids: []const []const u8) anyerror!usize {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.docs.items.len) {
            var found = false;
            for (ids) |id| {
                if (std.mem.eql(u8, self.docs.items[i].id, id)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                const d = self.docs.orderedRemove(i);
                freeDocument(self.alloc, d);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// No planner statistics to refresh on the memory store.
    fn analyze(_: *anyopaque, _: std.mem.Allocator) anyerror!void {}

    fn deinitErased(ptr: *anyopaque) void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "memory store insert is idempotent and search finds terms" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    const doc = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations report long queues.",
        .published_at = null,
        .fetched_at = 1794497000,
        .reliability = 0.70,
        .topics = &.{"energy"},
        .content_hash = "d1",
    };
    try repo.insertDocument(doc);
    try repo.insertDocument(doc);
    try std.testing.expectEqual(@as(usize, 1), repo.countDocuments());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const found = try repo.search(alloc, .{ .terms = &.{"fuel"}, .limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Fuel shortage hits Monrovia", found[0].title);
    const none = try repo.search(alloc, .{ .terms = &.{"quantum"}, .limit = 10 });
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const counts = try repo.countBySource(alloc);
    try std.testing.expectEqual(@as(usize, 1), counts.len);
    try std.testing.expectEqualStrings("new-dawn", counts[0].source_id);
    try std.testing.expectEqual(@as(usize, 1), counts[0].count);
}

test "memory store applies time window, geo radius, and fuzzy terms" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    const base = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations report long queues.",
        .published_at = 1794441600 + 3600, // 2026-11-12 01:00 UTC
        .fetched_at = 1794441600 + 7200,
        .reliability = 0.70,
        .topics = &.{"energy"},
        .content_hash = "d1",
        .lat = 6.3204,
        .lon = -10.8060,
    };
    var old = base;
    old.id = "d2";
    old.url = "https://example.com/2";
    old.content_hash = "d2";
    old.title = "Budget debate in Gbarnga";
    old.text = "The budget debate continues in Gbarnga.";
    old.published_at = 1794441600 - 30 * 86400; // a month earlier
    old.lat = 6.9963;
    old.lon = -9.4709;
    try repo.insertDocument(base);
    try repo.insertDocument(old);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Time window: only the Nov 12 doc is inside [Nov 12, Nov 13).
    const today = try repo.search(alloc, .{
        .terms = &.{},
        .from_ts = 1794441600,
        .to_ts = 1794441600 + 86400,
        .limit = 10,
    });
    try std.testing.expectEqual(@as(usize, 1), today.len);
    try std.testing.expectEqualStrings("d1", today[0].id);
    // Geo radius: 50 km around Monrovia keeps d1, drops Gbarnga (~150 km).
    const near = try repo.search(alloc, .{
        .terms = &.{},
        .geo = .{ .lat = 6.3204, .lon = -10.8060, .radius_km = 50 },
        .limit = 10,
    });
    try std.testing.expectEqual(@as(usize, 1), near.len);
    try std.testing.expectEqualStrings("d1", near[0].id);
    // Fuzzy: "monrova" (typo) finds the Monrovia doc only with fuzzy on.
    const exact = try repo.search(alloc, .{ .terms = &.{"monrova"}, .limit = 10 });
    try std.testing.expectEqual(@as(usize, 0), exact.len);
    const fuzzy_q = try repo.search(alloc, .{ .terms = &.{"monrova"}, .fuzzy = true, .limit = 10 });
    try std.testing.expectEqual(@as(usize, 1), fuzzy_q.len);
    try std.testing.expectEqualStrings("d1", fuzzy_q[0].id);
}

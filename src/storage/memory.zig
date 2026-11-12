//! In-memory repository: the dev default and the fallback when no
//! DATABASE_URL is configured. Owns deep copies of every document it stores.
//! Single-threaded in Phase 1 (same as the server); no internal locking.
//! Implements the repository.Repository vtable.

const std = @import("std");
const types = @import("../common/types.zig");
const repository = @import("repository.zig");
const entities = @import("../engine/entities.zig");

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

    fn docMatches(alloc: std.mem.Allocator, doc: types.Document, q: types.SearchQuery) !bool {
        // Term match: any term in title or text.
        var term_ok = q.terms.len == 0;
        if (q.terms.len > 0) {
            const title_lower = try entities.lowerCopy(alloc, doc.title);
            const text_lower = try entities.lowerCopy(alloc, doc.text);
            for (q.terms) |t| {
                if (std.mem.indexOf(u8, title_lower, t) != null or std.mem.indexOf(u8, text_lower, t) != null) {
                    term_ok = true;
                    break;
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

//! Trust & Intelligence Engine: source history log (Phase 1).
//!
//! Bounded, append-only record of registry changes: profile creation,
//! status changes, profile updates. Every entry names the source, the
//! action, a plain-words detail, and the unix time it happened — the
//! audit trail the spec requires ("a source should be able to see why
//! its score changed, and a user should be able to see why PULSE
//! reached a conclusion"). In Phase 1 the only entries are the
//! `profile_created` records the registry seeds at boot; status
//! changes and score changes (Phase 4) will append here. Nothing is
//! ever backfilled: an entry records a change that really happened,
//! at the time it happened.

const std = @import("std");

pub const HistoryEntry = struct {
    seq: u64,
    source_id: []const u8,
    action: []const u8,
    detail: []const u8,
    at: i64, // unix seconds
};

pub const SourceHistory = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(HistoryEntry) = .empty,
    next_seq: u64 = 1,

    pub const max_entries: usize = 500;

    pub fn init(alloc: std.mem.Allocator) SourceHistory {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SourceHistory) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.source_id);
            self.alloc.free(e.action);
            self.alloc.free(e.detail);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn count(self: *const SourceHistory) usize {
        return self.entries.items.len;
    }

    /// Append one entry. Strings are duped into the log's allocator.
    /// Past the cap the oldest entry is evicted first — the log never
    /// grows without bound, and the newest entries always survive.
    pub fn record(self: *SourceHistory, source_id: []const u8, action: []const u8, detail: []const u8, at: i64) !void {
        if (self.entries.items.len >= max_entries) {
            const old = self.entries.orderedRemove(0);
            self.alloc.free(old.source_id);
            self.alloc.free(old.action);
            self.alloc.free(old.detail);
        }
        try self.entries.append(self.alloc, .{
            .seq = self.next_seq,
            .source_id = try self.alloc.dupe(u8, source_id),
            .action = try self.alloc.dupe(u8, action),
            .detail = try self.alloc.dupe(u8, detail),
            .at = at,
        });
        self.next_seq += 1;
    }

    /// Entries for one source, in insertion order (oldest first).
    /// The returned slice is allocated on `alloc`; the strings stay
    /// owned by the log.
    pub fn forSource(self: *const SourceHistory, alloc: std.mem.Allocator, source_id: []const u8) ![]HistoryEntry {
        var out: std.ArrayList(HistoryEntry) = .empty;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.source_id, source_id)) try out.append(alloc, e);
        }
        return out.toOwnedSlice(alloc);
    }
};

test "source history: empty, then one entry per record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var h = SourceHistory.init(alloc);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 0), h.count());
    try regRecord(&h, "new-dawn", "profile_created", "created", 1000);
    try regRecord(&h, "new-dawn", "status_changed", "active -> removed", 2000);
    try regRecord(&h, "kmtv", "profile_created", "created", 1000);
    try std.testing.expectEqual(@as(usize, 3), h.count());
    const nd = try h.forSource(alloc, "new-dawn");
    try std.testing.expectEqual(@as(usize, 2), nd.len);
    try std.testing.expectEqual(@as(u64, 1), nd[0].seq);
    try std.testing.expectEqualStrings("profile_created", nd[0].action);
    try std.testing.expectEqual(@as(u64, 2), nd[1].seq);
    try std.testing.expectEqualStrings("status_changed", nd[1].action);
    const none = try h.forSource(alloc, "does-not-exist");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

fn regRecord(h: *SourceHistory, id: []const u8, action: []const u8, detail: []const u8, at: i64) !void {
    try h.record(id, action, detail, at);
}

test "source history: bounded, oldest evicted past the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var h = SourceHistory.init(alloc);
    defer h.deinit();
    var i: usize = 0;
    while (i < SourceHistory.max_entries + 5) : (i += 1) {
        try h.record("new-dawn", "status_changed", "change", 1000 + @as(i64, @intCast(i)));
    }
    try std.testing.expectEqual(SourceHistory.max_entries, h.count());
    try std.testing.expectEqual(@as(u64, 6), h.entries.items[0].seq);
}

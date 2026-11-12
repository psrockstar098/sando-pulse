//! Webhook notification store (Roadmap 3.2, design doc section 4).
//!
//! The server process records validated webhook notifications; the
//! worker process drains them. Server and worker are separate
//! processes, so the handoff is persistent, not in-memory: Postgres
//! when a database is configured, an in-memory list otherwise
//! (tests + memory mode — notifications recorded there are visible
//! only to the process that recorded them, which the status route
//! reports honestly).
//!
//! Row id: SHA-256 hex of page_id + source_time (Meta's entry
//! time) + kind + object_id, so a retried webhook delivery inserts
//! once (ON CONFLICT DO NOTHING) instead of duplicating the record.

const std = @import("std");
const fb_types = @import("types.zig");
const pg = @import("../../../storage/postgres.zig");

pub const NotificationStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, n: fb_types.WebhookNotification) anyerror!void,
        pending: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]fb_types.WebhookNotification,
        markProcessed: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, page_id: []const u8, now: i64) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn record(self: NotificationStore, alloc: std.mem.Allocator, n: fb_types.WebhookNotification) !void {
        return self.vtable.record(self.ptr, alloc, n);
    }

    pub fn pending(self: NotificationStore, alloc: std.mem.Allocator) ![]fb_types.WebhookNotification {
        return self.vtable.pending(self.ptr, alloc);
    }

    pub fn markProcessed(self: NotificationStore, alloc: std.mem.Allocator, page_id: []const u8, now: i64) !void {
        return self.vtable.markProcessed(self.ptr, alloc, page_id, now);
    }

    pub fn deinit(self: NotificationStore) void {
        self.vtable.deinit(self.ptr);
    }
};

pub fn notificationId(alloc: std.mem.Allocator, n: fb_types.WebhookNotification) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(n.page_id);
    h.update("\n");
    h.update(n.kind);
    h.update("\n");
    h.update(n.object_id);
    h.update("\n");
    var ts_buf: [20]u8 = undefined;
    // source_time (Meta's entry time), NOT received_at: a retried
    // delivery carries the same entry time, so it dedupes; the
    // server's receipt time differs per delivery.
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{n.source_time}) catch unreachable;
    h.update(ts);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

/// In-memory store: tests + memory mode.
pub const MemoryNotifications = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(fb_types.WebhookNotification) = .empty,

    pub fn init(alloc: std.mem.Allocator) MemoryNotifications {
        return .{ .alloc = alloc };
    }

    pub fn store(self: *MemoryNotifications) NotificationStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = NotificationStore.VTable{
        .record = recordErased,
        .pending = pendingErased,
        .markProcessed = markProcessedErased,
        .deinit = deinitErased,
    };

    fn recordErased(ptr: *anyopaque, alloc: std.mem.Allocator, n: fb_types.WebhookNotification) !void {
        const self: *MemoryNotifications = @ptrCast(@alignCast(ptr));
        // Dedupe on the deterministic id, like the Postgres store.
        const id = try notificationId(alloc, n);
        defer alloc.free(id);
        for (self.items.items) |existing| {
            const eid = try notificationId(alloc, existing);
            defer alloc.free(eid);
            if (std.mem.eql(u8, eid, id)) return;
        }
        // Stored strings use the STORE's allocator (self.alloc):
        // the passed alloc may be a per-request arena that dies
        // before the record is drained.
        try self.items.append(self.alloc, .{
            .page_id = try self.alloc.dupe(u8, n.page_id),
            .kind = try self.alloc.dupe(u8, n.kind),
            .object_id = try self.alloc.dupe(u8, n.object_id),
            .received_at = n.received_at,
            .processed_at = n.processed_at,
        });
    }

    fn pendingErased(ptr: *anyopaque, alloc: std.mem.Allocator) ![]fb_types.WebhookNotification {
        const self: *MemoryNotifications = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(fb_types.WebhookNotification) = .empty;
        for (self.items.items) |n| {
            if (n.processed_at != null) continue;
            try out.append(alloc, .{
                .page_id = try alloc.dupe(u8, n.page_id),
                .kind = try alloc.dupe(u8, n.kind),
                .object_id = try alloc.dupe(u8, n.object_id),
                .received_at = n.received_at,
                .processed_at = null,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn markProcessedErased(ptr: *anyopaque, _: std.mem.Allocator, page_id: []const u8, now: i64) !void {
        const self: *MemoryNotifications = @ptrCast(@alignCast(ptr));
        for (self.items.items) |*n| {
            if (std.mem.eql(u8, n.page_id, page_id) and n.processed_at == null) {
                n.processed_at = now;
            }
        }
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *MemoryNotifications = @ptrCast(@alignCast(ptr));
        for (self.items.items) |n| {
            self.alloc.free(n.page_id);
            self.alloc.free(n.kind);
            self.alloc.free(n.object_id);
        }
        self.items.deinit(self.alloc);
    }
};

/// Postgres store: table `facebook_notifications` (migration 006).
pub const PostgresNotifications = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    conninfo: []const u8,
    client: ?pg.PgClient = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, conninfo: []const u8) !PostgresNotifications {
        return .{
            .alloc = alloc,
            .io = io,
            .conninfo = try alloc.dupe(u8, conninfo),
        };
    }

    pub fn deinit(self: *PostgresNotifications) void {
        if (self.client) |*c| c.close();
        self.alloc.free(self.conninfo);
    }

    pub fn store(self: *PostgresNotifications) NotificationStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = NotificationStore.VTable{
        .record = recordErased,
        .pending = pendingErased,
        .markProcessed = markProcessedErased,
        .deinit = deinitErased,
    };

    fn lock(self: *PostgresNotifications) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *PostgresNotifications) void {
        self.mutex.unlock(self.io);
    }

    fn ensureClient(self: *PostgresNotifications) !*pg.PgClient {
        if (self.client == null) {
            self.client = try pg.PgClient.connect(self.alloc, self.io, self.conninfo);
        }
        return &self.client.?;
    }

    fn dropClient(self: *PostgresNotifications) void {
        if (self.client) |*c| {
            c.close();
            self.client = null;
        }
    }

    fn recordErased(ptr: *anyopaque, alloc: std.mem.Allocator, n: fb_types.WebhookNotification) !void {
        const self: *PostgresNotifications = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const id = try notificationId(alloc, n);
        defer alloc.free(id);
        const page_lit = try pg.escapeLiteral(alloc, n.page_id);
        defer alloc.free(page_lit);
        const kind_lit = try pg.escapeLiteral(alloc, n.kind);
        defer alloc.free(kind_lit);
        const obj_lit = try pg.escapeLiteral(alloc, n.object_id);
        defer alloc.free(obj_lit);
        const id_lit = try pg.escapeLiteral(alloc, id);
        defer alloc.free(id_lit);
        const sql = try std.fmt.allocPrint(alloc,
            \\INSERT INTO facebook_notifications (id, page_id, kind, object_id, source_time, received_at)
            \\ VALUES ({s}, {s}, {s}, {s}, {d}, to_timestamp({d}))
            \\ ON CONFLICT (id) DO NOTHING
        , .{ id_lit, page_lit, kind_lit, obj_lit, n.source_time, n.received_at });
        defer alloc.free(sql);
        const client = try self.ensureClient();
        client.exec(alloc, sql) catch |e| {
            self.dropClient();
            return e;
        };
    }

    fn pendingErased(ptr: *anyopaque, alloc: std.mem.Allocator) ![]fb_types.WebhookNotification {
        const self: *PostgresNotifications = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const client = try self.ensureClient();
        var res = client.query(alloc,
            \\SELECT page_id, kind, object_id, source_time, EXTRACT(EPOCH FROM received_at)::bigint
            \\ FROM facebook_notifications WHERE processed_at IS NULL
            \\ ORDER BY received_at ASC
        ) catch |e| {
            self.dropClient();
            return e;
        };
        defer res.deinit(alloc);
        var out: std.ArrayList(fb_types.WebhookNotification) = .empty;
        for (res.rows) |row| {
            if (row.cols.len != 5) continue;
            const page_id = row.cols[0] orelse continue;
            const kind = row.cols[1] orelse "";
            const object_id = row.cols[2] orelse "";
            const source_time = std.fmt.parseInt(i64, row.cols[3] orelse "0", 10) catch 0;
            const ts = std.fmt.parseInt(i64, row.cols[4] orelse "0", 10) catch 0;
            try out.append(alloc, .{
                .page_id = try alloc.dupe(u8, page_id),
                .kind = try alloc.dupe(u8, kind),
                .object_id = try alloc.dupe(u8, object_id),
                .source_time = source_time,
                .received_at = ts,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    fn markProcessedErased(ptr: *anyopaque, alloc: std.mem.Allocator, page_id: []const u8, now: i64) !void {
        const self: *PostgresNotifications = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        const lit = try pg.escapeLiteral(alloc, page_id);
        defer alloc.free(lit);
        const sql = try std.fmt.allocPrint(alloc,
            \\UPDATE facebook_notifications SET processed_at = to_timestamp({d})
            \\ WHERE page_id = {s} AND processed_at IS NULL
        , .{ now, lit });
        defer alloc.free(sql);
        const client = try self.ensureClient();
        client.exec(alloc, sql) catch |e| {
            self.dropClient();
            return e;
        };
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *PostgresNotifications = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "notification store: memory record / pending / markProcessed + retry dedupe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mem = MemoryNotifications.init(alloc);
    const store = mem.store();
    defer store.deinit();
    const n = fb_types.WebhookNotification{ .page_id = "456", .kind = "feed", .object_id = "456_789", .received_at = 1794477600 };
    try store.record(alloc, n);
    try store.record(alloc, n); // retried delivery: recorded once
    const pend = try store.pending(alloc);
    try std.testing.expectEqual(@as(usize, 1), pend.len);
    try std.testing.expectEqualStrings("456", pend[0].page_id);
    try store.markProcessed(alloc, "456", 1794477700);
    const pend2 = try store.pending(alloc);
    try std.testing.expectEqual(@as(usize, 0), pend2.len);
}

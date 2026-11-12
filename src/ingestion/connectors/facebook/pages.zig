//! Page registry (Roadmap 3.2, design doc section 8).
//!
//! The registry is CONFIG, not code: a JSON file whose path comes
//! from PULSE_FACEBOOK_REGISTRY_PATH. Adding or removing a monitored
//! Page means editing the file — never changing Zig code — and the
//! worker re-reads the file on every run, so registry edits take
//! effect without a restart.
//!
//! An entry with an empty page_id is PENDING: the organization is
//! named (from the design doc's three priorities) but its Page has
//! not been registered yet — no partnership / authorization exists
//! for it. Pending entries are reported, never fetched, and their
//! page_id is never guessed or filled in from anywhere.

const std = @import("std");
const fb_types = @import("types.zig");

pub const RegistryFile = struct {
    pages: []fb_types.PageEntry = &.{},
};

/// Load the registry from a JSON file. A missing file is NOT an
/// error — it means no Pages are registered yet (empty registry).
/// A malformed file IS an error: a broken registry must be fixed,
/// not silently treated as empty.
pub fn loadRegistry(alloc: std.mem.Allocator, io: std.Io, path: ?[]const u8) ![]fb_types.PageEntry {
    const p = path orelse return &.{};
    var dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, p, .{}) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const bytes = try reader.interface.readAllocShort(alloc, 1 << 20);
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSliceLeaky(RegistryFile, alloc, bytes, .{ .ignore_unknown_fields = true });
    // The parsed strings borrow from `bytes` (freed above), so dupe
    // every entry into owned strings before returning.
    var out: std.ArrayList(fb_types.PageEntry) = .empty;
    for (parsed.pages) |entry| {
        try out.append(alloc, .{
            .page_id = try alloc.dupe(u8, entry.page_id),
            .name = try alloc.dupe(u8, entry.name),
            .priority = entry.priority,
            .category = try alloc.dupe(u8, entry.category),
            .notes = try alloc.dupe(u8, entry.notes),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Count entries that are actually registered (have a page_id).
pub fn registeredCount(pages: []const fb_types.PageEntry) usize {
    var n: usize = 0;
    for (pages) |p| {
        if (p.registered()) n += 1;
    }
    return n;
}

pub fn findPage(pages: []const fb_types.PageEntry, page_id: []const u8) ?fb_types.PageEntry {
    for (pages) |p| {
        if (std.mem.eql(u8, p.page_id, page_id)) return p;
    }
    return null;
}

test "registry: missing file is empty; example file loads with pending entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const missing = try loadRegistry(alloc, io, "does-not-exist-registry.json");
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    const none = try loadRegistry(alloc, io, null);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const example = try loadRegistry(alloc, io, "config/facebook-pages.example.json");
    try std.testing.expect(example.len >= 11);
    try std.testing.expectEqual(@as(usize, 0), registeredCount(example));
    // Priority 1 media orgs from the design doc are named.
    var saw_fpa = false;
    var saw_okfm = false;
    for (example) |p| {
        if (std.mem.eql(u8, p.name, "FrontPage Africa")) saw_fpa = true;
        if (std.mem.eql(u8, p.name, "OK FM")) saw_okfm = true;
    }
    try std.testing.expect(saw_fpa and saw_okfm);
}

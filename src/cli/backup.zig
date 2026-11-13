//! Database backup and restore (Roadmap 5.1): `pulse backup` / `pulse restore`.
//!
//! The backup is a plain-format `pg_dump` of DATABASE_URL, written to
//! `backups/pulse-<UTC stamp>.sql` (or `--out <path>`), with its SHA-256
//! printed so the operator can verify the file later. Old backups are
//! pruned to the last N (default 7, `--keep N`). The dump never contains
//! the database password (pg_dump does not echo it) and the file lives on
//! the operator's disk, never in the repo.
//!
//! Restore runs `psql -f <file>` against DATABASE_URL with
//! ON_ERROR_STOP=1. The dump is a plain restore into an EMPTY database:
//! restoring over a live database with existing tables fails on the
//! CREATE TABLE statements, which is the safe behaviour — see
//! docs/OPERATIONS.md for the full disaster-recovery procedure
//! (dropdb/createdb, then restore, then `pulse migrate`).
//!
//! Both commands need pg_dump / psql on PATH (postgresql-client). When
//! they are missing the command fails with a plain message, never a
//! half-written file: the dump is written by pg_dump itself, and a
//! non-zero pg_dump exit deletes the partial file.

const std = @import("std");
const format = @import("../common/format.zig");
const timex = @import("../common/time.zig");

pub const default_keep: usize = 7;
pub const default_dir: []const u8 = "backups";

pub const BackupReport = struct {
    path: []const u8,
    bytes: u64,
    sha256_hex: []const u8,
    pruned: usize,
};

/// "YYYYMMDD-HHMMSS" (UTC). Civil-from-days algorithm, same as
/// maintenance.stampOf (kept local so this CLI stays independent).
pub fn stampOf(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const days = @divFloor(ts, 86400);
    const secs = @mod(ts, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try format.writeZeroPadded(&w, m, 2);
    try format.writeZeroPadded(&w, d, 2);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, @divFloor(secs, 3600), 2);
    try format.writeZeroPadded(&w, @divFloor(@mod(secs, 3600), 60), 2);
    try format.writeZeroPadded(&w, @mod(secs, 60), 2);
    return alloc.dupe(u8, w.buffered());
}

pub fn backupFileName(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const stamp = try stampOf(alloc, ts);
    defer alloc.free(stamp);
    return std.fmt.allocPrint(alloc, "pulse-{s}.sql", .{stamp});
}

pub fn sha256Hex(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

/// Delete every `pulse-*.sql` in `dir` except the newest `keep` (by
/// filename, which sorts by UTC stamp). Returns how many were removed.
pub fn pruneBackups(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, keep: usize) !usize {
    var cwd = std.Io.Dir.cwd();
    var d = cwd.openDir(io, dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "pulse-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    if (names.items.len <= keep) return 0;
    const remove_n = names.items.len - keep;
    var removed: usize = 0;
    for (names.items[0..remove_n]) |name| {
        d.deleteFile(io, name) catch continue;
        removed += 1;
    }
    return removed;
}

/// Run pg_dump against `database_url` and write the dump to `out_path`.
/// On a non-zero pg_dump exit the partial file is deleted and the
/// pg_dump stderr is returned in the error's message via the caller.
pub fn runBackup(alloc: std.mem.Allocator, io: std.Io, database_url: []const u8, out_path: []const u8) !BackupReport {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "pg_dump", database_url, "-f", out_path },
    }) catch |e| switch (e) {
        error.FileNotFound => return error.PgDumpMissing,
        else => return e,
    };
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (!res.term.success()) {
        var cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, out_path) catch {};
        return error.PgDumpFailed;
    }
    var cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, out_path, .{}) catch return error.BackupUnreadable;
    defer file.close(io);
    const stat = file.stat(io) catch return error.BackupUnreadable;
    const bytes: u64 = @intCast(stat.size);
    if (bytes == 0) {
        cwd.deleteFile(io, out_path) catch {};
        return error.BackupEmpty;
    }
    if (bytes > 1024 * 1024 * 1024) return error.BackupTooLarge;
    const data = try alloc.alloc(u8, @intCast(bytes));
    defer alloc.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return error.BackupUnreadable;
    if (n != bytes) return error.BackupUnreadable;
    if (std.mem.indexOf(u8, data, "PostgreSQL database dump") == null) {
        cwd.deleteFile(io, out_path) catch {};
        return error.BackupInvalid;
    }
    return .{
        .path = try alloc.dupe(u8, out_path),
        .bytes = bytes,
        .sha256_hex = try sha256Hex(alloc, data),
        .pruned = 0,
    };
}

/// `pulse backup` entry point: default path `backups/pulse-<stamp>.sql`,
/// then prune to `keep` files. Prints one line for the operator.
pub fn backup(alloc: std.mem.Allocator, io: std.Io, database_url: []const u8, out_path: ?[]const u8, keep: usize) !void {
    const now = timex.nowSeconds(io);
    const path: []const u8 = if (out_path) |p| p else blk: {
        var cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, default_dir) catch |e| return e;
        const name = try backupFileName(alloc, now);
        defer alloc.free(name);
        break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ default_dir, name });
    };
    defer if (out_path == null) alloc.free(path);
    var report = try runBackup(alloc, io, database_url, path);
    report.pruned = try pruneBackups(alloc, io, default_dir, keep);
    std.debug.print("backup: path={s} bytes={d} sha256={s} pruned={d}\n", .{ report.path, report.bytes, report.sha256_hex, report.pruned });
    alloc.free(report.path);
    alloc.free(report.sha256_hex);
}

/// `pulse restore` entry point: psql -f against DATABASE_URL.
pub fn restore(alloc: std.mem.Allocator, io: std.Io, database_url: []const u8, in_path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    var probe = cwd.openFile(io, in_path, .{}) catch return error.RestoreFileMissing;
    probe.close(io);
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "psql", database_url, "-v", "ON_ERROR_STOP=1", "-f", in_path },
    }) catch |e| switch (e) {
        error.FileNotFound => return error.PsqlMissing,
        else => return e,
    };
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (!res.term.success()) {
        std.debug.print("restore failed: {s}\n", .{res.stderr});
        return error.RestoreFailed;
    }
    std.debug.print("restore: {s} applied\n", .{in_path});
}

test "backup: stampOf formats UTC stamps" {
    const alloc = std.testing.allocator;
    const s = try stampOf(alloc, 1794441600); // 2026-11-12 00:00 UTC
    defer alloc.free(s);
    try std.testing.expectEqualStrings("20261112-000000", s);
    const s2 = try stampOf(alloc, 1794540816); // 2026-11-13 03:33:36 UTC
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("20261113-033336", s2);
}

test "backup: backupFileName" {
    const alloc = std.testing.allocator;
    const n = try backupFileName(alloc, 1794441600);
    defer alloc.free(n);
    try std.testing.expectEqualStrings("pulse-20261112-000000.sql", n);
}

test "backup: sha256Hex is stable and correct" {
    const alloc = std.testing.allocator;
    const h = try sha256Hex(alloc, "abc");
    defer alloc.free(h);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", h);
    const h2 = try sha256Hex(alloc, "abc");
    defer alloc.free(h2);
    try std.testing.expectEqualStrings(h, h2);
}

test "backup: pruneBackups keeps the newest N" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "test-backups-prune";
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    const names = [_][]const u8{
        "pulse-20261110-000000.sql",
        "pulse-20261111-000000.sql",
        "pulse-20261112-000000.sql",
        "pulse-20261113-000000.sql",
        "notes.txt",
    };
    defer {
        for (names) |n| {
            const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, n }) catch continue;
            defer alloc.free(p);
            cwd.deleteFile(io, p) catch {};
        }
        cwd.deleteDir(io, dir) catch {};
    }
    for (names) |n| {
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, n });
        defer alloc.free(p);
        var f = try cwd.createFile(io, p, .{});
        f.close(io);
    }
    const pruned = try pruneBackups(alloc, io, dir, 2);
    try std.testing.expectEqual(@as(usize, 2), pruned);
    // The two newest .sql files and the unrelated file must survive.
    var f1 = try cwd.openFile(io, dir ++ "/pulse-20261113-000000.sql", .{});
    f1.close(io);
    var f2 = try cwd.openFile(io, dir ++ "/pulse-20261112-000000.sql", .{});
    f2.close(io);
    var f3 = try cwd.openFile(io, dir ++ "/notes.txt", .{});
    f3.close(io);
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, dir ++ "/pulse-20261110-000000.sql", .{}));
}

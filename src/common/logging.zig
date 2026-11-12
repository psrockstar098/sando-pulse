//! Structured JSON logging (one JSON object per line, on stderr).
//! Fields never include secrets, API keys, or user query bodies.

const std = @import("std");

pub const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };

pub const Field = struct { key: []const u8, value: []const u8 };

/// NOTE: Pulse is single-threaded in Phase 1 (one accept loop, one worker
/// process), so logging needs no lock. If threads are introduced, add a
/// mutex here first.
var current_level: Level = .info;

pub fn setLevel(level: Level) void {
    current_level = level;
}

pub fn parseLevel(s: []const u8) Level {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .err;
    return .info;
}

fn levelName(level: Level) []const u8 {
    return switch (level) {
        .debug => "debug",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:04}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Wall-clock milliseconds. Zig 0.17.1 has no std.time wall clock, so the
/// logger reads CLOCK_REALTIME directly (Linux-only; Pulse targets Linux
/// containers). Returns 0 if the call fails rather than crashing logging.
fn wallMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (std.posix.errno(rc) != .SUCCESS) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Emit one structured log line. Never logs secrets: callers must not pass
/// API keys, passwords, or tokens as field values.
pub fn log(level: Level, msg: []const u8, fields: []const Field) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{{\"ts\":{d},\"level\":", .{wallMillis()}) catch return;
    writeJsonString(&w, levelName(level)) catch return;
    w.writeAll(",\"msg\":") catch return;
    writeJsonString(&w, msg) catch return;
    for (fields) |f| {
        w.writeAll(",") catch return;
        writeJsonString(&w, f.key) catch return;
        w.writeAll(":") catch return;
        writeJsonString(&w, f.value) catch return;
    }
    w.writeAll("}") catch return;
    std.debug.print("{s}\n", .{w.buffered()});
}

pub fn debug(msg: []const u8, fields: []const Field) void {
    log(.debug, msg, fields);
}
pub fn info(msg: []const u8, fields: []const Field) void {
    log(.info, msg, fields);
}
pub fn warn(msg: []const u8, fields: []const Field) void {
    log(.warn, msg, fields);
}
pub fn err(msg: []const u8, fields: []const Field) void {
    log(.err, msg, fields);
}

test "parseLevel maps known names and defaults to info" {
    try std.testing.expectEqual(Level.debug, parseLevel("debug"));
    try std.testing.expectEqual(Level.warn, parseLevel("warn"));
    try std.testing.expectEqual(Level.err, parseLevel("error"));
    try std.testing.expectEqual(Level.info, parseLevel("info"));
    try std.testing.expectEqual(Level.info, parseLevel("bogus"));
}

test "log emits a line without crashing" {
    // Smoke-only: verifies the JSON writer path runs.
    log(.info, "test log line", &.{ .{ .key = "k", .value = "v\"q" } });
}

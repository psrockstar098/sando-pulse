//! Structured JSON logging (one JSON object per line, on stderr).
//! Fields never include secrets, API keys, or user query bodies.

const std = @import("std");

pub const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };

pub const Field = struct { key: []const u8, value: []const u8 };

var log_mutex: std.Thread.Mutex = .{};
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

/// Emit one structured log line. Never logs secrets: callers must not pass
/// API keys, passwords, or tokens as field values.
pub fn log(level: Level, msg: []const u8, fields: []const Field) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    log_mutex.lock();
    defer log_mutex.unlock();
    const stderr = std.io.getStdErr().writer();
    stderr.print("{{\"ts\":{d},\"level\":", .{std.time.milliTimestamp()}) catch return;
    writeJsonString(stderr, levelName(level)) catch return;
    stderr.writeAll(",\"msg\":") catch return;
    writeJsonString(stderr, msg) catch return;
    for (fields) |f| {
        stderr.writeAll(",") catch return;
        writeJsonString(stderr, f.key) catch return;
        stderr.writeAll(":") catch return;
        writeJsonString(stderr, f.value) catch return;
    }
    stderr.writeAll("}\n") catch return;
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

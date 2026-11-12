//! Temporal intelligence (Roadmap 2.5): resolve natural-language time
//! expressions ("today", "last week", "in 2024", "between 2026-01-01 and
//! 2026-03-01") into Unix time ranges, and compute day/month boundaries in
//! a timezone. All ranges are half-open [from, to) in Unix seconds.
//! Timezone is an offset in minutes east of UTC (Africa/Monrovia = 0).

const std = @import("std");

pub const TimeRange = struct {
    from: i64,
    to: i64,

    pub fn contains(self: TimeRange, ts: i64) bool {
        return ts >= self.from and ts < self.to;
    }
};

pub const seconds_per_day: i64 = 86_400;

/// Start of the local day containing `unix`, for a timezone offset in minutes.
pub fn dayStart(unix: i64, tz_offset_minutes: i32) i64 {
    const off: i64 = @as(i64, tz_offset_minutes) * 60;
    return unix - @mod(unix + off, seconds_per_day);
}

/// Start of the local month containing `unix`.
pub fn monthStart(unix: i64, tz_offset_minutes: i32) i64 {
    const local = unix + @as(i64, tz_offset_minutes) * 60;
    const days = @divFloor(local, seconds_per_day);
    const civil = civilFromDays(days);
    return daysFromCivil(civil.year, civil.month, 1) * seconds_per_day - @as(i64, tz_offset_minutes) * 60;
}

/// Start of the local year containing `unix`.
pub fn yearStart(unix: i64, tz_offset_minutes: i32) i64 {
    const local = unix + @as(i64, tz_offset_minutes) * 60;
    const days = @divFloor(local, seconds_per_day);
    const civil = civilFromDays(days);
    return daysFromCivil(civil.year, 1, 1) * seconds_per_day - @as(i64, tz_offset_minutes) * 60;
}

pub const CivilDate = struct { year: i64, month: i64, day: i64 };

/// Days since 1970-01-01 -> civil date (Howard Hinnant's algorithm).
pub fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

/// Civil date -> days since 1970-01-01.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

const month_names = [_][]const u8{
    "january", "february", "march",     "april",   "may",      "june",
    "july",    "august",   "september", "october", "november", "december",
};
const month_abbrs = [_][]const u8{
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec",
};

pub fn monthNumber(name: []const u8) ?i64 {
    var lower_buf: [16]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(lower_buf[0..name.len], name);
    for (month_names, 0..) |n, i| {
        if (std.mem.eql(u8, lower, n)) return @intCast(i + 1);
    }
    for (month_abbrs, 0..) |n, i| {
        if (std.mem.eql(u8, lower, n)) return @intCast(i + 1);
    }
    return null;
}

/// Parse an ISO date "YYYY-MM-DD" at the start of `s`. Returns days since epoch.
fn parseIsoDate(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    return daysFromCivil(y, m, d);
}

/// Parse "12 November 2026" / "12 Nov 2026" / "November 12, 2026".
/// Scans every consecutive triple of whitespace/comma-separated tokens so
/// the date can sit anywhere in the sentence.
fn parseLongDate(s: []const u8) ?i64 {
    var toks: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " ,");
    while (it.next()) |tok| {
        if (n >= toks.len) return null;
        toks[n] = tok;
        n += 1;
    }
    if (n < 3) return null;
    var i: usize = 0;
    while (i + 2 < n) : (i += 1) {
        const first = toks[i];
        const second = toks[i + 1];
        const third = toks[i + 2];
        // "12 November 2026"
        if (std.fmt.parseInt(i64, first, 10)) |d| {
            if (monthNumber(second)) |m| {
                if (std.fmt.parseInt(i64, third, 10)) |y| {
                    if (d >= 1 and d <= daysInMonth(y, m)) return daysFromCivil(y, m, d);
                } else |_| {}
            }
            continue;
        } else |_| {}
        // "November 12, 2026"
        if (monthNumber(first)) |m| {
            if (std.fmt.parseInt(i64, second, 10)) |d| {
                if (std.fmt.parseInt(i64, third, 10)) |y| {
                    if (d >= 1 and d <= daysInMonth(y, m)) return daysFromCivil(y, m, d);
                } else |_| {}
            } else |_| {}
        }
    }
    return null;
}

/// Find the first ISO or long date inside `s` (scanning token by token).
fn findDate(s: []const u8) ?i64 {
    // ISO dates appear as a contiguous 10-char token.
    var i: usize = 0;
    while (i + 10 <= s.len) : (i += 1) {
        if (parseIsoDate(s[i .. i + 10])) |days| return days;
    }
    return parseLongDate(s);
}

fn findYear(s: []const u8) ?i64 {
    // A standalone 4-digit year 1900-2100.
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') continue;
        const before_ok = i == 0 or s[i - 1] < '0' or s[i - 1] > '9';
        const after_ok = i + 4 >= s.len or s[i + 4] < '0' or s[i + 4] > '9';
        if (!before_ok or !after_ok) continue;
        const y = std.fmt.parseInt(i64, s[i .. i + 4], 10) catch continue;
        if (y >= 1900 and y <= 2100) return y;
    }
    return null;
}

fn parseCounted(s: []const u8, needle: []const u8) ?i64 {
    // "last 7 days" / "past 30 days" / "last 2 weeks" / "last 3 months".
    const idx = std.mem.indexOf(u8, s, needle) orelse return null;
    const before = s[0..idx];
    var it = std.mem.tokenizeAny(u8, before, " ");
    var last_num: ?i64 = null;
    while (it.next()) |tok| {
        if (std.fmt.parseInt(i64, tok, 10)) |n| {
            last_num = n;
        } else |_| {}
    }
    return last_num;
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, haystack, " ,.;:!?\"'()");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, needle)) return true;
    }
    return false;
}

/// Resolve a natural-language time expression to a [from, to) range.
/// `now` is Unix seconds; `tz_offset_minutes` is minutes east of UTC.
/// Returns null when the text carries no recognizable time expression.
/// The caller owns nothing; no allocation.
pub fn resolve(text: []const u8, now: i64, tz_offset_minutes: i32) ?TimeRange {
    var lower_buf: [512]u8 = undefined;
    const lower = if (text.len <= lower_buf.len)
        std.ascii.lowerString(lower_buf[0..text.len], text)
    else
        text; // too long: match case-sensitively on the raw text (rare)
    const s = lower;
    const off: i64 = @as(i64, tz_offset_minutes) * 60;
    const today = dayStart(now, tz_offset_minutes);

    // Explicit ranges first: "between X and Y", "from X to Y".
    if (std.mem.indexOf(u8, s, "between ") != null or std.mem.indexOf(u8, s, "from ") != null) {
        const first = findDate(s) orelse null;
        if (first) |f| {
            // Find a second date after the first one.
            const rest_start = std.mem.indexOf(u8, s, " and ") orelse std.mem.indexOf(u8, s, " to ") orelse null;
            if (rest_start) |rs| {
                if (findDate(s[rs + 4 ..])) |second| {
                    const from = f * seconds_per_day - off;
                    const to = (second + 1) * seconds_per_day - off;
                    if (to > from) return .{ .from = from, .to = to };
                }
            }
        }
    }

    // Single explicit day: ISO or long date anywhere in the text.
    if (findDate(s)) |days| {
        return .{ .from = days * seconds_per_day - off, .to = (days + 1) * seconds_per_day - off };
    }

    if (containsWord(s, "today")) return .{ .from = today, .to = today + seconds_per_day };
    if (containsWord(s, "yesterday")) return .{ .from = today - seconds_per_day, .to = today };
    if (containsWord(s, "tomorrow")) return .{ .from = today + seconds_per_day, .to = today + 2 * seconds_per_day };

    if (std.mem.indexOf(u8, s, "this week") != null) {
        // Week starts Monday. Local weekday: 1970-01-01 was Thursday.
        const days = @divFloor(now + off, seconds_per_day);
        const weekday = @mod(days + 3, 7); // 0 = Monday
        return .{ .from = today - weekday * seconds_per_day, .to = today + seconds_per_day };
    }
    if (std.mem.indexOf(u8, s, "last week") != null) {
        const days = @divFloor(now + off, seconds_per_day);
        const weekday = @mod(days + 3, 7);
        const start = today - (weekday + 7) * seconds_per_day;
        return .{ .from = start, .to = start + 7 * seconds_per_day };
    }
    if (std.mem.indexOf(u8, s, "this month") != null) {
        const start = monthStart(now, tz_offset_minutes);
        const civil = civilFromDays(@divFloor(now + off, seconds_per_day));
        const next_month = if (civil.month == 12) 1 else civil.month + 1;
        const next_year = if (civil.month == 12) civil.year + 1 else civil.year;
        const end = daysFromCivil(next_year, next_month, 1) * seconds_per_day - off;
        return .{ .from = start, .to = end };
    }
    if (std.mem.indexOf(u8, s, "last month") != null) {
        const civil = civilFromDays(@divFloor(now + off, seconds_per_day));
        const prev_month = if (civil.month == 1) 12 else civil.month - 1;
        const prev_year = if (civil.month == 1) civil.year - 1 else civil.year;
        const start = daysFromCivil(prev_year, prev_month, 1) * seconds_per_day - off;
        const end = monthStart(now, tz_offset_minutes);
        return .{ .from = start, .to = end };
    }
    if (std.mem.indexOf(u8, s, "this year") != null) {
        const start = yearStart(now, tz_offset_minutes);
        const civil = civilFromDays(@divFloor(now + off, seconds_per_day));
        const end = daysFromCivil(civil.year + 1, 1, 1) * seconds_per_day - off;
        return .{ .from = start, .to = end };
    }
    if (std.mem.indexOf(u8, s, "last year") != null) {
        const civil = civilFromDays(@divFloor(now + off, seconds_per_day));
        const start = daysFromCivil(civil.year - 1, 1, 1) * seconds_per_day - off;
        const end = daysFromCivil(civil.year, 1, 1) * seconds_per_day - off;
        return .{ .from = start, .to = end };
    }

    // Counted windows: "last 7 days", "past 30 days", "last 2 weeks", "last 3 months".
    if (std.mem.indexOf(u8, s, "days") != null) {
        if (parseCounted(s, "days")) |n| {
            if (n > 0 and n <= 3650) return .{ .from = today - (n - 1) * seconds_per_day, .to = today + seconds_per_day };
        }
    }
    if (std.mem.indexOf(u8, s, "weeks") != null) {
        if (parseCounted(s, "weeks")) |n| {
            if (n > 0 and n <= 520) return .{ .from = today - (n * 7 - 1) * seconds_per_day, .to = today + seconds_per_day };
        }
    }
    if (std.mem.indexOf(u8, s, "months") != null) {
        if (parseCounted(s, "months")) |n| {
            if (n > 0 and n <= 120) {
                const civil = civilFromDays(@divFloor(now + off, seconds_per_day));
                var y = civil.year;
                var m = civil.month - n;
                while (m <= 0) {
                    m += 12;
                    y -= 1;
                }
                const start = daysFromCivil(y, m, 1) * seconds_per_day - off;
                return .{ .from = start, .to = today + seconds_per_day };
            }
        }
    }

    // Bare year: "in 2024", "2024".
    if (findYear(s)) |y| {
        return .{ .from = daysFromCivil(y, 1, 1) * seconds_per_day - off, .to = daysFromCivil(y + 1, 1, 1) * seconds_per_day - off };
    }

    return null;
}

/// Human label for a resolved range, e.g. "today", "2026-11-11..2026-11-12".
/// Caller owns the returned slice.
pub fn describe(alloc: std.mem.Allocator, range: TimeRange, tz_offset_minutes: i32) ![]u8 {
    const off: i64 = @as(i64, tz_offset_minutes) * 60;
    const from = civilFromDays(@divFloor(range.from + off, seconds_per_day));
    const to = civilFromDays(@divFloor(range.to - 1 + off, seconds_per_day));
    // NOTE (Zig 0.17.1 fmt quirk, found live 2026-11-12): a width spec on a
    // signed integer prints an explicit '+' for positive values
    // ("{d:04}" on i64 2026 -> "+2026"). Civil dates here are always
    // post-1970, so cast to u64 first — unsigned values pad cleanly.
    const fy: u64 = @intCast(from.year);
    const fm: u64 = @intCast(from.month);
    const fd: u64 = @intCast(from.day);
    const ty: u64 = @intCast(to.year);
    const tm: u64 = @intCast(to.month);
    const td: u64 = @intCast(to.day);
    if (from.year == to.year and from.month == to.month and from.day == to.day) {
        return std.fmt.allocPrint(alloc, "{d:04}-{d:02}-{d:02}", .{ fy, fm, fd });
    }
    return std.fmt.allocPrint(alloc, "{d:04}-{d:02}-{d:02}..{d:04}-{d:02}-{d:02}", .{ fy, fm, fd, ty, tm, td });
}

test "temporal: day boundaries in Monrovia (UTC+0)" {
    // 2026-11-12 12:00 UTC.
    const now: i64 = 1794484800;
    const today = dayStart(now, 0);
    try std.testing.expectEqual(@as(i64, 1794441600), today);
    const r = resolve("today", now, 0).?;
    try std.testing.expectEqual(today, r.from);
    try std.testing.expectEqual(today + 86400, r.to);
    const y = resolve("yesterday", now, 0).?;
    try std.testing.expectEqual(today - 86400, y.from);
    try std.testing.expectEqual(today, y.to);
}

test "temporal: counted windows" {
    const now: i64 = 1794484800; // 2026-11-12 12:00 UTC
    const r = resolve("last 7 days", now, 0).?;
    try std.testing.expectEqual(@as(i64, 1794441600 - 6 * 86400), r.from);
    try std.testing.expectEqual(@as(i64, 1794441600 + 86400), r.to);
    const w = resolve("last 2 weeks", now, 0).?;
    try std.testing.expectEqual(@as(i64, 1794441600 - 13 * 86400), w.from);
}

test "temporal: explicit dates and years" {
    const now: i64 = 1794484800;
    const d = resolve("what happened on 2026-11-10", now, 0).?;
    // 2026-11-10 00:00 UTC = 1794268800
    try std.testing.expectEqual(@as(i64, 1794268800), d.from);
    try std.testing.expectEqual(@as(i64, 1794268800 + 86400), d.to);
    const l = resolve("news from 12 November 2026", now, 0).?;
    try std.testing.expectEqual(@as(i64, 1794441600), l.from);
    const yr = resolve("in 2024", now, 0).?;
    try std.testing.expectEqual(@as(i64, 1704067200), yr.from); // 2024-01-01
    try std.testing.expectEqual(@as(i64, 1735689600), yr.to); // 2025-01-01
    const between = resolve("between 2026-01-01 and 2026-02-01", now, 0).?;
    try std.testing.expectEqual(@as(i64, 1767225600), between.from); // 2026-01-01
    try std.testing.expectEqual(@as(i64, 1769990400), between.to); // 2026-02-02 (exclusive end)
}

test "temporal: this week / last month / no match" {
    const now: i64 = 1794484800; // Thursday 2026-11-12
    const w = resolve("this week", now, 0).?;
    // Monday 2026-11-09 00:00 UTC = 1794182400
    try std.testing.expectEqual(@as(i64, 1794182400), w.from);
    const m = resolve("last month", now, 0).?;
    // October 2026: 2026-10-01 = 1790812800, 2026-11-01 = 1793491200
    try std.testing.expectEqual(@as(i64, 1790812800), m.from);
    try std.testing.expectEqual(@as(i64, 1793491200), m.to);
    try std.testing.expectEqual(@as(?TimeRange, null), resolve("fuel prices in Monrovia", now, 0));
}

test "temporal: civil date round trip" {
    const days = daysFromCivil(2026, 11, 12);
    try std.testing.expectEqual(@as(i64, 20769), days);
    const c = civilFromDays(days);
    try std.testing.expectEqual(@as(i64, 2026), c.year);
    try std.testing.expectEqual(@as(i64, 11), c.month);
    try std.testing.expectEqual(@as(i64, 12), c.day);
    const leap = daysFromCivil(2024, 2, 29);
    const cl = civilFromDays(leap);
    try std.testing.expectEqual(@as(i64, 29), cl.day);
    try std.testing.expectEqual(@as(i64, 2), cl.month);
}

test "temporal: describe formats a single day" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = resolve("today", 1794484800, 0).?;
    const label = try describe(alloc, r, 0);
    std.debug.print("describe today: [{s}]\n", .{label});
    try std.testing.expectEqualStrings("2026-11-12", label);
    const w = resolve("last week", 1794484800, 0).?;
    const wl = try describe(alloc, w, 0);
    std.debug.print("describe last week: [{s}]\n", .{wl});
    try std.testing.expectEqualStrings("2026-11-02..2026-11-08", wl);
}

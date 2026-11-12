//! Minimal RSS 2.0 parser: <item> blocks with title, link, description,
//! pubDate. Handles CDATA sections and XML entities; strips HTML from
//! descriptions. No external XML library — the feeds are small and regular.

const std = @import("std");

pub const RawItem = struct {
    title: []const u8,
    link: []const u8,
    description: []const u8,
    pub_date: ?i64,
};

/// Decode the five XML entities plus numeric character references.
pub fn decodeEntities(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, s, i, ';');
            if (semi) |end| {
                const ent = s[i + 1 .. end];
                if (std.mem.eql(u8, ent, "amp")) {
                    try out.append(alloc, '&');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "lt")) {
                    try out.append(alloc, '<');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "gt")) {
                    try out.append(alloc, '>');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "quot")) {
                    try out.append(alloc, '"');
                    i = end + 1;
                    continue;
                } else if (std.mem.eql(u8, ent, "apos")) {
                    try out.append(alloc, '\'');
                    i = end + 1;
                    continue;
                } else if (ent.len > 1 and ent[0] == '#') {
                    const num = if (ent[1] == 'x' or ent[1] == 'X')
                        std.fmt.parseInt(u21, ent[2..], 16) catch null
                    else
                        std.fmt.parseInt(u21, ent[1..], 10) catch null;
                    if (num) |cp| {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        if (n > 0) {
                            try out.appendSlice(alloc, buf[0..n]);
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Strip <...> tags, leaving the text between them.
pub fn stripTags(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    for (s) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// Collapse runs of whitespace to single spaces and trim.
pub fn cleanText(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const no_tags = try stripTags(alloc, s);
    defer alloc.free(no_tags);
    const decoded = try decodeEntities(alloc, no_tags);
    defer alloc.free(decoded);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var last_space = true;
    for (decoded) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!last_space) try out.append(alloc, ' ');
            last_space = true;
        } else {
            try out.append(alloc, c);
            last_space = false;
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " ");
    return alloc.dupe(u8, trimmed);
}

fn unwrapCdata(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (std.mem.startsWith(u8, trimmed, "<![CDATA[") and std.mem.endsWith(u8, trimmed, "]]>")) {
        return trimmed["<![CDATA[".len .. trimmed.len - "]]>".len];
    }
    return trimmed;
}

fn fieldValue(block: []const u8, tag: []const u8) ?[]const u8 {
    const open = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open);
    const close = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close);
    const start = std.mem.indexOf(u8, block, open) orelse return null;
    const content_start = start + open.len;
    const end = std.mem.indexOfPos(u8, block, content_start, close) orelse return null;
    return unwrapCdata(block[content_start..end]);
}

/// Days-from-civil (Howard Hinnant's algorithm), for RFC 822 dates.
fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = if (yy >= 0) @divFloor(yy, 400) else @divFloor(yy - 399, 400);
    const yoe = yy - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn monthNumber(name: []const u8) ?i64 {
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    for (months, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(name, m)) return @intCast(i + 1);
    }
    return null;
}

/// Parse an RFC 822 date ("Thu, 12 Nov 2026 10:00:00 +0000" or "... GMT").
/// Returns unix seconds, or null when unparseable.
pub fn parsePubDate(s: []const u8) ?i64 {
    const t = std.mem.trim(u8, s, " \t\n\r");
    // Skip weekday prefix.
    var rest = t;
    if (std.mem.indexOfScalar(u8, t, ',')) |comma| rest = std.mem.trim(u8, t[comma + 1 ..], " ");
    var it = std.mem.tokenizeAny(u8, rest, " ");
    const day_s = it.next() orelse return null;
    const mon_s = it.next() orelse return null;
    const year_s = it.next() orelse return null;
    const time_s = it.next() orelse return null;
    const tz_s = it.next() orelse "GMT";
    const day = std.fmt.parseInt(i64, day_s, 10) catch return null;
    const month = monthNumber(mon_s) orelse return null;
    const year = std.fmt.parseInt(i64, year_s, 10) catch return null;
    var tit = std.mem.splitScalar(u8, time_s, ':');
    const hh = std.fmt.parseInt(i64, tit.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(i64, tit.next() orelse return null, 10) catch return null;
    const ss_s = tit.next() orelse "0";
    const ss = std.fmt.parseInt(i64, ss_s, 10) catch 0;
    var offset: i64 = 0;
    if (tz_s.len == 5 and (tz_s[0] == '+' or tz_s[0] == '-')) {
        const oh = std.fmt.parseInt(i64, tz_s[1..3], 10) catch return null;
        const om = std.fmt.parseInt(i64, tz_s[3..5], 10) catch return null;
        offset = (oh * 3600 + om * 60) * (if (tz_s[0] == '-') @as(i64, -1) else @as(i64, 1));
    }
    const days = daysFromCivil(year, month, day);
    return days * 86400 + hh * 3600 + mm * 60 + ss - offset;
}

/// Parse an RSS 2.0 document into items. Returns items owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, xml: []const u8) ![]RawItem {
    var items: std.ArrayList(RawItem) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<item>")) |start| {
        const content_start = start + "<item>".len;
        const end = std.mem.indexOfPos(u8, xml, content_start, "</item>") orelse break;
        const block = xml[content_start..end];
        pos = end + "</item>".len;
        const title_raw = fieldValue(block, "title") orelse continue;
        const link_raw = fieldValue(block, "link") orelse continue;
        const desc_raw = fieldValue(block, "description") orelse fieldValue(block, "content:encoded") orelse "";
        const title = try cleanText(alloc, title_raw);
        const link = try cleanText(alloc, link_raw);
        const desc = try cleanText(alloc, desc_raw);
        var pub_date: ?i64 = null;
        if (fieldValue(block, "pubDate")) |pd| pub_date = parsePubDate(pd);
        if (title.len == 0 or link.len == 0) continue;
        try items.append(alloc, .{
            .title = title,
            .link = link,
            .description = desc,
            .pub_date = pub_date,
        });
    }
    return items.toOwnedSlice(alloc);
}

test "decodeEntities handles named and numeric refs" {
    const d = try decodeEntities(std.testing.allocator, "Fish &amp; Chips &lt;tag&gt; &#65; &#x42;");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("Fish & Chips <tag> A B", d);
}

test "stripTags and cleanText" {
    const c = try cleanText(std.testing.allocator, "<p>Hello   <b>world</b>\nnext</p> &amp; more");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("Hello world next & more", c);
}

test "parsePubDate handles RFC 822 and GMT" {
    // 2026-11-12 10:00:00 UTC = 1794477600 (verified with python datetime)
    try std.testing.expectEqual(@as(?i64, 1794477600), parsePubDate("Thu, 12 Nov 2026 10:00:00 +0000"));
    try std.testing.expectEqual(@as(?i64, 1794477600), parsePubDate("Thu, 12 Nov 2026 10:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1794477600), parsePubDate("Thu, 12 Nov 2026 11:00:00 +0100"));
    try std.testing.expectEqual(@as(?i64, null), parsePubDate("not a date"));
}

test "parse handles CDATA, entities, and skips empty items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const xml =
        \\<?xml version="1.0"?><rss><channel>
        \\<item><title><![CDATA[Fuel &amp; Power in Monrovia]]></title><link>https://example.com/1</link><description><![CDATA[<p>Queues at stations.</p>]]></description><pubDate>Thu, 12 Nov 2026 10:00:00 +0000</pubDate></item>
        \\<item><title>Second story</title><link>https://example.com/2</link><description>Plain text.</description></item>
        \\<item><title></title><link>https://example.com/3</link></item>
        \\</channel></rss>
    ;
    const items = try parse(alloc, xml);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("Fuel & Power in Monrovia", items[0].title);
    try std.testing.expectEqualStrings("Queues at stations.", items[0].description);
    try std.testing.expectEqual(@as(?i64, 1794477600), items[0].pub_date);
    try std.testing.expectEqualStrings("Second story", items[1].title);
    try std.testing.expectEqual(@as(?i64, null), items[1].pub_date);
}

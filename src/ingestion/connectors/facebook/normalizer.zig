//! Post normalization (Roadmap 3.2, design doc section 7).
//!
//! Graph API post -> FacebookPost (the design doc's record shape) ->
//! Pulse Document, the same shape RSS items become, so Facebook
//! posts flow through the same pipeline: validation, embedding,
//! entity/event knowledge, search. Engagement stays nullable all
//! the way down — a missing metric is never defaulted to zero.
//!
//! Title rule: the post's first line, trimmed, truncated to 120
//! bytes. Posts with no message text are skipped by the collector
//! (nothing to index, nothing to cite).

const std = @import("std");
const types = @import("../../../common/types.zig");
const entities = @import("../../../engine/entities.zig");
const geo = @import("../../../engine/geo.zig");
const language = @import("../../../engine/language.zig");
const providers = @import("../../../ai/providers.zig");
const fb_types = @import("types.zig");
const client = @import("client.zig");

/// Days from civil date (Howard Hinnant's algorithm) — needed to
/// turn a Graph API created_time into Unix seconds without any
/// external date library.
fn daysFromCivil(y_in: i64, m: u64, d: u64) i64 {
    const y: i64 = if (m <= 2) y_in - 1 else y_in;
    const era: i64 = if (y >= 0) y else y - 399;
    const era_div: i64 = @divFloor(era, 400);
    const yoe: u64 = @intCast(y - era_div * 400);
    const mp: u64 = if (m > 2) m - 3 else m + 9;
    const doy: u64 = (153 * mp + 2) / 5 + d - 1;
    const doe: i64 = @intCast(yoe * 365 + yoe / 4 - yoe / 100 + doy);
    return era_div * 146097 + doe - 719468;
}

fn parseU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + @as(u64, c - '0');
    }
    return n;
}

/// Parse a Graph API created_time into Unix seconds.
/// Accepted: "2026-11-12T10:00:00+0000", "...T10:00:00+00:00",
/// "...T10:00:00Z". Returns null on any malformed input — the
/// document then carries published_at = null rather than a wrong
/// timestamp.
pub fn parseCreatedTime(s: []const u8) ?i64 {
    // Minimum: YYYY-MM-DDTHH:MM:SS (19 chars).
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = parseU64(s[0..4]) orelse return null;
    const month = parseU64(s[5..7]) orelse return null;
    const day = parseU64(s[8..10]) orelse return null;
    const hour = parseU64(s[11..13]) orelse return null;
    const minute = parseU64(s[14..16]) orelse return null;
    const sec = parseU64(s[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or sec > 60) return null;
    var offset: i64 = 0;
    const rest = s[19..];
    if (rest.len == 0) {
        // No offset: treat as UTC (Graph API always sends one, but
        // never guess a local zone).
    } else if (std.mem.eql(u8, rest, "Z")) {
        offset = 0;
    } else if (rest.len == 5 and (rest[0] == '+' or rest[0] == '-')) {
        const oh = parseU64(rest[1..3]) orelse return null;
        const om = parseU64(rest[3..5]) orelse return null;
        offset = @as(i64, @intCast(oh * 3600 + om * 60)) * @as(i64, if (rest[0] == '+') 1 else -1);
    } else if (rest.len == 6 and rest[0] != 'Z' and rest[3] == ':' and (rest[0] == '+' or rest[0] == '-')) {
        const oh = parseU64(rest[1..3]) orelse return null;
        const om = parseU64(rest[4..6]) orelse return null;
        offset = @as(i64, @intCast(oh * 3600 + om * 60)) * @as(i64, if (rest[0] == '+') 1 else -1);
    } else {
        return null;
    }
    const days = daysFromCivil(@intCast(year), month, day);
    return days * 86400 + @as(i64, @intCast(hour * 3600 + minute * 60 + sec)) - offset;
}

/// RawPost -> FacebookPost (design doc record shape). The post_id is
/// the Graph API id ("<page_id>_<post_id>"); page_id is taken from
/// the registry entry that produced the fetch.
pub fn toFacebookPost(raw: client.RawPost, page_id: []const u8, collected_at: i64) fb_types.FacebookPost {
    return .{
        .page_id = page_id,
        .post_id = raw.id,
        .content = raw.message,
        .permalink = raw.permalink_url,
        .published_at = raw.created_time,
        .collected_at = collected_at,
        .engagement = .{
            .reactions = raw.reactions,
            .comments = raw.comments,
            .shares = raw.shares,
        },
        .permissions_verified = true,
    };
}

fn titleFromContent(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const first_line = std.mem.sliceTo(content, '\n');
    const trimmed = std.mem.trim(u8, first_line, " \t\r");
    const cap: usize = 120;
    if (trimmed.len <= cap) return alloc.dupe(u8, trimmed);
    return alloc.dupe(u8, trimmed[0..cap]);
}

/// FacebookPost -> Pulse Document. Mirrors
/// ingestion/normalizer.normalize: entity extraction, geo-tag from
/// the verified OSM table, extractive summary, language ID. The
/// source_id is "facebook:<page_id>" so health + counts are
/// per-page; reliability comes from the page's registry priority.
pub fn toDocument(
    alloc: std.mem.Allocator,
    post: fb_types.FacebookPost,
    page_name: []const u8,
    priority: fb_types.PagePriority,
) !types.Document {
    const source_id = try std.fmt.allocPrint(alloc, "facebook:{s}", .{post.page_id});
    const source_url = try std.fmt.allocPrint(alloc, "https://www.facebook.com/{s}", .{post.page_id});
    const title = try titleFromContent(alloc, post.content);
    const text = try alloc.dupe(u8, post.content);
    const combined = try std.mem.concat(alloc, u8, &.{ title, " ", text });
    const ent = try entities.extract(alloc, combined);
    const id = try types.contentHash(alloc, source_id, post.permalink, title);
    var lat: ?f64 = null;
    var lon: ?f64 = null;
    if (ent.cities.len > 0) {
        if (geo.lookup(ent.cities[0])) |p| {
            lat = p.lat;
            lon = p.lon;
        }
    }
    if (lat == null and ent.counties.len > 0) {
        if (geo.countyPoint(ent.counties[0])) |p| {
            lat = p.lat;
            lon = p.lon;
        }
    }
    var summarizer = providers.ExtractiveSummarizer{};
    const raw_summary = try summarizer.provider().summarize(alloc, text, 2);
    const summary: ?[]const u8 = if (std.mem.eql(u8, raw_summary, text)) blk: {
        alloc.free(raw_summary);
        break :blk null;
    } else raw_summary;
    const lang = language.identify(combined);
    return .{
        .id = id,
        .source_id = source_id,
        .source_name = page_name,
        .source_url = source_url,
        .title = title,
        .url = post.permalink,
        .text = text,
        .published_at = parseCreatedTime(post.published_at),
        .fetched_at = post.collected_at,
        .reliability = priority.reliability(),
        .topics = ent.topics,
        .content_hash = id,
        .lat = lat,
        .lon = lon,
        .summary = summary,
        .lang = lang,
    };
}

test "normalizer parses created_time offsets" {
    // 2026-11-12T10:00:00Z == 1794477600.
    try std.testing.expectEqual(@as(?i64, 1794477600), parseCreatedTime("2026-11-12T10:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1794477600), parseCreatedTime("2026-11-12T10:00:00+0000"));
    try std.testing.expectEqual(@as(?i64, 1794477600), parseCreatedTime("2026-11-12T10:00:00+00:00"));
    try std.testing.expectEqual(@as(?i64, 1794477600), parseCreatedTime("2026-11-12T12:00:00+0200"));
    try std.testing.expectEqual(@as(?i64, null), parseCreatedTime("not a date"));
    try std.testing.expectEqual(@as(?i64, null), parseCreatedTime("2026-13-12T10:00:00Z"));
    try std.testing.expectEqual(@as(?i64, null), parseCreatedTime("2026-11-12 10:00:00"));
}

test "normalizer builds a document from a Facebook post" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const raw = client.RawPost{
        .id = "456_789",
        .message = "Fuel shortage hits Monrovia\nStations report long queues.",
        .created_time = "2026-11-12T10:00:00+0000",
        .permalink_url = "https://www.facebook.com/456/posts/789",
        .reactions = 12,
        .comments = null,
        .shares = 5,
    };
    const post = toFacebookPost(raw, "456", 1794497000);
    try std.testing.expectEqualStrings("facebook", post.source_type);
    try std.testing.expect(post.permissions_verified);
    try std.testing.expectEqual(@as(?u64, 12), post.engagement.reactions);
    try std.testing.expectEqual(@as(?u64, null), post.engagement.comments);
    const doc = try toDocument(alloc, post, "FrontPage Africa", .media);
    try std.testing.expectEqualStrings("Fuel shortage hits Monrovia", doc.title);
    try std.testing.expectEqualStrings("facebook:456", doc.source_id);
    try std.testing.expectEqualStrings("FrontPage Africa", doc.source_name);
    try std.testing.expectEqual(@as(?i64, 1794477600), doc.published_at);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), doc.reliability, 0.001);
    try std.testing.expect(doc.lat != null);
    try std.testing.expectApproxEqAbs(@as(f64, 6.3204), doc.lat.?, 0.001);
    var saw_energy = false;
    for (doc.topics) |t| {
        if (std.mem.eql(u8, t, "energy")) saw_energy = true;
    }
    try std.testing.expect(saw_energy);
}

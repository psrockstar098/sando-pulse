//! Unified search: one query, three sources, one answer.
//!
//! POST /v1/query fans out to (a) Pulse's own local index — the RSS
//! feeds plus the Facebook posts the worker ingested — (b) the web
//! through the bundled SearXNG instance, and (c) Facebook/social,
//! which is the same local index surfaced distinctly: documents whose
//! source_id starts with "facebook:" are the social results. There is
//! no live per-query Graph API call: Meta has no general post search,
//! and a live fetch per query would burn rate limit for data the
//! worker already collected. The `facebook` source status says honestly
//! whether the connector is configured; when it is not, the social
//! list is empty and no post is ever invented.
//!
//! Rules, all testable here:
//! - Web results are deduplicated against local results by normalized
//!   URL (lowercase, no trailing slash, no tracking params, no
//!   fragment). A New Dawn article found locally and on the web
//!   appears once, locally. Web results that duplicate each other
//!   (two engines, same link) also collapse to the first.
//! - Order is fixed and stated: local results first (Pulse's own
//!   sources, fused-score order), then web results in SearXNG's
//!   order. No score is invented for web results — SearXNG already
//!   ranked them, and the ranking is reported as-is.
//! - Every source reports a status: local ok, web ok / unavailable /
//!   timeout / error, facebook configured / not_configured. An empty
//!   result list is a valid answer, never an error.

const std = @import("std");
const searxng = @import("searxng.zig");

pub const WebResult = searxng.WebResult;

/// What the web leg did for this query. `unavailable` = no SearXNG
/// URL configured; `timeout` = the leg was still running when the
/// deadline passed (its results are dropped, never half-rendered);
/// `err` = SearXNG answered with an error or an unusable response.
pub const WebStatus = enum { ok, unavailable, timeout, err };

pub fn webStatusName(s: WebStatus) []const u8 {
    return switch (s) {
        .ok => "ok",
        .unavailable => "unavailable",
        .timeout => "timeout",
        .err => "error",
    };
}

/// The unified data POST /v1/query renders. The web slice borrows its
/// strings from the SearXNG response (owned by the fan-out task arena
/// until the caller joins it — render before joining, as the enrichment
/// sections already do).
pub const Unified = struct {
    web: []searxng.WebResult = &.{},
    web_complete: bool = true,
    web_status: WebStatus = .unavailable,
    web_detail: ?[]const u8 = null,
    facebook_configured: bool = false,
};

/// True when a document came from the Facebook connector (its
/// source_id is "facebook:<page_id>" — see
/// ingestion/connectors/facebook/normalizer.zig).
pub fn isSocialSource(source_id: []const u8) bool {
    return std.mem.startsWith(u8, source_id, "facebook:");
}

fn isTrackingParam(key: []const u8) bool {
    if (std.mem.eql(u8, key, "fbclid") or std.mem.eql(u8, key, "gclid") or std.mem.eql(u8, key, "msclkid")) return true;
    return std.mem.startsWith(u8, key, "utm_");
}

/// Normalize a URL for dedupe comparison: lowercase, no fragment, no
/// trailing slash, no tracking query params (utm_*, fbclid, gclid,
/// msclkid). Everything else — path, remaining params, order — is
/// kept verbatim, so two different articles never collapse.
pub fn normalizeUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    // Cut the fragment first: same page with or without #anchor.
    const no_frag = if (std.mem.indexOfScalar(u8, url, '#')) |i| url[0..i] else url;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Lowercase + split off the query string.
    const qi = std.mem.indexOfScalar(u8, no_frag, '?');
    const base = if (qi) |i| no_frag[0..i] else no_frag;
    for (base) |c| try out.append(alloc, std.ascii.toLower(c));
    if (qi) |i| {
        const query = no_frag[i + 1 ..];
        var kept: std.ArrayList(u8) = .empty;
        defer kept.deinit(alloc);
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |param| {
            if (param.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, param, '=') orelse param.len;
            const key = param[0..eq];
            // Keys were lowercased already only if we lowercased the
            // whole string — we did not; compare case-insensitively.
            var key_lower: [16]u8 = undefined;
            const kl = if (key.len <= key_lower.len) blk: {
                for (key, 0..) |c, j| key_lower[j] = std.ascii.toLower(c);
                break :blk key_lower[0..key.len];
            } else key;
            if (isTrackingParam(kl)) continue;
            if (kept.items.len > 0) try kept.append(alloc, '&');
            for (param) |c| try kept.append(alloc, std.ascii.toLower(c));
        }
        if (kept.items.len > 0) {
            try out.append(alloc, '?');
            try out.appendSlice(alloc, kept.items);
        }
    }
    // One trailing slash goes (never the "://" of the scheme).
    if (out.items.len > 0 and out.items[out.items.len - 1] == '/' and !std.mem.endsWith(u8, out.items, "://")) {
        _ = out.pop();
    }
    return out.toOwnedSlice(alloc);
}

/// Drop web results whose normalized URL already appears among the
/// local result URLs, or among an earlier web result. The returned
/// slice holds the same WebResult values (strings borrowed from the
/// caller); only the slice itself is newly allocated. `scratch` is a
/// throwaway arena for the normalized forms.
pub fn dedupeWeb(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    local_urls: []const []const u8,
    web: []const searxng.WebResult,
) ![]searxng.WebResult {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(scratch);
    for (local_urls) |u| {
        const n = try normalizeUrl(scratch, u);
        try seen.append(scratch, n);
    }
    var out: std.ArrayList(searxng.WebResult) = .empty;
    errdefer out.deinit(alloc);
    for (web) |r| {
        const n = try normalizeUrl(scratch, r.url);
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, n)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try seen.append(scratch, n);
        try out.append(alloc, r);
    }
    return out.toOwnedSlice(alloc);
}

test "unified: normalizeUrl lowercases, strips slash, fragment and trackers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = try normalizeUrl(alloc, "https://Example.COM/News/?utm_source=x&fbclid=abc#top");
    try std.testing.expectEqualStrings("https://example.com/news", a);
    const b = try normalizeUrl(alloc, "https://example.com/a?x=1&utm_medium=cpc&y=2");
    try std.testing.expectEqualStrings("https://example.com/a?x=1&y=2", b);
    const c = try normalizeUrl(alloc, "https://example.com/a");
    try std.testing.expectEqualStrings("https://example.com/a", c);
    const d = try normalizeUrl(alloc, "https://example.com/a?gclid=1");
    try std.testing.expectEqualStrings("https://example.com/a", d);
    const e = try normalizeUrl(alloc, "HTTPS://EXAMPLE.COM/A/?UTM_SOURCE=X");
    try std.testing.expectEqualStrings("https://example.com/a", e);
}

test "unified: dedupeWeb drops local dups, tracker variants and web-web dups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const local = [_][]const u8{"https://thenewdawnliberia.com/fuel-queues/"};
    const web = [_]searxng.WebResult{
        .{ .title = "Fuel", .url = "https://thenewdawnliberia.com/fuel-queues?utm_source=google", .content = "", .engine = "bing" },
        .{ .title = "Fuel 2", .url = "HTTPS://THENEWDAWNLIBERIA.COM/Fuel-Queues/", .content = "", .engine = "google" },
        .{ .title = "Other", .url = "https://example.com/other", .content = "", .engine = "duckduckgo" },
        .{ .title = "Other dup", .url = "https://example.com/other?fbclid=z", .content = "", .engine = "brave" },
        .{ .title = "Third", .url = "https://example.com/third", .content = "", .engine = "mojeek" },
    };
    const kept = try dedupeWeb(alloc, scratch.allocator(), &local, &web);
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("https://example.com/other", kept[0].url);
    try std.testing.expectEqualStrings("https://example.com/third", kept[1].url);
}

test "unified: dedupeWeb keeps everything when nothing overlaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const web = [_]searxng.WebResult{
        .{ .title = "A", .url = "https://a.example/1", .content = "", .engine = "bing" },
        .{ .title = "B", .url = "https://b.example/2", .content = "", .engine = "google" },
    };
    const kept = try dedupeWeb(alloc, scratch.allocator(), &.{}, &web);
    try std.testing.expectEqual(@as(usize, 2), kept.len);
}

test "unified: isSocialSource matches facebook: pages only" {
    try std.testing.expect(isSocialSource("facebook:106003915444667"));
    try std.testing.expect(!isSocialSource("new-dawn"));
    try std.testing.expect(!isSocialSource("facebook"));
    try std.testing.expect(!isSocialSource(""));
}

test "unified: webStatusName spells every status" {
    try std.testing.expectEqualStrings("ok", webStatusName(.ok));
    try std.testing.expectEqualStrings("unavailable", webStatusName(.unavailable));
    try std.testing.expectEqualStrings("timeout", webStatusName(.timeout));
    try std.testing.expectEqualStrings("error", webStatusName(.err));
}

//! Trust & Intelligence Engine, Phase 2: live account monitoring.
//!
//! The monitor answers, per source, "when did you last check, when
//! did you last succeed, when did something NEW arrive, and how
//! fresh is this source right now" — from the persisted source
//! health (`source_health`, migration 014 adds `last_new_at`) and
//! the newest document per source. Nothing here fetches anything:
//! the worker already records health on every run (pipeline
//! `recordHealth`); this module only assembles and interprets it.
//!
//! Freshness rule (documented in the API response): a source is
//! `fresh` when its last success is within twice the ingest
//! interval, `stale` when older, `unknown` when it has never
//! succeeded. A fetch that returns nothing new is NOT activity:
//! `last_new_at` moves only when a run inserts a document.
//!
//! Change detection, honestly labelled per channel:
//!   - RSS: `new_items_only` — a feed shows new items; it cannot
//!     report edits or deletions, and the monitor never claims it can.
//!   - Facebook: `webhook_events` — Meta webhooks report new posts,
//!     edits and deletions when the platform sends them, and the
//!     connector's poll reconciles anything a webhook missed.
//!     Without a token + registered pages the Facebook section
//!     reports unavailable with the exact reason, never empty data.
//!   - Disabled/removed sources: `none` — not monitored.
//!
//! Webhooks map onto the existing connector: the Facebook connector
//! already records notifications and marks pages due for
//! reconciliation (`recordWebhook` / `drainNotifications`); Phase 2
//! only labels those kinds for the monitor response.

const std = @import("std");
const sources = @import("../../ingestion/sources.zig");
const knowledge = @import("../../storage/knowledge.zig");

/// Freshness of one source's last successful check.
pub const Freshness = enum {
    fresh,
    stale,
    unknown,

    pub fn name(self: Freshness) []const u8 {
        return switch (self) {
            .fresh => "fresh",
            .stale => "stale",
            .unknown => "unknown",
        };
    }
};

/// Fresh within twice the ingest interval (the worker checks each
/// source about once per interval, so two intervals without a
/// success means the source is behind). Never succeeded → unknown.
pub fn freshness(now: i64, last_success_at: ?i64, interval_s: i64) Freshness {
    const last = last_success_at orelse return .unknown;
    const age = now - last;
    if (age < 0) return .fresh; // clock skew the safe way: trust the stamp
    return if (age <= 2 * interval_s) .fresh else .stale;
}

/// What change detection a channel can actually do (see module doc).
pub fn changeCapability(channel: []const u8, enabled: bool) []const u8 {
    if (!enabled) return "none";
    if (std.mem.eql(u8, channel, "facebook")) return "webhook_events";
    return "new_items_only";
}

/// A Meta webhook notification kind, labelled for the monitor.
/// Unknown kinds are passed through unchanged — never reclassified.
pub fn webhookChangeKind(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "feed")) return "new_post_or_update";
    if (std.mem.eql(u8, kind, "mention")) return "mention";
    if (std.mem.eql(u8, kind, "delete")) return "deleted_post";
    if (std.mem.eql(u8, kind, "edit")) return "edited_post";
    return kind;
}

/// The newest document the monitor saw for a source (title + url +
/// fetch time), for the "what changed last" line. Null when the
/// source has no documents yet.
pub const LatestDoc = struct {
    title: []const u8,
    url: []const u8,
    fetched_at: i64,
};

/// One source's monitoring state, as the API serves it.
pub const MonitorStatus = struct {
    source_id: []const u8,
    name: []const u8,
    channel: []const u8, // "rss" for the 12 registry outlets
    enabled: bool,
    last_checked_at: ?i64,
    last_success_at: ?i64,
    last_new_at: ?i64,
    consecutive_failures: usize,
    documents_total: usize,
    last_error: ?[]const u8,
    freshness: Freshness,
    change_detection: []const u8,
    latest: ?LatestDoc,
    note: []const u8,
};

/// Assemble one status from the registry source, its persisted
/// health (null when the worker has never recorded it), and its
/// newest document (null when it has none). All timestamps are unix
/// seconds; the response renders them as ISO strings.
pub fn statusFromHealth(
    source: sources.Source,
    health: ?knowledge.SourceHealth,
    latest: ?LatestDoc,
    now: i64,
    interval_s: i64,
) MonitorStatus {
    const channel = "rss";
    const h = health;
    return .{
        .source_id = source.id,
        .name = source.name,
        .channel = channel,
        .enabled = source.enabled,
        .last_checked_at = if (h) |hh| hh.last_run_at else null,
        .last_success_at = if (h) |hh| hh.last_success_at else null,
        .last_new_at = if (h) |hh| hh.last_new_at else null,
        .consecutive_failures = if (h) |hh| hh.consecutive_failures else 0,
        .documents_total = if (h) |hh| hh.docs_total else 0,
        .last_error = if (h) |hh| hh.last_error else null,
        .freshness = freshness(now, if (h) |hh| hh.last_success_at else null, interval_s),
        .change_detection = changeCapability(channel, source.enabled),
        .latest = latest,
        .note = if (!source.enabled)
            if (source.disabled_reason) |r| r else "Source disabled; not monitored."
        else if (h == null)
            "Never checked — the worker has not recorded a run for this source yet."
        else if (latest == null)
            "Checked, but no documents ingested yet."
        else
            "Monitored on the worker's ingest schedule.",
    };
}

/// Statuses for every registry source, in registry order. `healths`
/// and `latests` are parallel to `sources.sources` (null entries
/// allowed); the caller reads them from the knowledge store and the
/// document repository.
pub fn allStatuses(
    alloc: std.mem.Allocator,
    healths: []const ?knowledge.SourceHealth,
    latests: []const ?LatestDoc,
    now: i64,
    interval_s: i64,
) ![]MonitorStatus {
    var out: std.ArrayList(MonitorStatus) = .empty;
    for (sources.sources, 0..) |s, i| {
        try out.append(alloc, statusFromHealth(s, healths[i], latests[i], now, interval_s));
    }
    return out.toOwnedSlice(alloc);
}

test "freshness: unknown without success, fresh inside 2x interval, stale after" {
    try std.testing.expectEqual(Freshness.unknown, freshness(1000, null, 300));
    try std.testing.expectEqual(Freshness.fresh, freshness(1000, 900, 300));
    try std.testing.expectEqual(Freshness.fresh, freshness(1000, 400, 300)); // exactly 2x interval
    try std.testing.expectEqual(Freshness.stale, freshness(1000, 399, 300));
    try std.testing.expectEqual(Freshness.fresh, freshness(1000, 1000, 300));
    try std.testing.expectEqual(Freshness.stale, freshness(1000, 0, 300));
}

test "change capability: rss is new-items-only, facebook is webhooks, disabled is none" {
    try std.testing.expectEqualStrings("new_items_only", changeCapability("rss", true));
    try std.testing.expectEqualStrings("webhook_events", changeCapability("facebook", true));
    try std.testing.expectEqualStrings("none", changeCapability("rss", false));
    try std.testing.expectEqualStrings("none", changeCapability("facebook", false));
}

test "webhook kinds labelled, unknown kinds passed through" {
    try std.testing.expectEqualStrings("new_post_or_update", webhookChangeKind("feed"));
    try std.testing.expectEqualStrings("deleted_post", webhookChangeKind("delete"));
    try std.testing.expectEqualStrings("edited_post", webhookChangeKind("edit"));
    try std.testing.expectEqualStrings("mention", webhookChangeKind("mention"));
    try std.testing.expectEqualStrings("reactions", webhookChangeKind("reactions"));
}

test "statusFromHealth: no health record is unknown, never-checked" {
    const s = sources.find("new-dawn").?;
    const st = statusFromHealth(s, null, null, 1795000000, 300);
    try std.testing.expectEqualStrings("new-dawn", st.source_id);
    try std.testing.expectEqualStrings("rss", st.channel);
    try std.testing.expect(st.enabled);
    try std.testing.expectEqual(Freshness.unknown, st.freshness);
    try std.testing.expectEqual(@as(?i64, null), st.last_checked_at);
    try std.testing.expectEqual(@as(usize, 0), st.documents_total);
    try std.testing.expectEqualStrings("new_items_only", st.change_detection);
    try std.testing.expect(std.mem.indexOf(u8, st.note, "Never checked") != null);
}

test "statusFromHealth: healthy source is fresh with last-new stamp" {
    const s = sources.find("gnn-liberia").?;
    const h = knowledge.SourceHealth{
        .source_id = "gnn-liberia",
        .last_run_at = 1795000000,
        .last_success_at = 1794999900,
        .consecutive_failures = 0,
        .docs_total = 10,
        .last_new_at = 1794999000,
    };
    const st = statusFromHealth(s, h, .{ .title = "Fuel shortage", .url = "https://example.com/x", .fetched_at = 1794999000 }, 1795000000, 300);
    try std.testing.expectEqual(Freshness.fresh, st.freshness);
    try std.testing.expectEqual(@as(?i64, 1794999000), st.last_new_at);
    try std.testing.expectEqual(@as(usize, 10), st.documents_total);
    try std.testing.expectEqualStrings("Fuel shortage", st.latest.?.title);
}

test "statusFromHealth: failing source is stale and keeps its error" {
    const s = sources.find("the-news").?;
    const h = knowledge.SourceHealth{
        .source_id = "the-news",
        .last_run_at = 1795000000,
        .last_success_at = 1794900000, // ~28h ago
        .last_error = "fetch failed",
        .consecutive_failures = 3,
        .docs_total = 4,
    };
    const st = statusFromHealth(s, h, null, 1795000000, 300);
    try std.testing.expectEqual(Freshness.stale, st.freshness);
    try std.testing.expectEqual(@as(usize, 3), st.consecutive_failures);
    try std.testing.expectEqualStrings("fetch failed", st.last_error.?);
}

test "statusFromHealth: disabled source is not monitored" {
    const s = sources.find("bush-chicken").?;
    const st = statusFromHealth(s, null, null, 1795000000, 300);
    try std.testing.expect(!st.enabled);
    try std.testing.expectEqualStrings("none", st.change_detection);
    try std.testing.expect(std.mem.indexOf(u8, st.note, "parked") != null or std.mem.indexOf(u8, st.note, "disabled") != null or std.mem.indexOf(u8, st.note, "Domain") != null);
}

test "allStatuses covers all 12 registry sources in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var healths: [12]?knowledge.SourceHealth = undefined;
    for (&healths) |*h| h.* = null;
    var latests: [12]?LatestDoc = undefined;
    for (&latests) |*l| l.* = null;
    healths[1] = .{ .source_id = "daily-observer", .last_run_at = 1795000000, .last_success_at = 1795000000, .docs_total = 50, .last_new_at = 1795000000 };
    const all = try allStatuses(alloc, &healths, &latests, 1795000000, 300);
    try std.testing.expectEqual(@as(usize, 12), all.len);
    try std.testing.expectEqualStrings("frontpage-africa", all[0].source_id);
    try std.testing.expectEqual(Freshness.fresh, all[1].freshness);
    try std.testing.expectEqual(@as(usize, 50), all[1].documents_total);
    try std.testing.expectEqual(Freshness.unknown, all[2].freshness);
}

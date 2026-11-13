//! Source registry: Liberian news sources for Pulse.
//! Verified live 2026-11-13 ~20:00 GMT from this VM (curl, RSS fetch).
//! A source is `enabled` ONLY if its feed returned real RSS with items.
//! Disabled entries stay in the registry with the honest reason, so a future
//! re-check can re-enable them — Pulse never pretends a dead source works.
//!
//! Verified live (9):
//!   New Dawn, Liberian Investigator, GNN Liberia, The News, Daily Observer,
//!   FrontPage Africa (needs a browser User-Agent — see fetchers.zig),
//!   KMTV (moved to mykmtvnews.com), The Analyst, Local Voices Liberia
//! Disabled (3) — the sites themselves are gone, not the feeds:
//!   Bush Chicken — domain parked (parking lander; verified 2026-11-13).
//!   Spoon TV     — website parked; network closed by court order Jul 2023,
//!                  live presence is Facebook only (needs the Meta app).
//!   New Republic — domain parked (resolves to a parking IP; verified 2026-11-13).

const std = @import("std");

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    home_url: []const u8,
    feed_url: []const u8,
    /// Design-doc reliability grades: news 0.70, government 0.88.
    reliability: f32,
    enabled: bool,
    disabled_reason: ?[]const u8 = null,
};

pub const sources: []const Source = &.{
    .{
        .id = "frontpage-africa",
        .name = "FrontPage Africa",
        .home_url = "https://frontpageafricaonline.com/",
        .feed_url = "https://frontpageafricaonline.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "daily-observer",
        .name = "Daily Observer",
        .home_url = "https://www.liberianobserver.com/",
        .feed_url = "http://www.liberianobserver.com/search/?f=rss&t=article&l=50&s=start_time&sd=desc",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "new-dawn",
        .name = "New Dawn",
        .home_url = "https://thenewdawnliberia.com/",
        .feed_url = "https://thenewdawnliberia.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "liberian-investigator",
        .name = "Liberian Investigator",
        .home_url = "https://liberianinvestigator.com/",
        .feed_url = "https://liberianinvestigator.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "gnn-liberia",
        .name = "GNN Liberia",
        .home_url = "https://gnnliberia.com/",
        .feed_url = "https://gnnliberia.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "kmtv",
        .name = "KMTV",
        .home_url = "https://mykmtvnews.com/",
        .feed_url = "https://mykmtvnews.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "spoon-tv",
        .name = "Spoon TV",
        .home_url = "https://www.spoonfmradio.com/",
        .feed_url = "https://www.spoonfmradio.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Website parked; network closed by court order Jul 2023, live presence is Facebook only (needs the Meta app) (verified 2026-11-13)",
    },
    .{
        .id = "bush-chicken",
        .name = "Bush Chicken",
        .home_url = "https://bushchicken.com/",
        .feed_url = "https://bushchicken.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Domain parked (parking lander page, no site) (verified 2026-11-13)",
    },
    .{
        .id = "new-republic",
        .name = "New Republic",
        .home_url = "https://www.newrepublicliberia.com/",
        .feed_url = "https://www.newrepublicliberia.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Domain parked (resolves to a parking IP; connection fails) (verified 2026-11-13)",
    },
    .{
        .id = "the-analyst",
        .name = "The Analyst",
        .home_url = "https://analystliberiaonline.com/",
        .feed_url = "https://analystliberiaonline.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "local-voices",
        .name = "Local Voices Liberia",
        .home_url = "https://localvoicesliberia.com/",
        .feed_url = "https://localvoicesliberia.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
    .{
        .id = "the-news",
        .name = "The News",
        .home_url = "https://thenewsnewspaperonline.com/",
        .feed_url = "https://thenewsnewspaperonline.com/feed/",
        .reliability = 0.70,
        .enabled = true,
    },
};

pub fn find(id: []const u8) ?Source {
    for (sources) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

pub fn enabledCount() usize {
    var n: usize = 0;
    for (sources) |s| {
        if (s.enabled) n += 1;
    }
    return n;
}

test "registry has 12 sources, 9 enabled" {
    try std.testing.expectEqual(@as(usize, 12), sources.len);
    try std.testing.expectEqual(@as(usize, 9), enabledCount());
    for (sources) |s| {
        try std.testing.expect(s.reliability > 0 and s.reliability <= 1);
        try std.testing.expect(s.feed_url.len > 0);
        if (!s.enabled) try std.testing.expect(s.disabled_reason != null);
    }
}

test "find returns known sources and null for unknown" {
    try std.testing.expect(find("new-dawn") != null);
    try std.testing.expectEqualStrings("New Dawn", find("new-dawn").?.name);
    try std.testing.expect(find("does-not-exist") == null);
}

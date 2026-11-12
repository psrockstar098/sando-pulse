//! Source registry: the first 10 Liberian news sources from the design doc.
//! Verified live 2026-11-12 ~17:00 GMT from this VM (curl, RSS fetch).
//! A source is `enabled` ONLY if its feed returned real RSS with items.
//! Disabled entries stay in the registry with the honest reason, so a future
//! re-check can re-enable them — Pulse never pretends a dead source works.
//!
//! Verified live (5):
//!   New Dawn, Liberian Investigator, GNN Liberia, The News, Daily Observer
//! Skipped (5):
//!   FrontPage Africa — Cloudflare bot challenge blocks plain HTTP clients.
//!   Bush Chicken     — feed URL returns a 114-byte lander redirect stub.
//!   Spoon TV (Spoon FM Radio) — same lander redirect stub, no content.
//!   New Republic     — domain parked on Hostinger DNS (no site at all).
//!   KMTV             — homepage loads, but no RSS feed or sitemap exists.

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
        .enabled = false,
        .disabled_reason = "Cloudflare bot challenge blocks non-browser HTTP clients (verified 2026-11-12)",
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
        .home_url = "https://kmtvliberia.com/",
        .feed_url = "https://kmtvliberia.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Homepage loads but no RSS feed or sitemap exists (verified 2026-11-12)",
    },
    .{
        .id = "spoon-tv",
        .name = "Spoon TV",
        .home_url = "https://www.spoonfmradio.com/",
        .feed_url = "https://www.spoonfmradio.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Feed URL returns a 114-byte lander redirect stub, no content (verified 2026-11-12)",
    },
    .{
        .id = "bush-chicken",
        .name = "Bush Chicken",
        .home_url = "https://bushchicken.com/",
        .feed_url = "https://bushchicken.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Feed URL returns a 114-byte lander redirect stub, no content (verified 2026-11-12)",
    },
    .{
        .id = "new-republic",
        .name = "New Republic",
        .home_url = "https://www.newrepublicliberia.com/",
        .feed_url = "https://www.newrepublicliberia.com/feed/",
        .reliability = 0.70,
        .enabled = false,
        .disabled_reason = "Domain parked on Hostinger DNS; site does not exist (verified 2026-11-12)",
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

test "registry has 10 sources, 5 enabled" {
    try std.testing.expectEqual(@as(usize, 10), sources.len);
    try std.testing.expectEqual(@as(usize, 5), enabledCount());
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

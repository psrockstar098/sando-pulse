//! Trust & Intelligence Engine, Phase 1: source profiles + county
//! categorization.
//!
//! A profile extends the existing ingestion registry
//! (`src/ingestion/sources.zig` — 12 real sources, 9 enabled) with
//! the fields the spec's source-profile table requires: identity,
//! location, coverage, activity, reliability, evidence, performance,
//! status. Profiles are DERIVED from the registry, never duplicated:
//! `profileFromSource` builds a profile from a `sources.Source`, so
//! the two can never drift apart.
//!
//! County assignment — read this before changing it:
//!   `county` is the outlet's BASE county (where it is headquartered),
//!   NOT its coverage. All 12 registry sources are national outlets
//!   headquartered in Monrovia, Montserrado (KMTV's own structured
//!   data confirms Camp Johnson Road, Monrovia, Montserrado —
//!   verified live 2026-11-14); their coverage is national. A county
//!   filter therefore answers "which sources are based in this
//!   county", and every county except Montserrado honestly reports
//!   zero sources until Phase 2's county-level discovery registers
//!   genuine county sources. Pulse NEVER invents a source to fill a
//!   county — a county with no qualifying sources shows none.
//!   One assignment is soft: Local Voices Liberia's newsroom base is
//!   not stated on its site, so its `county_confidence` is
//!   "unverified" and the note says so. Everything else is
//!   "verified".
//!
//! Honesty labels, Phase 1:
//!   - `reliability` is the registry's design-doc grade (news 0.70),
//!     NOT a computed credibility score. The 1-5 credibility score
//!     is Phase 4; nothing here scores a source.
//!   - `coverage` is "general" for every source: topic-level coverage
//!     profiling from ingested articles is a later phase. Do not
//!     invent per-source topic specializations.
//!   - `performance` is not measured in Phase 1 (null in the API)
//!     and `activity.posting_frequency` / `last_update` are null
//!     until the worker tracks per-source freshness (later phase).
//!     `activity.documents_total` IS live, from the store.
//!   - No verdicts: no claim statuses, no "False" anywhere. That is
//!     a later-phase decision (see the spec's D-notes).

const std = @import("std");
const sources = @import("../../ingestion/sources.zig");
const geo = @import("../../engine/geo.zig");
const history_mod = @import("source_history.zig");

/// Profile status (spec section 1). Only `active` and `removed` occur
/// in the seeded data: enabled sources are active, disabled sources
/// are removed because their sites are gone (see sources.zig).
/// `under_review` and `restricted` exist for later phases (a source
/// under credibility review, or one whose web presence is gone but
/// whose authorized social presence is still live).
pub const ProfileStatus = enum {
    active,
    under_review,
    restricted,
    removed,

    pub fn name(self: ProfileStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .under_review => "under_review",
            .restricted => "restricted",
            .removed => "removed",
        };
    }

    pub fn parse(s: []const u8) ?ProfileStatus {
        if (std.ascii.eqlIgnoreCase(s, "active")) return .active;
        if (std.ascii.eqlIgnoreCase(s, "under_review")) return .under_review;
        if (std.ascii.eqlIgnoreCase(s, "restricted")) return .restricted;
        if (std.ascii.eqlIgnoreCase(s, "removed")) return .removed;
        return null;
    }
};

/// One source profile. `district`/`community` are null for every
/// seeded source: national outlets have no district-level base, and
/// inventing one would be fabrication.
pub const SourceProfile = struct {
    id: []const u8,
    name: []const u8,
    /// Platform kind: "news" for the 12 registry outlets (online
    /// newspapers / news sites). Later phases add "facebook",
    /// "radio", "blogger", etc. for newly registered sources.
    platform: []const u8,
    home_url: []const u8,
    feed_url: []const u8,
    /// Base county (headquarters), see the module doc comment.
    county: []const u8,
    /// "verified" or "unverified" (see `county_note`).
    county_confidence: []const u8,
    county_note: []const u8,
    district: ?[]const u8 = null,
    community: ?[]const u8 = null,
    /// Coverage scope: "national" for the 12 registry outlets.
    /// Local Voices Liberia is "county": a community-reporter
    /// network whose coverage is county-level.
    scope: []const u8,
    /// Topic coverage. "general" for every seeded source — topic
    /// profiling from ingested articles is a later phase.
    coverage: []const []const u8,
    /// Registry design-doc grade, NOT a credibility score (Phase 4).
    reliability: f32,
    status: ProfileStatus,
    disabled_reason: ?[]const u8 = null,
};

/// One county's categorization: capital (from geo.county_capitals),
/// how many registry sources are based there, and an honest note.
pub const CountyCount = struct {
    county: []const u8,
    capital: []const u8,
    sources: usize,
    note: []const u8,
};

fn profileFromSource(s: sources.Source) SourceProfile {
    const is_local_voices = std.mem.eql(u8, s.id, "local-voices");
    return .{
        .id = s.id,
        .name = s.name,
        .platform = "news",
        .home_url = s.home_url,
        .feed_url = s.feed_url,
        .county = "Montserrado",
        .county_confidence = if (is_local_voices) "unverified" else "verified",
        .county_note = if (is_local_voices)
            "Community-reporter network; newsroom base not stated on the outlet's site — recorded as Montserrado (Monrovia media hub) pending verification. Coverage is county-level via community reporters."
        else
            "National outlet headquartered in Monrovia, Montserrado; coverage is national, not county-limited.",
        .scope = if (is_local_voices) "county" else "national",
        .coverage = &.{"general"},
        .reliability = s.reliability,
        .status = if (s.enabled) .active else .removed,
        .disabled_reason = s.disabled_reason,
    };
}

/// The last score noted for one source, so noteScore can tell a
/// real change from a recompute of the same score.
pub const LastRating = struct {
    rating: ?u8,
    total: f64,
};

/// The Phase 1 registry: the 12 profiles derived from the ingestion
/// registry, plus the history log. The log is seeded at init with one
/// `profile_created` entry per source — the registry really was
/// created at boot, so the entries are real, not backfilled history.
pub const Registry = struct {
    alloc: std.mem.Allocator,
    history: history_mod.SourceHistory,
    /// Last noted score per registry source (registry order). Null
    /// until a score is first computed.
    last_ratings: [sources.sources.len]?LastRating,

    pub fn init(alloc: std.mem.Allocator, now: i64) !Registry {
        var last_ratings: [sources.sources.len]?LastRating = undefined;
        for (&last_ratings) |*r| r.* = null;
        var reg = Registry{
            .alloc = alloc,
            .history = history_mod.SourceHistory.init(alloc),
            .last_ratings = last_ratings,
        };
        errdefer reg.history.deinit();
        for (sources.sources) |s| {
            try reg.history.record(s.id, "profile_created", "Source profile created (Trust & Intelligence Engine, Phase 1)", now);
        }
        return reg;
    }

    pub fn deinit(self: *Registry) void {
        self.history.deinit();
    }

    /// All 12 profiles, in registry order. Allocated on the caller's
    /// allocator (the server's per-request arena).
    pub fn allProfiles(self: *Registry, alloc: std.mem.Allocator) ![]SourceProfile {
        _ = self;
        var out: std.ArrayList(SourceProfile) = .empty;
        for (sources.sources) |s| try out.append(alloc, profileFromSource(s));
        return out.toOwnedSlice(alloc);
    }

    pub fn profile(self: *Registry, id: []const u8) ?SourceProfile {
        _ = self;
        const s = sources.find(id) orelse return null;
        return profileFromSource(s);
    }

    /// Record a computed score in the history log — but only when it
    /// CHANGED. A recompute of the same rating and total (within 0.01)
    /// writes nothing, so the log stays an audit trail of real
    /// changes, not a row per page view. The first score for a source
    /// is always recorded. `rating` is null for a provisional score.
    pub fn noteScore(self: *Registry, source_id: []const u8, rating: ?u8, total: f64, at: i64) !void {
        for (sources.sources, 0..) |s, i| {
            if (!std.mem.eql(u8, s.id, source_id)) continue;
            if (self.last_ratings[i]) |last| {
                if (last.rating == rating and @abs(last.total - total) < 0.01) return;
            }
            self.last_ratings[i] = .{ .rating = rating, .total = total };
            var rating_buf: [16]u8 = undefined;
            const rating_str = if (rating) |r| std.fmt.bufPrint(&rating_buf, "{d}/5", .{r}) catch "?" else "provisional";
            const detail = try std.fmt.allocPrint(self.alloc, "Credibility score {d:.2} (rating {s})", .{ total, rating_str });
            defer self.alloc.free(detail);
            try self.history.record(source_id, "score_changed", detail, at);
            return;
        }
    }

    /// Is `name` one of Liberia's 15 counties? Case-insensitive.
    /// The canonical list is geo.county_capitals — never duplicated.
    pub fn isKnownCounty(name: []const u8) bool {
        for (geo.county_capitals) |cc| {
            if (std.ascii.eqlIgnoreCase(cc.county, name)) return true;
        }
        return false;
    }

    /// Profiles based in one county (case-insensitive). Empty, never
    /// an error, for a known county with no sources — that is the
    /// honest answer until Phase 2 registers county sources.
    pub fn profilesForCounty(self: *Registry, alloc: std.mem.Allocator, county: []const u8) ![]SourceProfile {
        _ = self;
        var out: std.ArrayList(SourceProfile) = .empty;
        for (sources.sources) |s| {
            const p = profileFromSource(s);
            if (std.ascii.eqlIgnoreCase(p.county, county)) try out.append(alloc, p);
        }
        return out.toOwnedSlice(alloc);
    }

    /// All 15 counties with their source counts, in geo order.
    /// Montserrado holds the 12 national outlets; the other 14 are
    /// honestly zero until Phase 2.
    pub fn countByCounty(self: *Registry, alloc: std.mem.Allocator) ![]CountyCount {
        _ = self;
        var out: std.ArrayList(CountyCount) = .empty;
        for (geo.county_capitals) |cc| {
            var n: usize = 0;
            for (sources.sources) |s| {
                if (std.ascii.eqlIgnoreCase(profileFromSource(s).county, cc.county)) n += 1;
            }
            try out.append(alloc, .{
                .county = cc.county,
                .capital = cc.capital,
                .sources = n,
                .note = if (n == 0)
                    "No sources registered for this county yet — no registration mechanism exists yet; Phase 4 ranks the sources that are registered, it does not invent new ones."
                else
                    "National outlets based in Monrovia; coverage is national, not county-limited.",
            });
        }
        return out.toOwnedSlice(alloc);
    }

    /// History entries for one source, newest last (insertion order).
    pub fn historyFor(self: *Registry, alloc: std.mem.Allocator, id: []const u8) ![]history_mod.HistoryEntry {
        return self.history.forSource(alloc, id);
    }
};

test "phase 1: 12 profiles derived from the registry, all fields present" {
    const alloc = std.testing.allocator;
    var reg = try Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const all = try reg.allProfiles(alloc);
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 12), all.len);
    for (all) |p| {
        try std.testing.expect(p.id.len > 0);
        try std.testing.expect(p.name.len > 0);
        try std.testing.expectEqualStrings("news", p.platform);
        try std.testing.expect(p.home_url.len > 0);
        try std.testing.expect(p.feed_url.len > 0);
        try std.testing.expect(Registry.isKnownCounty(p.county));
        try std.testing.expect(p.coverage.len > 0);
        try std.testing.expect(p.reliability > 0 and p.reliability <= 1);
        // The profile mirrors the registry exactly.
        const s = sources.find(p.id).?;
        try std.testing.expectEqualStrings(s.name, p.name);
        try std.testing.expectEqual(s.reliability, p.reliability);
        try std.testing.expectEqual(s.enabled, p.status == .active);
    }
}

test "phase 1: status mapping — 9 active, 3 removed" {
    const alloc = std.testing.allocator;
    var reg = try Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const all = try reg.allProfiles(alloc);
    defer alloc.free(all);
    var active: usize = 0;
    var removed: usize = 0;
    for (all) |p| {
        if (p.status == .active) active += 1;
        if (p.status == .removed) removed += 1;
        if (p.status == .removed) try std.testing.expect(p.disabled_reason != null);
    }
    try std.testing.expectEqual(@as(usize, 9), active);
    try std.testing.expectEqual(@as(usize, 3), removed);
}

test "phase 1: county categorization — Montserrado 12, every other county 0" {
    const alloc = std.testing.allocator;
    var reg = try Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const counties = try reg.countByCounty(alloc);
    defer alloc.free(counties);
    try std.testing.expectEqual(@as(usize, 15), counties.len);
    var total: usize = 0;
    for (counties) |c| {
        total += c.sources;
        if (std.mem.eql(u8, c.county, "Montserrado")) {
            try std.testing.expectEqual(@as(usize, 12), c.sources);
            try std.testing.expectEqualStrings("Monrovia", c.capital);
        } else {
            try std.testing.expectEqual(@as(usize, 0), c.sources);
        }
    }
    try std.testing.expectEqual(@as(usize, 12), total);
    // Case-insensitive county lookup; unknown county is not known.
    try std.testing.expect(Registry.isKnownCounty("nimba"));
    try std.testing.expect(Registry.isKnownCounty("Grand Cape Mount"));
    try std.testing.expect(!Registry.isKnownCounty("No Such County"));
    const nimba = try reg.profilesForCounty(alloc, "Nimba");
    defer alloc.free(nimba);
    try std.testing.expectEqual(@as(usize, 0), nimba.len);
    const mont = try reg.profilesForCounty(alloc, "montserrado");
    defer alloc.free(mont);
    try std.testing.expectEqual(@as(usize, 12), mont.len);
}

test "phase 1: profile lookup + local-voices county is unverified" {
    const alloc = std.testing.allocator;
    var reg = try Registry.init(alloc, 1763145600);
    defer reg.deinit();
    const fpa = reg.profile("frontpage-africa").?;
    try std.testing.expectEqualStrings("FrontPage Africa", fpa.name);
    try std.testing.expectEqualStrings("Montserrado", fpa.county);
    try std.testing.expectEqualStrings("verified", fpa.county_confidence);
    try std.testing.expectEqualStrings("national", fpa.scope);
    try std.testing.expect(reg.profile("does-not-exist") == null);
    const lv = reg.profile("local-voices").?;
    try std.testing.expectEqualStrings("unverified", lv.county_confidence);
    try std.testing.expectEqualStrings("county", lv.scope);
}

test "phase 1: status parse round-trips, rejects unknown" {
    try std.testing.expectEqual(ProfileStatus.active, ProfileStatus.parse("active").?);
    try std.testing.expectEqual(ProfileStatus.under_review, ProfileStatus.parse("UNDER_REVIEW").?);
    try std.testing.expectEqual(ProfileStatus.restricted, ProfileStatus.parse("restricted").?);
    try std.testing.expectEqual(ProfileStatus.removed, ProfileStatus.parse("removed").?);
    try std.testing.expect(ProfileStatus.parse("bogus") == null);
    try std.testing.expectEqualStrings("under_review", ProfileStatus.under_review.name());
}

test "phase 1: registry init seeds one profile_created entry per source" {
    const alloc = std.testing.allocator;
    var reg = try Registry.init(alloc, 1763145600);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 12), reg.history.count());
    const hist = try reg.historyFor(alloc, "new-dawn");
    defer alloc.free(hist);
    try std.testing.expectEqual(@as(usize, 1), hist.len);
    try std.testing.expectEqualStrings("profile_created", hist[0].action);
    try std.testing.expectEqual(@as(i64, 1763145600), hist[0].at);
    const none = try reg.historyFor(alloc, "does-not-exist");
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

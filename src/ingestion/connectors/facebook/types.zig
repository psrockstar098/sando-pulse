//! Facebook connector types (Roadmap 3.2, design doc
//! ~/workspace/sando-pulse-facebook-connector.md).
//!
//! The internal record shape follows the design doc exactly:
//! source_type / page_id / post_id / content / permalink /
//! published_at / collected_at / engagement (nullable) /
//! permissions_verified. Engagement values are nullable because
//! Facebook may not expose every metric.

const std = @import("std");

/// Engagement metrics as exposed by the Graph API. Every field is
/// nullable: reactions/comments/shares are permission- and
/// field-dependent, and a missing metric is recorded as null —
/// never invented, never defaulted to zero.
pub const Engagement = struct {
    reactions: ?u64 = null,
    comments: ?u64 = null,
    shares: ?u64 = null,
};

/// One normalized Facebook post — the design doc's record shape.
pub const FacebookPost = struct {
    source_type: []const u8 = "facebook",
    page_id: []const u8,
    post_id: []const u8,
    content: []const u8,
    permalink: []const u8,
    /// ISO-8601 as returned by the Graph API (created_time).
    published_at: []const u8,
    /// Unix seconds when Pulse collected the post.
    collected_at: i64,
    engagement: Engagement = .{},
    /// True only when the post was fetched with an authorized token
    /// for a page in the authorized registry.
    permissions_verified: bool,
};

/// Registry priority from the design doc: 1 = Liberian media orgs,
/// 2 = community/county sources, 3 = public-interest/official.
pub const PagePriority = enum(u8) {
    media = 1,
    community = 2,
    official = 3,

    pub fn name(self: PagePriority) []const u8 {
        return switch (self) {
            .media => "media",
            .community => "community",
            .official => "official",
        };
    }

    /// Reliability grade for documents from a page of this priority.
    /// Mirrors the source-registry grades (news 0.70, government
    /// 0.88): media pages are news-grade, official pages are
    /// government-grade, community pages are lower — a community
    /// post is a lead, not a corroborated report.
    pub fn reliability(self: PagePriority) f32 {
        return switch (self) {
            .media => 0.70,
            .community => 0.55,
            .official => 0.85,
        };
    }
};

/// One registry entry (config, not code — see
/// config/facebook-pages.example.json). `page_id` is empty until the
/// Page is registered after a partnership / authorization step;
/// empty entries are "pending" and are never fetched.
pub const PageEntry = struct {
    page_id: []const u8,
    name: []const u8,
    priority: u8,
    category: []const u8,
    notes: []const u8 = "",

    pub fn registered(self: PageEntry) bool {
        return self.page_id.len > 0;
    }

    pub fn priorityEnum(self: PageEntry) PagePriority {
        return switch (self.priority) {
            1 => .media,
            2 => .community,
            else => .official,
        };
    }
};

/// One webhook notification as recorded by the receiver. Webhooks
/// notify Pulse of a change; they carry NO post content — the worker
/// fetches the permitted content through the Graph API afterwards
/// (design doc section 4).
pub const WebhookNotification = struct {
    page_id: []const u8,
    /// Change field, e.g. "feed".
    kind: []const u8,
    /// Object id from the notification, if present.
    object_id: []const u8 = "",
    /// Meta's entry time (seconds) — the same across retried
    /// deliveries of one notification, so it (not the server's
    /// receipt time) keys the dedupe id.
    source_time: i64 = 0,
    received_at: i64,
    /// Set when the worker has polled the page for this notification.
    processed_at: ?i64 = null,
};

test "priority reliability grades" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), PagePriority.media.reliability(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), PagePriority.community.reliability(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), PagePriority.official.reliability(), 0.001);
    try std.testing.expectEqual(PagePriority.media, (PageEntry{ .page_id = "", .name = "x", .priority = 1, .category = "media" }).priorityEnum());
    try std.testing.expect(!(PageEntry{ .page_id = "", .name = "x", .priority = 1, .category = "media" }).registered());
    try std.testing.expect((PageEntry{ .page_id = "123", .name = "x", .priority = 1, .category = "media" }).registered());
}

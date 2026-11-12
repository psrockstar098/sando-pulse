//! Polling fallback + periodic reconciliation (Roadmap 3.2, design
//! doc sections 4 and 9).
//!
//! Webhooks notify; they do not deliver content, and notifications
//! can be missed or delayed — so every registered page is also
//! polled on a schedule, and a page whose notifications were missed
//! or whose last successful poll is stale is reconciled with a full
//! re-poll. Polling is the fallback that makes the connector work
//! even when webhooks are never configured.

const std = @import("std");

pub const PageState = struct {
    page_id: []const u8,
    last_poll_at: ?i64 = null,
    last_success_at: ?i64 = null,
    consecutive_failures: u32 = 0,
    /// Webhook notifications received but not yet followed by a
    /// successful poll of the page.
    missed_notifications: u32 = 0,

    /// Due for a poll: never polled, or the interval has elapsed
    /// since the last poll attempt.
    pub fn isDue(self: PageState, now: i64, interval_s: u64) bool {
        const last = self.last_poll_at orelse return true;
        return now - last >= @as(i64, @intCast(interval_s));
    }

    /// Needs reconciliation: missed notifications exist, or the last
    /// successful poll is older than twice the interval (the page
    /// has gone stale — fetch it regardless of the normal schedule).
    pub fn needsReconciliation(self: PageState, now: i64, interval_s: u64) bool {
        if (self.missed_notifications > 0) return true;
        const last = self.last_success_at orelse return false;
        return now - last >= 2 * @as(i64, @intCast(interval_s));
    }

    pub fn markPolled(self: *PageState, now: i64) void {
        self.last_poll_at = now;
    }

    pub fn markSuccess(self: *PageState, now: i64) void {
        self.last_success_at = now;
        self.consecutive_failures = 0;
        self.missed_notifications = 0;
    }

    pub fn markFailure(self: *PageState) void {
        self.consecutive_failures += 1;
    }

    pub fn markMissed(self: *PageState) void {
        self.missed_notifications += 1;
    }
};

test "scheduler: never-polled is due; missed notifications force reconciliation" {
    var s = PageState{ .page_id = "123" };
    try std.testing.expect(s.isDue(1000, 900));
    try std.testing.expect(!s.needsReconciliation(1000, 900));
    s.markPolled(1000);
    s.markSuccess(1000);
    try std.testing.expect(!s.isDue(1500, 900));
    try std.testing.expect(s.isDue(1900, 900));
    try std.testing.expect(!s.needsReconciliation(1900, 900));
    try std.testing.expect(s.needsReconciliation(2800, 900));
    s.markMissed();
    try std.testing.expect(s.needsReconciliation(1500, 900));
    s.markSuccess(1500);
    try std.testing.expect(!s.needsReconciliation(1500, 900));
    try std.testing.expectEqual(@as(u32, 0), s.missed_notifications);
    s.markFailure();
    s.markFailure();
    try std.testing.expectEqual(@as(u32, 2), s.consecutive_failures);
}

//! Knowledge maintenance (Roadmap 3.5): retention, compressed archives,
//! duplicate elimination, historical aggregation, and concise event
//! summaries. Runs on a schedule from the worker loop and on demand via
//! `pulse maintenance`. Never deletes a document without archiving it
//! first; never invents data — aggregation only counts what is stored.

const std = @import("std");

/// Retention policy (env: PULSE_RETENTION_DAYS, PULSE_ARCHIVE_DIR).
/// Documents older than `docs_retention_days` (by fetched_at) are
/// archived as compressed JSONL and then deleted from the store.
/// Events, entities, topics, and monthly aggregates are never deleted —
/// the historical record survives retention.
pub const RetentionPolicy = struct {
    docs_retention_days: u32 = 365,
    archive_dir: []const u8 = "archive",
};

test "retention policy defaults are sane" {
    const p = RetentionPolicy{};
    try std.testing.expectEqual(@as(u32, 365), p.docs_retention_days);
    try std.testing.expectEqualStrings("archive", p.archive_dir);
}

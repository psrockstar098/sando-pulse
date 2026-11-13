//! Event intelligence (Roadmap 4.1): importance scoring, source
//! corroboration, conflicting-report detection, correction/retraction
//! tracking, event timelines.
//!
//! Pure functions over an event's documents — no I/O, no store.
//! The knowledge store supplies the docs (`eventDocs`); the pipeline
//! scans for retraction markers at ingest; the server renders the
//! results. Nothing here claims certainty it does not have:
//! conflicts are reported as *possible* divergent reports (a
//! heuristic on title similarity), and retraction status comes only
//! from the publisher's own words (correction/retraction markers).

const std = @import("std");
const format = @import("../common/format.zig");
const knowledge = @import("../storage/knowledge.zig");
const fuzzy = @import("../engine/fuzzy.zig");

/// A document as the intelligence layer sees it (from `eventDocs`).
pub const EventDoc = knowledge.EventDoc;

/// Importance 0..1: doc_count (log-scaled, saturates ~20 docs),
/// distinct sources (saturates ~5), and recency (last_seen age).
/// Weights: coverage 0.4, corroboration 0.3, recency 0.3.
pub fn importanceScore(doc_count: usize, distinct_sources: usize, age_s: i64) f64 {
    const docs_f = @as(f64, @floatFromInt(@min(doc_count, 20)));
    const coverage = @log(docs_f + 1.0) / @log(21.0);
    const src_f = @as(f64, @floatFromInt(@min(distinct_sources, 5)));
    const corroboration_score = src_f / 5.0;
    const age_f = @as(f64, @floatFromInt(@max(age_s, 0)));
    // Recency decays over 7 days: 1.0 fresh, ~0.5 at 2 days, ~0 at 7.
    const recency = @exp(-age_f / (2.0 * 86400.0));
    return 0.4 * coverage + 0.3 * corroboration_score + 0.3 * recency;
}

/// Distinct source ids among the docs.
pub fn corroboration(alloc: std.mem.Allocator, docs: []const EventDoc) !usize {
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (docs) |d| {
        try seen.put(d.source_id, {});
    }
    return seen.count();
}

/// Markers that mean the publisher is correcting its own reporting.
/// Two sets: retraction (the story is withdrawn) outranks correction
/// (a detail was fixed). Matched case-insensitively against the
/// document title + text.
pub const retraction_markers: []const []const u8 = &.{ "retraction", "retracted", "we retract", "withdrawn" };
pub const correction_markers: []const []const u8 = &.{ "correction", "corrected", "erroneously reported", "we reported incorrectly", "apologise", "apologize", "clarification" };

/// Returns "retracted" or "corrected" when the text carries one of
/// the publisher's own markers, else null. Retraction outranks
/// correction.
pub fn scanRetraction(alloc: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const lower = try std.ascii.allocLowerString(alloc, text);
    defer alloc.free(lower);
    for (retraction_markers) |m| {
        if (std.mem.indexOf(u8, lower, m) != null) return "retracted";
    }
    for (correction_markers) |m| {
        if (std.mem.indexOf(u8, lower, m) != null) return "corrected";
    }
    return null;
}

/// Event status from its docs: "retracted" if any doc retracts,
/// "corrected" if any doc corrects, else "reported". The pipeline
/// persists this at ingest (markEventStatus); this is the same rule
/// recomputed from the docs for the detail endpoint.
pub fn eventStatus(alloc: std.mem.Allocator, docs: []const EventDoc) ![]const u8 {
    var corrected = false;
    for (docs) |d| {
        if (try scanRetraction(alloc, d.title)) |s| {
            if (std.mem.eql(u8, s, "retracted")) return "retracted";
            corrected = true;
        }
        if (try scanRetraction(alloc, d.text)) |s| {
            if (std.mem.eql(u8, s, "retracted")) return "retracted";
            corrected = true;
        }
    }
    return if (corrected) "corrected" else "reported";
}

pub const ConflictReport = struct {
    /// True when two reports in the same event have titles too
    /// dissimilar to be the same facts (a heuristic, not a verdict).
    divergent: bool,
    min_similarity: f64,
    a_title: ?[]const u8 = null,
    b_title: ?[]const u8 = null,
};

/// Pairwise trigram similarity of the docs' titles. An event is
/// divergent when its most-dissimilar pair scores below 0.30 —
/// same topic, different facts. Single-doc events never diverge.
pub fn detectConflicts(alloc: std.mem.Allocator, docs: []const EventDoc) !ConflictReport {
    var report = ConflictReport{ .divergent = false, .min_similarity = 1.0 };
    if (docs.len < 2) return report;
    var i: usize = 0;
    while (i < docs.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < docs.len) : (j += 1) {
            const sim = try fuzzy.similarity(alloc, docs[i].title, docs[j].title);
            if (sim < report.min_similarity) {
                report.min_similarity = sim;
                report.a_title = docs[i].title;
                report.b_title = docs[j].title;
            }
        }
    }
    report.divergent = report.min_similarity < 0.30;
    return report;
}

/// One flagged contradiction (Roadmap 7.5): two reports in the same
/// title-clustered event whose titles disagree (similarity < 0.30),
/// with both sources cited. A flag is a WARNING for a human to
/// check — never a verdict about which report is right.
pub const ContradictionFlag = struct {
    a_title: []const u8,
    b_title: []const u8,
    a_source: []const u8,
    b_source: []const u8,
    similarity: f64,
    note: []const u8 = "titles disagree: the reports may describe different facts — check both sources",
};

/// Every divergent pair in the event (not just the worst one), most
/// dissimilar first. Empty for single-doc events and for events
/// whose reports agree.
pub fn detectContradictionFlags(alloc: std.mem.Allocator, docs: []const EventDoc) ![]ContradictionFlag {
    var out: std.ArrayList(ContradictionFlag) = .empty;
    if (docs.len < 2) return out.toOwnedSlice(alloc);
    var i: usize = 0;
    while (i < docs.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < docs.len) : (j += 1) {
            const sim = try fuzzy.similarity(alloc, docs[i].title, docs[j].title);
            if (sim < 0.30) {
                try out.append(alloc, .{
                    .a_title = docs[i].title,
                    .b_title = docs[j].title,
                    .a_source = docs[i].source_name,
                    .b_source = docs[j].source_name,
                    .similarity = sim,
                });
            }
        }
    }
    std.mem.sort(ContradictionFlag, out.items, {}, struct {
        fn less(_: void, a: ContradictionFlag, b: ContradictionFlag) bool {
            return a.similarity < b.similarity;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

pub const TimelineDay = struct {
    day: []const u8, // "YYYY-MM-DD" (UTC)
    doc_count: usize,
};

/// "YYYY-MM-DD" (UTC) for a unix timestamp. Same civil-from-days
/// algorithm as maintenance.stampOf.
pub fn dayOf(alloc: std.mem.Allocator, ts: i64) ![]u8 {
    const days = @divFloor(ts, 86400);
    const z = days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    var buf: [11]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format.writeZeroPadded(&w, year, 4);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, m, 2);
    try w.writeByte('-');
    try format.writeZeroPadded(&w, d, 2);
    return alloc.dupe(u8, w.buffered());
}

/// Per-day document counts for the event, oldest day first.
pub fn timelineBuckets(alloc: std.mem.Allocator, docs: []const EventDoc) ![]TimelineDay {
    var days: std.ArrayList(TimelineDay) = .empty;
    // Docs arrive newest-first from the store; sort ascending by day
    // by inserting each day in order (few docs per event, linear is fine).
    for (docs) |d| {
        const day = try dayOf(alloc, d.published_at);
        var found: ?*TimelineDay = null;
        for (days.items) |*t| {
            if (std.mem.eql(u8, t.day, day)) {
                found = t;
                break;
            }
        }
        if (found) |t| {
            t.doc_count += 1;
            alloc.free(day);
        } else {
            // Insert in day order.
            var idx: usize = 0;
            while (idx < days.items.len and std.mem.lessThan(u8, days.items[idx].day, day)) : (idx += 1) {}
            try days.insert(alloc, idx, .{ .day = day, .doc_count = 1 });
        }
    }
    return days.toOwnedSlice(alloc);
}

test "importance: more docs, more sources, fresher = higher" {
    const fresh = importanceScore(10, 4, 3600);
    const stale = importanceScore(10, 4, 7 * 86400);
    const thin = importanceScore(1, 1, 3600);
    try std.testing.expect(fresh > stale);
    try std.testing.expect(fresh > thin);
    try std.testing.expect(fresh >= 0 and fresh <= 1);
    try std.testing.expect(importanceScore(0, 0, 30 * 86400) < 0.1);
    try std.testing.expect(importanceScore(100, 100, 0) <= 1.0);
}

test "corroboration counts distinct sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const docs = [_]EventDoc{
        .{ .id = "a", .title = "t", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "t", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" },
        .{ .id = "c", .title = "t", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "" },
    };
    try std.testing.expectEqual(@as(usize, 2), try corroboration(alloc, &docs));
    try std.testing.expectEqual(@as(usize, 0), try corroboration(alloc, &.{}));
}

test "scanRetraction finds the publisher's own markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("retracted", (try scanRetraction(alloc, "RETRACTION: we withdraw the story")).?);
    try std.testing.expectEqualStrings("corrected", (try scanRetraction(alloc, "Correction: the figure was wrong")).?);
    try std.testing.expectEqualStrings("corrected", (try scanRetraction(alloc, "We erroneously reported the time")).?);
    try std.testing.expect(try scanRetraction(alloc, "Fuel prices rose today.") == null);
    // Retraction outranks correction in the same text.
    try std.testing.expectEqualStrings("retracted", (try scanRetraction(alloc, "Correction issued. This story is retracted.")).?);
}

test "eventStatus escalates retracted over corrected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const plain = [_]EventDoc{.{ .id = "a", .title = "Fuel queue", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "queues form" }};
    try std.testing.expectEqualStrings("reported", try eventStatus(alloc, &plain));
    const fixed = [_]EventDoc{.{ .id = "a", .title = "Fuel queue", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "queues form" }, .{ .id = "b", .title = "Correction: fuel queue", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "the earlier figure was wrong" }};
    try std.testing.expectEqualStrings("corrected", try eventStatus(alloc, &fixed));
    const gone = [_]EventDoc{.{ .id = "a", .title = "Fuel queue", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "queues form" }, .{ .id = "b", .title = "Retraction", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "we retract the story" }};
    try std.testing.expectEqualStrings("retracted", try eventStatus(alloc, &gone));
}

test "detectConflicts flags divergent titles, not similar ones" {    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const same = [_]EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "Fuel shortage hits Monrovia today", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "" },
    };
    const r1 = try detectConflicts(alloc, &same);
    try std.testing.expect(!r1.divergent);
    const diff = [_]EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "President opens new hospital in Gbarnga", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "" },
    };
    const r2 = try detectConflicts(alloc, &diff);
    try std.testing.expect(r2.divergent);
    try std.testing.expect(r2.min_similarity < 0.30);
    const single = [_]EventDoc{.{ .id = "a", .title = "Fuel shortage", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" }};
    try std.testing.expect(!(try detectConflicts(alloc, &single)).divergent);
}

test "detectContradictionFlags lists every divergent pair with sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const docs = [_]EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "New Dawn", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "President opens new hospital in Gbarnga", .source_id = "s2", .source_name = "GNN Liberia", .published_at = 0, .text = "" },
        .{ .id = "c", .title = "Fuel shortage hits Monrovia today", .source_id = "s3", .source_name = "Daily Observer", .published_at = 0, .text = "" },
    };
    const flags = try detectContradictionFlags(alloc, &docs);
    // Only the two pairs against the hospital story diverge; the
    // two fuel stories agree with each other.
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expectEqualStrings("GNN Liberia", flags[0].b_source);
    try std.testing.expect(flags[0].similarity < 0.30);
    try std.testing.expect(std.mem.indexOf(u8, flags[0].note, "check both sources") != null);
    const agree = [_]EventDoc{
        .{ .id = "a", .title = "Fuel shortage hits Monrovia", .source_id = "s1", .source_name = "S1", .published_at = 0, .text = "" },
        .{ .id = "b", .title = "Fuel shortage hits Monrovia today", .source_id = "s2", .source_name = "S2", .published_at = 0, .text = "" },
    };
    try std.testing.expectEqual(@as(usize, 0), (try detectContradictionFlags(alloc, &agree)).len);
}

test "dayOf and timelineBuckets group by UTC day" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // 2026-11-12 01:00 UTC and 2026-11-13 01:00 UTC.
    try std.testing.expectEqualStrings("2026-11-12", try dayOf(alloc, 1794441600 + 3600));
    try std.testing.expectEqualStrings("2026-11-13", try dayOf(alloc, 1794441600 + 86400 + 3600));
    const docs = [_]EventDoc{
        .{ .id = "a", .title = "t", .source_id = "s1", .source_name = "S1", .published_at = 1794441600 + 3600, .text = "" },
        .{ .id = "b", .title = "t", .source_id = "s1", .source_name = "S1", .published_at = 1794441600 + 7200, .text = "" },
        .{ .id = "c", .title = "t", .source_id = "s2", .source_name = "S2", .published_at = 1794441600 + 86400 + 3600, .text = "" },
    };
    const days = try timelineBuckets(alloc, &docs);
    try std.testing.expectEqual(@as(usize, 2), days.len);
    try std.testing.expectEqualStrings("2026-11-12", days[0].day);
    try std.testing.expectEqual(@as(usize, 2), days[0].doc_count);
    try std.testing.expectEqualStrings("2026-11-13", days[1].day);
    try std.testing.expectEqual(@as(usize, 1), days[1].doc_count);
}

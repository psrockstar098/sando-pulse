//! Trust & Intelligence Engine, Phase 3: claim assessment.
//!
//! Given a claim and the documents that mention it, this module
//! produces an EVIDENCE ASSESSMENT, not a verdict:
//!
//!   verified            — 4+ independent sources agree, no credible
//!                         disagreement, nothing retracted or corrected.
//!   corroborated        — 2–3 independent sources agree, no credible
//!                         disagreement.
//!   partially_confirmed — the publisher corrected part of the story,
//!                         or only part of the claim is supported.
//!   unconfirmed         — one source only, or no supporting document
//!                         at all. "No answer is better than a wrong
//!                         answer": a single source is not enough to
//!                         call a claim corroborated.
//!   disputed            — credible sources disagree (contradiction
//!                         flags among the supporting documents), or
//!                         the publisher retracted the report. The
//!                         flags are cited so a reader can check.
//!   outdated            — a newer report on the same topic exists and
//!                         this one is more than 30 days old.
//!
//! There is deliberately NO "false" status here. Calling a claim
//! false is a verdict, and Pulse never issues verdicts (Roadmap 7.5
//! rule). Whether "false" is ever implemented is Dominic's call;
//! until then a claim that is contradicted reads "disputed" with the
//! evidence cited. See STATUS.md.
//!
//! Confidence is a 0..1 number with a fixed, documented formula, not
//! a judgement: 0.6 * min(distinct_sources, 5) / 5 + 0.3 * agreement
//! (1 - flagged_pairs / pairs, 1 when there is one document or no
//! pair) + 0.1 * recency (1 when the newest supporting document is
//! under 7 days old, 0 when over 30 days, linear between). The
//! result is capped at 0.95 — Pulse never claims certainty.

const std = @import("std");
const events = @import("../events.zig");
const fuzzy = @import("../../engine/fuzzy.zig");
const knowledge = @import("../../storage/knowledge.zig");

/// A document considered as evidence for a claim. Converted from
/// types.Document or knowledge.EventDoc by the caller so this module
/// stays independent of both stores.
pub const EvidenceInput = struct {
    source_id: []const u8,
    source_name: []const u8,
    title: []const u8,
    url: []const u8,
    published_at: i64,
    /// Registry reliability of the source (0.70 news, 0.88
    /// government). 0 when unknown — the assessment does not depend
    /// on it except through the verified bar (see assess).
    reliability: f32,
};

/// One supporting document, as rendered in the evidence record.
pub const EvidenceDoc = struct {
    source_id: []const u8,
    source_name: []const u8,
    title: []const u8,
    url: []const u8,
    published_at: i64,
    /// Title similarity to the claim (0..1, trigram).
    similarity: f64,
};

pub const ClaimStatus = enum {
    verified,
    corroborated,
    partially_confirmed,
    unconfirmed,
    disputed,
    outdated,

    pub fn name(self: ClaimStatus) []const u8 {
        return switch (self) {
            .verified => "verified",
            .corroborated => "corroborated",
            .partially_confirmed => "partially_confirmed",
            .unconfirmed => "unconfirmed",
            .disputed => "disputed",
            .outdated => "outdated",
        };
    }
};

/// The assessment of one claim, with everything a reader needs to
/// check it: the supporting documents, the contradiction flags, the
/// plain-words explanation, and the basis string naming which rule
/// produced the status.
pub const EvidenceRecord = struct {
    claim: []const u8,
    status: ClaimStatus,
    confidence: f64,
    explanation: []const u8,
    /// Which rule produced the status, e.g. "4+ independent sources
    /// agree, no contradiction flags".
    basis: []const u8,
    supporting: []EvidenceDoc,
    contradicting: []events.ContradictionFlag,
    distinct_sources: usize,
    event_id: ?[]const u8,
    assessed_at: i64,
};

/// Minimum title similarity for a document to count as supporting
/// the claim (same threshold as R7.5 event grouping).
pub const support_similarity: f64 = 0.5;

/// Distinct sources needed for "verified" (with no flags and nothing
/// retracted/corrected). Four independent outlets agreeing is the
/// bar the spec calls "sufficiently strong independent
/// confirmation"; with 9 enabled sources it is reachable but not
/// cheap.
pub const verified_sources: usize = 4;

/// Days after which a claim with a newer same-topic report is
/// "outdated".
pub const outdated_after_days: i64 = 30;

/// Assess one claim against the candidate documents.
///
/// - `event_status`: the event's status ("reported", "corrected" or
///   "retracted") when the claim comes from an event; "reported"
///   when it comes from a free-text query.
/// - `newer_event_exists`: a newer event on the same topic exists
///   (the caller checks the event list); false for query claims.
/// - `event_last_seen`: last time the event was seen (unix); for a
///   query claim pass the newest supporting document's time, or
///   `now` when there is none.
pub fn assess(
    alloc: std.mem.Allocator,
    claim: []const u8,
    docs: []const EvidenceInput,
    event_status: []const u8,
    newer_event_exists: bool,
    event_last_seen: i64,
    now: i64,
    event_id: ?[]const u8,
) !EvidenceRecord {
    var supporting: std.ArrayList(EvidenceDoc) = .empty;
    for (docs) |d| {
        const sim = fuzzy.similarity(alloc, d.title, claim) catch 0;
        if (sim >= support_similarity) {
            try supporting.append(alloc, .{
                .source_id = d.source_id,
                .source_name = d.source_name,
                .title = d.title,
                .url = d.url,
                .published_at = d.published_at,
                .similarity = sim,
            });
        }
    }
    const sup = supporting.items;

    var distinct: std.ArrayList([]const u8) = .empty;
    for (sup) |s| {
        var seen = false;
        for (distinct.items) |d| {
            if (std.mem.eql(u8, d, s.source_id)) {
                seen = true;
                break;
            }
        }
        if (!seen) try distinct.append(alloc, s.source_id);
    }

    // Contradiction flags among the supporting documents only — a
    // divergent pair in the wider event that does not touch this
    // claim's documents does not make this claim disputed.
    var flag_docs: std.ArrayList(knowledge.EventDoc) = .empty;
    for (sup) |s| {
        try flag_docs.append(alloc, .{
            .id = "",
            .title = s.title,
            .source_id = s.source_id,
            .source_name = s.source_name,
            .published_at = s.published_at,
            .text = "",
        });
    }
    const flags = try events.detectContradictionFlags(alloc, flag_docs.items);

    // Agreement: 1 when there is at most one supporting document or
    // no pair at all, else 1 - flagged pairs / total pairs.
    var agreement: f64 = 1;
    if (sup.len >= 2) {
        const pairs: f64 = @floatFromInt(sup.len * (sup.len - 1) / 2);
        agreement = 1 - @as(f64, @floatFromInt(flags.len)) / pairs;
        if (agreement < 0) agreement = 0;
    }

    // Recency: 1 when the newest supporting document is under 7 days
    // old, 0 when over 30, linear between.
    var recency: f64 = 0;
    if (sup.len > 0) {
        var newest: i64 = sup[0].published_at;
        for (sup) |s| {
            if (s.published_at > newest) newest = s.published_at;
        }
        const age_days = @divFloor(now - newest, 86400);
        if (age_days <= 7) {
            recency = 1;
        } else if (age_days >= 30) {
            recency = 0;
        } else {
            recency = @as(f64, @floatFromInt(30 - age_days)) / 23;
        }
    }

    const distinct_f: f64 = @floatFromInt(@min(distinct.items.len, 5));
    var confidence = 0.6 * distinct_f / 5 + 0.3 * agreement + 0.1 * recency;
    if (confidence > 0.95) confidence = 0.95;

    const is_retracted = std.mem.eql(u8, event_status, "retracted");
    const is_corrected = std.mem.eql(u8, event_status, "corrected");
    const age_days = @divFloor(now - event_last_seen, 86400);
    const is_outdated = newer_event_exists and age_days > outdated_after_days;

    var status: ClaimStatus = .unconfirmed;
    var basis: []const u8 = "no supporting document found";
    var explanation: []const u8 = "No document in the store supports this claim, so it cannot be confirmed.";
    if (sup.len == 0) {
        // stays unconfirmed
    } else if (is_retracted) {
        status = .disputed;
        basis = "publisher retracted the report";
        explanation = "The publisher retracted this report, so the claim is contested — read the retraction before trusting it.";
    } else if (flags.len > 0) {
        status = .disputed;
        basis = "contradiction flags among the supporting documents";
        explanation = "Reports that should agree on this claim disagree with each other, so it is disputed — the flags below show which ones.";
    } else if (is_outdated) {
        status = .outdated;
        basis = "a newer report on the same topic exists and this one is over 30 days old";
        explanation = "A newer report on the same topic exists, so this claim may no longer be current.";
    } else if (is_corrected) {
        status = .partially_confirmed;
        basis = "publisher corrected part of the story";
        explanation = "The publisher corrected part of this story, so the claim is only partially confirmed as originally stated.";
    } else if (distinct.items.len >= verified_sources) {
        status = .verified;
        basis = "4+ independent sources agree, no contradiction flags";
        explanation = "Four or more independent sources agree on this claim and none contradicts it.";
    } else if (distinct.items.len >= 2) {
        status = .corroborated;
        basis = "2-3 independent sources agree, no contradiction flags";
        explanation = "Two or more independent sources agree on this claim and none contradicts it.";
    } else {
        status = .unconfirmed;
        basis = "single source only";
        explanation = "Only one source reports this claim, which is not enough to confirm it.";
    }

    return .{
        .claim = claim,
        .status = status,
        .confidence = confidence,
        .explanation = explanation,
        .basis = basis,
        .supporting = sup,
        .contradicting = flags,
        .distinct_sources = distinct.items.len,
        .event_id = event_id,
        .assessed_at = now,
    };
}

fn input(id: []const u8, source: []const u8, title: []const u8) EvidenceInput {
    return .{ .source_id = id, .source_name = source, .title = title, .url = "", .published_at = 1795000000, .reliability = 0.70 };
}

test "assess: no supporting document is unconfirmed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rec = try assess(alloc, "Fuel shortage hits Monrovia", &.{}, "reported", false, 1795000000, 1795000000, null);
    try std.testing.expectEqual(ClaimStatus.unconfirmed, rec.status);
    try std.testing.expectEqual(@as(usize, 0), rec.distinct_sources);
    try std.testing.expect(rec.confidence < 0.35);
}

test "assess: one source is unconfirmed, two corroborated, four verified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const claim = "Fuel shortage hits Monrovia";
    const one = [_]EvidenceInput{input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia")};
    try std.testing.expectEqual(ClaimStatus.unconfirmed, (try assess(alloc, claim, &one, "reported", false, 1795000000, 1795000000, null)).status);

    const two = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("daily-observer", "Daily Observer", "Fuel shortage hits Monrovia today"),
    };
    const r2 = try assess(alloc, claim, &two, "reported", false, 1795000000, 1795000000, null);
    try std.testing.expectEqual(ClaimStatus.corroborated, r2.status);
    try std.testing.expectEqual(@as(usize, 2), r2.distinct_sources);

    const four = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("daily-observer", "Daily Observer", "Fuel shortage hits Monrovia today"),
        input("frontpage-africa", "FrontPage Africa", "Fuel shortage hits Monrovia"),
        input("the-news", "The News", "Fuel shortage hits Monrovia"),
    };
    const r4 = try assess(alloc, claim, &four, "reported", false, 1795000000, 1795000000, null);
    try std.testing.expectEqual(ClaimStatus.verified, r4.status);
    try std.testing.expect(r4.confidence > r2.confidence);
    try std.testing.expect(r4.confidence <= 0.95);

    // Same source twice is still one distinct source.
    const dup = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia again"),
    };
    try std.testing.expectEqual(ClaimStatus.unconfirmed, (try assess(alloc, claim, &dup, "reported", false, 1795000000, 1795000000, null)).status);
}

test "assess: retracted and corrected map to disputed / partially_confirmed, flags dispute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const claim = "Fuel shortage hits Monrovia";
    const two = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("daily-observer", "Daily Observer", "Fuel shortage hits Monrovia today"),
    };
    try std.testing.expectEqual(ClaimStatus.disputed, (try assess(alloc, claim, &two, "retracted", false, 1795000000, 1795000000, null)).status);
    try std.testing.expectEqual(ClaimStatus.partially_confirmed, (try assess(alloc, claim, &two, "corrected", false, 1795000000, 1795000000, null)).status);
    // Two documents that each support the claim (both share half of
    // it) but disagree with each other (they share no words) flag a
    // dispute even though both support the claim text.
    const clash_claim = "Fuel shortage hits Monrovia, LPRC announces new prices today";
    const clash = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("daily-observer", "Daily Observer", "LPRC announces new prices today"),
    };
    const rc = try assess(alloc, clash_claim, &clash, "reported", false, 1795000000, 1795000000, null);
    try std.testing.expectEqual(ClaimStatus.disputed, rc.status);
    try std.testing.expect(rc.contradicting.len > 0);
}

test "assess: outdated needs a newer event and age over 30 days" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const claim = "Fuel shortage hits Monrovia";
    const two = [_]EvidenceInput{
        input("new-dawn", "New Dawn", "Fuel shortage hits Monrovia"),
        input("daily-observer", "Daily Observer", "Fuel shortage hits Monrovia today"),
    };
    const old = 1795000000 - 40 * 86400;
    try std.testing.expectEqual(ClaimStatus.outdated, (try assess(alloc, claim, &two, "reported", true, old, 1795000000, null)).status);
    // Same age but no newer event: not outdated.
    try std.testing.expectEqual(ClaimStatus.corroborated, (try assess(alloc, claim, &two, "reported", false, old, 1795000000, null)).status);
    // Newer event but recent: not outdated.
    try std.testing.expectEqual(ClaimStatus.corroborated, (try assess(alloc, claim, &two, "reported", true, 1795000000, 1795000000, null)).status);
}

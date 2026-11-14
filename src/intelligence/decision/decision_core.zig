//! Trust & Intelligence Engine, Phase 7: PULSE Decision Core.
//!
//! A rule-based claim assessment. It reuses the Phase 3
//! corroboration assessment for the status + confidence, then adds
//! the decision's own rules and — the point of this module — the
//! FULL REASONING: every rule that fired, what it saw, and what it
//! concluded, so a reader (or an auditor) can check the decision
//! step by step. The reasoning is the audit trail; it is returned
//! in the response and the call is also recorded in the audit log
//! (route /v1/decisions) by the handler.
//!
//! The status is an ASSESSMENT, never a verdict — the same six
//! statuses as Phase 3 (verified, corroborated,
//! partially_confirmed, unconfirmed, disputed, outdated), and
//! deliberately no "false". What "decision like jev" means beyond
//! this rule-based assessment is UNVERIFIED (Dominic's original
//! prompt is not visible on the shared design page) — see STATUS.md.
//!
//! Official sources: a supporting document counts as official when
//! its source's registry reliability is >= 0.88 (the design-doc
//! grade for government sources). No registry source carries that
//! grade today, so official_source_present is honestly false until
//! a government source is registered.

const std = @import("std");
const sources = @import("../../ingestion/sources.zig");
const events = @import("../events.zig");
const trust_corroboration = @import("../trust/corroboration.zig");

/// One rule that fired, with what it saw and what it concluded.
pub const ReasoningStep = struct {
    rule: []const u8,
    outcome: []const u8,
    detail: []const u8,
};

pub const Decision = struct {
    claim: []const u8,
    status: trust_corroboration.ClaimStatus,
    confidence: f64,
    distinct_sources: usize,
    supporting_docs: usize,
    flags: []const events.ContradictionFlag,
    /// True when at least one supporting document comes from a
    /// source with registry reliability >= 0.88 (government grade).
    official_source_present: bool,
    /// Names of the official sources, if any.
    official_sources: []const []const u8,
    reasoning: []const ReasoningStep,
    explanation: []const u8,
};

const official_reliability: f32 = 0.88;

/// Assess a claim. `inputs` are the supporting documents (the same
/// shape Phase 3 uses); `status_hint` is the event status when the
/// claim comes from an event ("reported" otherwise); `newer_exists`
/// and `newest` are the Phase 3 inputs for the outdated rule.
pub fn assessDecision(
    alloc: std.mem.Allocator,
    claim: []const u8,
    inputs: []const trust_corroboration.EvidenceInput,
    status_hint: []const u8,
    newer_exists: bool,
    newest: i64,
    now: i64,
    event_id: ?[]const u8,
) !Decision {
    const rec = try trust_corroboration.assess(alloc, claim, inputs, status_hint, newer_exists, newest, now, event_id);
    var reasoning: std.ArrayList(ReasoningStep) = .empty;
    var official: std.ArrayList([]const u8) = .empty;
    var official_present = false;
    for (inputs) |inp| {
        for (sources.sources) |s| {
            if (std.mem.eql(u8, s.id, inp.source_id) and s.reliability >= official_reliability) {
                official_present = true;
                var seen = false;
                for (official.items) |x| {
                    if (std.mem.eql(u8, x, s.name)) seen = true;
                }
                if (!seen) try official.append(alloc, s.name);
            }
        }
    }
    const age_days: i64 = @divFloor(@max(0, now - newest), 86400);

    try reasoning.append(alloc, .{
        .rule = "distinct_sources",
        .outcome = if (rec.distinct_sources >= 4) "met" else if (rec.distinct_sources >= 2) "partial" else "not met",
        .detail = try std.fmt.allocPrint(alloc, "{d} distinct source(s) support the claim (4+ needed for verified, 2+ for corroborated).", .{rec.distinct_sources}),
    });
    try reasoning.append(alloc, .{
        .rule = "volume",
        .outcome = if (rec.supporting.len >= 4) "strong" else if (rec.supporting.len >= 2) "some" else "thin",
        .detail = try std.fmt.allocPrint(alloc, "{d} supporting document(s) — search returned {d}, of which {d} are similar enough to the claim (title similarity >= 0.5) to count as supporting it.", .{ rec.supporting.len, inputs.len, rec.supporting.len }),
    });
    try reasoning.append(alloc, .{
        .rule = "contradiction_flags",
        .outcome = if (rec.contradicting.len == 0) "none" else "present",
        .detail = if (rec.contradicting.len == 0)
            "No contradiction flags among the supporting documents."
        else
            try std.fmt.allocPrint(alloc, "{d} contradiction flag(s) — the supporting documents disagree with each other or the publisher retracted the report.", .{rec.contradicting.len}),
    });
    try reasoning.append(alloc, .{
        .rule = "official_source",
        .outcome = if (official_present) "present" else "absent",
        .detail = if (official_present)
            "At least one supporting document comes from a government-grade source (registry reliability >= 0.88)."
        else
            "No supporting document comes from a government-grade source (registry reliability >= 0.88) — none is registered yet.",
    });
    try reasoning.append(alloc, .{
        .rule = "recency",
        .outcome = if (age_days <= 7) "fresh" else if (age_days <= 30) "aging" else "old",
        .detail = try std.fmt.allocPrint(alloc, "Newest supporting document is {d} day(s) old.", .{age_days}),
    });
    try reasoning.append(alloc, .{
        .rule = "status_rule",
        .outcome = rec.status.name(),
        .detail = try std.fmt.allocPrint(alloc, "Applied the Phase 3 assessment rules to the evidence above: {s}.", .{rec.explanation}),
    });

    return .{
        .claim = claim,
        .status = rec.status,
        .confidence = rec.confidence,
        .distinct_sources = rec.distinct_sources,
        .supporting_docs = rec.supporting.len,
        .flags = rec.contradicting,
        .official_source_present = official_present,
        .official_sources = official.items,
        .reasoning = reasoning.items,
        .explanation = rec.explanation,
    };
}

test "decision carries full reasoning and no official source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794681600;
    const inputs = [_]trust_corroboration.EvidenceInput{
        .{ .source_id = "frontpage-africa", .source_name = "FrontPage Africa", .title = "Fuel shortage hits Monrovia", .url = "https://example.com/1", .published_at = now, .reliability = 0.70 },
        .{ .source_id = "new-dawn", .source_name = "New Dawn", .title = "Fuel shortage hits Monrovia", .url = "https://example.com/2", .published_at = now, .reliability = 0.70 },
        .{ .source_id = "gnn-liberia", .source_name = "GNN Liberia", .title = "Fuel shortage hits Monrovia", .url = "https://example.com/3", .published_at = now, .reliability = 0.70 },
        .{ .source_id = "the-analyst", .source_name = "The Analyst", .title = "Fuel shortage hits Monrovia", .url = "https://example.com/4", .published_at = now, .reliability = 0.70 },
    };
    const d = try assessDecision(alloc, "Fuel shortage hits Monrovia", &inputs, "reported", false, now, now, null);
    try std.testing.expectEqual(trust_corroboration.ClaimStatus.verified, d.status);
    try std.testing.expectEqual(@as(usize, 4), d.distinct_sources);
    try std.testing.expect(!d.official_source_present);
    try std.testing.expectEqual(@as(usize, 6), d.reasoning.len);
    try std.testing.expectEqualStrings("distinct_sources", d.reasoning[0].rule);
    try std.testing.expectEqualStrings("met", d.reasoning[0].outcome);
    try std.testing.expectEqualStrings("official_source", d.reasoning[3].rule);
    try std.testing.expectEqualStrings("absent", d.reasoning[3].outcome);
}

test "decision on one source is unconfirmed with thin volume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1794681600;
    const inputs = [_]trust_corroboration.EvidenceInput{
        .{ .source_id = "new-dawn", .source_name = "New Dawn", .title = "Zebra migration patterns", .url = "https://example.com/1", .published_at = now, .reliability = 0.70 },
    };
    const d = try assessDecision(alloc, "Zebra migration patterns", &inputs, "reported", false, now, now, null);
    try std.testing.expectEqual(trust_corroboration.ClaimStatus.unconfirmed, d.status);
    try std.testing.expectEqualStrings("thin", d.reasoning[1].outcome);
    try std.testing.expectEqualStrings("not met", d.reasoning[0].outcome);
}

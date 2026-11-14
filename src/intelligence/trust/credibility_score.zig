//! Trust & Intelligence Engine, Phase 4: credibility scoring +
//! county rankings.
//!
//! Spec weights (from the design doc, section 3):
//!
//!   accuracy 30% — share of the source's event documents that sit
//!   in events with NO contradiction flag. A flag means reports in
//!   the same event disagree; a source whose stories keep landing in
//!   flagged events scores lower. No event data in the window scores
//!   neutral (0.5), not zero — absence of evidence is not evidence
//!   of inaccuracy.
//!   corroboration 20% — share of the source's documents that appear
//!   in multi-source events (another outlet independently reported
//!   the same story). No event data scores neutral.
//!   evidence/transparency 15% — share of documents with substantive
//!   text (>= 200 chars) and a URL. The honest proxy for "shows its
//!   work": a stub headline with no body text scores lower.
//!   original reporting 10% — share of documents whose title is NOT
//!   a near-duplicate (similarity >= 0.9) of a document from another
//!   source published within 2 days. A title copied from another
//!   outlet's story is likely syndicated or republished, not
//!   original reporting.
//!   timeliness 10% — average ingest lag (fetched_at - published_at):
//!   <= 1h is 1.0, >= 24h is 0.0, linear between. Documents without
//!   a publication time are excluded; if none has one, neutral.
//!   corrections/accountability 10% — 1.0 when at least one
//!   retraction/correction marker appears in the source's documents
//!   (the outlet corrects its mistakes in public), else 0.5 neutral
//!   — "no corrections found" is not scored as a failure, because a
//!   clean record and a never-corrected record look the same.
//!   local knowledge 5% — share of documents mentioning a Liberian
//!   county other than Montserrado, or a Liberian city. Reporting
//!   beyond the capital scores higher.
//!
//! Ratings 1–5 come from the weighted total: >= 0.85 → 5, >= 0.70 →
//! 4, >= 0.55 → 3, >= 0.40 → 2, else 1. A source with fewer than
//! `min_docs_for_rating` documents in the window is PROVISIONAL: its
//! rating is null and the reason is stated, because 2 documents
//! cannot support a credibility judgement. The total is still shown
//! so the reader can see what the (thin) evidence says.
//!
//! Everything here is computed from the store, on demand, over the
//! last `window_days` days. No score is persisted as a fact — the
//! Registry's history log records score CHANGES (see
//! source_registry.noteScore), so a source can see why its score
//! moved. Rankings (Phase 4, second half) rank REGISTERED sources
//! only, per county, top 20 of up to 50 candidates; a county with no
//! registered sources ranks nothing, honestly.

const std = @import("std");
const types = @import("../../common/types.zig");
const knowledge = @import("../../storage/knowledge.zig");
const sources = @import("../../ingestion/sources.zig");
const events = @import("../events.zig");
const entities = @import("../../engine/entities.zig");
const fuzzy = @import("../../engine/fuzzy.zig");

/// Scoring window in days.
pub const window_days: i64 = 30;
/// Documents in the window needed for a non-provisional rating.
pub const min_docs_for_rating: usize = 5;
/// Caps that keep the on-demand computation bounded. The window scan
/// is newest-first, so the caps keep the freshest documents.
pub const max_docs_scored: usize = 200;
pub const max_events_scored: usize = 50;
/// Substantive text length for the evidence component.
pub const substantive_text_len: usize = 200;
/// Title similarity at which a story counts as republished.
pub const duplicate_similarity: f64 = 0.9;
/// Window (seconds) in which a near-duplicate counts as a copy.
pub const duplicate_window_s: i64 = 2 * 86400;

pub const Component = struct {
    name: []const u8,
    weight: f64,
    value: f64,
    basis: []const u8,
};

pub const Score = struct {
    source_id: []const u8,
    source_name: []const u8,
    total: f64,
    rating: ?u8,
    provisional: bool,
    provisional_reason: ?[]const u8,
    components: [7]Component,
    docs_in_window: usize,
    window_days: i64,
};

/// One event as the scorer sees it: its documents (for membership
/// and flags) and its distinct-source count.
pub const ScoredEvent = struct {
    id: []const u8,
    status: []const u8,
    distinct_sources: usize,
    docs: []const knowledge.EventDoc,
    has_flag: bool,
};

/// Rating from a weighted total.
pub fn ratingFor(total: f64) u8 {
    if (total >= 0.85) return 5;
    if (total >= 0.70) return 4;
    if (total >= 0.55) return 3;
    if (total >= 0.40) return 2;
    return 1;
}

/// One ranked entry: the score plus its position.
pub const RankedEntry = struct {
    rank: usize,
    score: Score,
};

/// Rank the scores of the given source ids (a county's sources, from
/// the Registry) by total, highest first, ties broken by source id
/// for stability. Provisional sources rank by total like any other
/// — their `provisional` flag says the rating is not final. At most
/// `limit` entries (spec: top 20 of up to 50 candidates).
pub fn rankScores(
    alloc: std.mem.Allocator,
    scores: []const Score,
    ids: []const []const u8,
    limit: usize,
) ![]RankedEntry {
    var kept: std.ArrayList(Score) = .empty;
    for (scores) |s| {
        for (ids) |id| {
            if (std.mem.eql(u8, s.source_id, id)) {
                try kept.append(alloc, s);
                break;
            }
        }
    }
    std.mem.sort(Score, kept.items, {}, struct {
        fn less(_: void, a: Score, b: Score) bool {
            if (a.total != b.total) return a.total > b.total;
            return std.mem.lessThan(u8, a.source_id, b.source_id);
        }
    }.less);
    const n = @min(kept.items.len, limit);
    var out: std.ArrayList(RankedEntry) = .empty;
    for (kept.items[0..n], 0..) |s, i| {
        try out.append(alloc, .{ .rank = i + 1, .score = s });
    }
    return out.toOwnedSlice(alloc);
}

/// Score every registered source from the window's documents and
/// events. `docs` are the window's documents (newest first, already
/// filtered to the window by the caller); `evts` are the window's
/// events with their documents. Sources with no documents in the
/// window still get a score (provisional, total from neutral
/// components) so the response lists all 12 sources honestly.
pub fn scoreAll(
    alloc: std.mem.Allocator,
    docs: []const types.Document,
    evts: []const ScoredEvent,
    now: i64,
) ![]Score {
    var out: std.ArrayList(Score) = .empty;
    for (sources.sources) |s| {
        var mine: std.ArrayList(types.Document) = .empty;
        for (docs) |d| {
            if (std.mem.eql(u8, d.source_id, s.id)) try mine.append(alloc, d);
        }
        try out.append(alloc, try scoreOne(alloc, s, mine.items, docs, evts, now));
    }
    return out.toOwnedSlice(alloc);
}

fn scoreOne(
    alloc: std.mem.Allocator,
    src: sources.Source,
    docs: []const types.Document,
    /// All window documents (every source) — the originality check
    /// compares against OTHER sources' stories, so it needs the full
    /// window, not just this source's documents.
    all_docs: []const types.Document,
    evts: []const ScoredEvent,
    now: i64,
) !Score {
    _ = now;
    const n = docs.len;

    // --- accuracy: docs in events, share in unflagged events.
    var in_events: usize = 0;
    var in_unflagged: usize = 0;
    for (docs) |d| {
        for (evts) |e| {
            for (e.docs) |ed| {
                if (std.mem.eql(u8, ed.id, d.id)) {
                    in_events += 1;
                    if (!e.has_flag) in_unflagged += 1;
                    break;
                }
            }
        }
    }
    const accuracy: f64 = if (in_events == 0) 0.5 else @as(f64, @floatFromInt(in_unflagged)) / @as(f64, @floatFromInt(in_events));
    const accuracy_basis = if (in_events == 0)
        "no event data in the window — scored neutrally"
    else
        "share of the source's event documents in events with no contradiction flag";

    // --- corroboration: docs in multi-source events.
    var in_multi: usize = 0;
    for (docs) |d| {
        for (evts) |e| {
            if (e.distinct_sources < 2) continue;
            for (e.docs) |ed| {
                if (std.mem.eql(u8, ed.id, d.id)) {
                    in_multi += 1;
                    break;
                }
            }
        }
    }
    const corroboration: f64 = if (in_events == 0) 0.5 else @as(f64, @floatFromInt(in_multi)) / @as(f64, @floatFromInt(in_events));
    const corroboration_basis = if (in_events == 0)
        "no event data in the window — scored neutrally"
    else
        "share of the source's event documents in multi-source events";

    // --- evidence: substantive text + URL.
    var substantive: usize = 0;
    for (docs) |d| {
        if (d.text.len >= substantive_text_len and d.url.len > 0) substantive += 1;
    }
    const evidence: f64 = if (n == 0) 0.5 else @as(f64, @floatFromInt(substantive)) / @as(f64, @floatFromInt(n));
    const evidence_basis = if (n == 0)
        "no documents in the window — scored neutrally"
    else
        "share of documents with substantive text (>= 200 chars) and a URL";

    // --- original reporting: not a near-duplicate of another source.
    var original: usize = 0;
    for (docs) |d| {
        const d_ts = knowledge.docTs(d);
        var dup = false;
        for (all_docs) |o| {
            if (std.mem.eql(u8, o.source_id, d.source_id)) continue;
            if (std.mem.eql(u8, o.id, d.id)) continue;
            const dt = @abs(knowledge.docTs(o) - d_ts);
            if (dt > duplicate_window_s) continue;
            if ((fuzzy.similarity(alloc, d.title, o.title) catch 0) >= duplicate_similarity) {
                dup = true;
                break;
            }
        }
        if (!dup) original += 1;
    }
    const originality: f64 = if (n == 0) 0.5 else @as(f64, @floatFromInt(original)) / @as(f64, @floatFromInt(n));
    const originality_basis = if (n == 0)
        "no documents in the window — scored neutrally"
    else
        "share of documents that are not near-duplicates of another source's story within 2 days";

    // --- timeliness: average ingest lag.
    var lag_sum: f64 = 0;
    var lag_n: usize = 0;
    for (docs) |d| {
        if (d.published_at) |pub_at| {
            if (pub_at > 0 and d.fetched_at >= pub_at) {
                lag_sum += @floatFromInt(d.fetched_at - pub_at);
                lag_n += 1;
            }
        }
    }
    var timeliness: f64 = 0.5;
    if (lag_n > 0) {
        const avg_lag = lag_sum / @as(f64, @floatFromInt(lag_n));
        if (avg_lag <= 3600) {
            timeliness = 1;
        } else if (avg_lag >= 86400) {
            timeliness = 0;
        } else {
            timeliness = 1 - (avg_lag - 3600) / (86400 - 3600);
        }
    }
    const timeliness_basis = if (lag_n == 0)
        "no publication times in the window — scored neutrally"
    else
        "average ingest lag (<= 1h is 1.0, >= 24h is 0.0)";

    // --- corrections/accountability: at least one public correction.
    var has_correction = false;
    for (docs) |d| {
        if (try events.scanRetraction(alloc, d.title)) |_| {
            has_correction = true;
            break;
        }
        if (try events.scanRetraction(alloc, d.text)) |_| {
            has_correction = true;
            break;
        }
    }
    const corrections: f64 = if (has_correction) 1 else 0.5;
    const corrections_basis = if (has_correction)
        "the source published a correction or retraction in the window"
    else
        "no corrections found in the window — scored neutrally, not as a failure";

    // --- local knowledge: mentions a county beyond Montserrado, or
    // a Liberian city.
    var local: usize = 0;
    for (docs) |d| {
        const ent = try entities.extract(alloc, d.title);
        defer entities.freeEntities(alloc, ent);
        const ent2 = try entities.extract(alloc, d.text);
        defer entities.freeEntities(alloc, ent2);
        var hit = false;
        for (ent.counties) |c| {
            if (!std.mem.eql(u8, c, "Montserrado")) hit = true;
        }
        for (ent2.counties) |c| {
            if (!std.mem.eql(u8, c, "Montserrado")) hit = true;
        }
        if (ent.cities.len > 0 or ent2.cities.len > 0) hit = true;
        if (hit) local += 1;
    }
    const local_knowledge: f64 = if (n == 0) 0.5 else @as(f64, @floatFromInt(local)) / @as(f64, @floatFromInt(n));
    const local_basis = if (n == 0)
        "no documents in the window — scored neutrally"
    else
        "share of documents mentioning a county beyond Montserrado or a Liberian city";

    const components = [7]Component{
        .{ .name = "accuracy", .weight = 0.30, .value = accuracy, .basis = accuracy_basis },
        .{ .name = "corroboration", .weight = 0.20, .value = corroboration, .basis = corroboration_basis },
        .{ .name = "evidence", .weight = 0.15, .value = evidence, .basis = evidence_basis },
        .{ .name = "original_reporting", .weight = 0.10, .value = originality, .basis = originality_basis },
        .{ .name = "timeliness", .weight = 0.10, .value = timeliness, .basis = timeliness_basis },
        .{ .name = "corrections", .weight = 0.10, .value = corrections, .basis = corrections_basis },
        .{ .name = "local_knowledge", .weight = 0.05, .value = local_knowledge, .basis = local_basis },
    };
    var total: f64 = 0;
    for (components) |c| total += c.weight * c.value;

    const provisional = n < min_docs_for_rating;
    var reason: ?[]const u8 = null;
    if (provisional) {
        reason = try std.fmt.allocPrint(alloc, "only {d} document(s) in the last {d} days (need {d} for a rating)", .{ n, window_days, min_docs_for_rating });
    }
    return .{
        .source_id = src.id,
        .source_name = src.name,
        .total = total,
        .rating = if (provisional) null else ratingFor(total),
        .provisional = provisional,
        .provisional_reason = reason,
        .components = components,
        .docs_in_window = n,
        .window_days = window_days,
    };
}

fn doc(id: []const u8, source: []const u8, title: []const u8, text: []const u8, published: i64, fetched: i64) types.Document {
    return .{
        .id = id,
        .source_id = source,
        .source_name = source,
        .source_url = "",
        .title = title,
        .url = "https://example.com/x",
        .text = text,
        .published_at = published,
        .fetched_at = fetched,
        .reliability = 0.70,
        .topics = &.{},
        .content_hash = id,
    };
}

fn evdoc(id: []const u8, source: []const u8, title: []const u8) knowledge.EventDoc {
    return .{ .id = id, .title = title, .source_id = source, .source_name = source, .published_at = 1795000000, .text = "" };
}

test "ratingFor thresholds" {
    try std.testing.expectEqual(@as(u8, 5), ratingFor(0.9));
    try std.testing.expectEqual(@as(u8, 5), ratingFor(0.85));
    try std.testing.expectEqual(@as(u8, 4), ratingFor(0.84));
    try std.testing.expectEqual(@as(u8, 4), ratingFor(0.70));
    try std.testing.expectEqual(@as(u8, 3), ratingFor(0.55));
    try std.testing.expectEqual(@as(u8, 2), ratingFor(0.40));
    try std.testing.expectEqual(@as(u8, 1), ratingFor(0.39));
    try std.testing.expectEqual(@as(u8, 1), ratingFor(0));
}

test "scoreAll: fewer than 5 docs is provisional with a null rating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const docs = [_]types.Document{
        doc("d1", "new-dawn", "Fuel shortage hits Monrovia", "Fuel stations report long queues in Monrovia today.", 1795000000, 1795003600),
        doc("d2", "new-dawn", "Lone Star wins friendly", "The national team won its friendly match in Monrovia.", 1795000000, 1795003600),
    };
    const scores = try scoreAll(alloc, &docs, &.{}, 1795000000);
    try std.testing.expectEqual(@as(usize, 12), scores.len);
    var nd: ?Score = null;
    for (scores) |s| {
        if (std.mem.eql(u8, s.source_id, "new-dawn")) nd = s;
    }
    const s = nd.?;
    try std.testing.expect(s.provisional);
    try std.testing.expectEqual(@as(?u8, null), s.rating);
    try std.testing.expect(s.provisional_reason != null);
    try std.testing.expectEqual(@as(usize, 2), s.docs_in_window);
    // A source with no documents at all is provisional too.
    for (scores) |o| {
        if (std.mem.eql(u8, o.source_id, "gnn-liberia")) {
            try std.testing.expect(o.provisional);
            try std.testing.expectEqual(@as(usize, 0), o.docs_in_window);
        }
    }
}

test "scoreAll: corroborated multi-source stories score higher than solo ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const long_text = "Fuel stations in Monrovia report long queues as the shortage continues into its second week, with drivers waiting for hours at pumps across the capital city and beyond. The queues stretched for blocks, and several stations closed early after running dry.";
    var docs: std.ArrayList(types.Document) = .empty;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try docs.append(alloc, doc(try std.fmt.allocPrint(alloc, "nd{d}", .{i}), "new-dawn", "Fuel shortage hits Monrovia", long_text, now, now + 600));
    }
    // One multi-source event holding all five new-dawn docs plus a
    // daily-observer doc, no flags.
    const ev_docs = [_]knowledge.EventDoc{
        evdoc("nd0", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd1", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd2", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd3", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd4", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("ob1", "daily-observer", "Fuel shortage hits Monrovia"),
    };
    const evts = [_]ScoredEvent{.{
        .id = "ev1",
        .status = "reported",
        .distinct_sources = 2,
        .docs = &ev_docs,
        .has_flag = false,
    }};
    const scores = try scoreAll(alloc, docs.items, &evts, now);
    var nd: ?Score = null;
    for (scores) |s| {
        if (std.mem.eql(u8, s.source_id, "new-dawn")) nd = s;
    }
    const s = nd.?;
    try std.testing.expect(!s.provisional);
    try std.testing.expectEqual(@as(?u8, 5), s.rating);
    // accuracy 1.0 (no flags), corroboration 1.0 (multi-source),
    // evidence 1.0 (long text + URL), timeliness 1.0 (10 min lag),
    // corrections 0.5 (none found), local 0.0 (no county/city beyond
    // the capital in the text — "Monrovia" is the capital, and the
    // county Montserrado is not named).
    try std.testing.expectApproxEqAbs(1.0, s.components[0].value, 0.001);
    try std.testing.expectApproxEqAbs(1.0, s.components[1].value, 0.001);
    try std.testing.expectApproxEqAbs(1.0, s.components[2].value, 0.001);
    try std.testing.expectApproxEqAbs(1.0, s.components[4].value, 0.001);
    try std.testing.expectApproxEqAbs(0.5, s.components[5].value, 0.001);
}

test "scoreAll: a flagged event drops accuracy, a correction lifts corrections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const long_text = "Fuel stations in Monrovia report long queues as the shortage continues into its second week, with drivers waiting for hours at pumps across the capital city and beyond. The queues stretched for blocks, and several stations closed early after running dry.";
    var docs: std.ArrayList(types.Document) = .empty;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try docs.append(alloc, doc(try std.fmt.allocPrint(alloc, "nd{d}", .{i}), "new-dawn", "Fuel shortage hits Monrovia", long_text, now, now + 600));
    }
    // Correction marker in one document's text.
    docs.items[0].text = "Correction: an earlier version of this story misstated the price. Fuel stations in Monrovia report long queues as the shortage continues into its second week, with drivers waiting for hours.";
    const ev_docs = [_]knowledge.EventDoc{
        evdoc("nd0", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd1", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd2", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd3", "new-dawn", "Fuel shortage hits Monrovia"),
        evdoc("nd4", "new-dawn", "Fuel shortage hits Monrovia"),
    };
    const evts = [_]ScoredEvent{.{
        .id = "ev1",
        .status = "reported",
        .distinct_sources = 1,
        .docs = &ev_docs,
        .has_flag = true,
    }};
    const scores = try scoreAll(alloc, docs.items, &evts, now);
    var nd: ?Score = null;
    for (scores) |s| {
        if (std.mem.eql(u8, s.source_id, "new-dawn")) nd = s;
    }
    const s = nd.?;
    // All five docs sit in a flagged event: accuracy 0.
    try std.testing.expectApproxEqAbs(0.0, s.components[0].value, 0.001);
    // Single-source event: corroboration 0.
    try std.testing.expectApproxEqAbs(0.0, s.components[1].value, 0.001);
    // The correction marker is found: corrections 1.0.
    try std.testing.expectApproxEqAbs(1.0, s.components[5].value, 0.001);
}

test "scoreAll: a copied title is not original reporting, a county mention is local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const now: i64 = 1795000000;
    const long_text = "The match was played in Gbarnga, Bong County, where fans filled the stadium for the county meet final.";
    var docs: std.ArrayList(types.Document) = .empty;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try docs.append(alloc, doc(try std.fmt.allocPrint(alloc, "nd{d}", .{i}), "new-dawn", "Lone Star wins in Gbarnga", long_text, now, now + 600));
    }
    // A daily-observer doc with the identical title, same day: the
    // new-dawn titles are copies.
    try docs.append(alloc, doc("ob1", "daily-observer", "Lone Star wins in Gbarnga", long_text, now, now + 600));
    const scores = try scoreAll(alloc, docs.items, &.{}, now);
    var nd: ?Score = null;
    for (scores) |s| {
        if (std.mem.eql(u8, s.source_id, "new-dawn")) nd = s;
    }
    const s = nd.?;
    // All five new-dawn titles duplicate the observer's: originality 0.
    try std.testing.expectApproxEqAbs(0.0, s.components[3].value, 0.001);
    // Every doc mentions Bong County: local knowledge 1.0.
    try std.testing.expectApproxEqAbs(1.0, s.components[6].value, 0.001);
}

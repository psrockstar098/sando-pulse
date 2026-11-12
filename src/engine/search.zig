//! Retrieval: plan -> repository candidates -> rank -> extractive answer.
//! The answer is built ONLY from indexed document text, quoted with
//! citations. If no document clears the evidence threshold, Pulse returns
//! `sufficient = false` and says it does not know — never a fabricated answer.

const std = @import("std");
const types = @import("../common/types.zig");
const planner = @import("planner.zig");
const ranking = @import("ranking.zig");
const entities = @import("entities.zig");
const repository = @import("../storage/repository.zig");

pub const RankedDoc = struct {
    doc: types.Document,
    score: ranking.ScoreParts,
};

pub const Outcome = struct {
    answer: ?[]const u8,
    results: []RankedDoc,
    confidence: f32,
    sufficient: bool,
    insufficient_reason: ?[]const u8,
};

fn firstEvidenceSentence(alloc: std.mem.Allocator, text: []const u8, terms: []const []const u8) !?[]u8 {
    if (text.len == 0) return null;
    const lower = try entities.lowerCopy(alloc, text);
    var it = std.mem.splitScalar(u8, text, '.');
    var first: ?[]const u8 = null;
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\n\r");
        if (s.len < 10) continue;
        if (first == null) first = s;
        // Score sentences by term hits; the first sentence containing any
        // term wins. We check containment on the lowercased full text by
        // finding the sentence's offset — simpler: lowercase the sentence.
        const s_lower = try entities.lowerCopy(alloc, s);
        for (terms) |t| {
            if (std.mem.indexOf(u8, s_lower, t) != null) {
                return try std.fmt.allocPrint(alloc, "{s}.", .{s});
            }
        }
        _ = lower;
    }
    if (first) |f| return try std.fmt.allocPrint(alloc, "{s}.", .{f});
    return null;
}

/// Run one planned query against a repository and rank the evidence.
pub fn searchAndRank(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    p: planner.Plan,
    now: i64,
) !Outcome {
    const q = types.SearchQuery{
        .terms = p.terms,
        .counties = p.counties,
        .organizations = p.organizations,
        .topics = p.topics,
        .limit = 100,
    };
    const candidates = try repo.search(alloc, q);

    // Score and keep only evidence above the threshold.
    var ranked: std.ArrayList(RankedDoc) = .empty;
    for (candidates) |doc| {
        const s = try ranking.scoreDocument(alloc, doc, p.terms, p.counties, p.organizations, p.topics, now);
        if (s.total >= ranking.min_evidence_score) {
            try ranked.append(alloc, .{ .doc = doc, .score = s });
        }
    }
    // Sort best-first (insertion sort; result sets are small).
    const items = ranked.items;
    if (items.len > 1) {
        for (1..items.len) |i| {
            var j = i;
            while (j > 0 and items[j].score.total > items[j - 1].score.total) {
                const tmp = items[j];
                items[j] = items[j - 1];
                items[j - 1] = tmp;
                j -= 1;
            }
        }
    }
    const top_n = @min(items.len, 10);
    const top = items[0..top_n];

    if (top.len == 0) {
        const reason: []const u8 = if (candidates.len == 0)
            "no_documents_matched"
        else
            "evidence_below_threshold";
        return .{
            .answer = null,
            .results = &.{},
            .confidence = 0,
            .sufficient = false,
            .insufficient_reason = reason,
        };
    }

    var top_docs: std.ArrayList(types.Document) = .empty;
    for (top) |r| try top_docs.append(alloc, r.doc);
    const conf = ranking.confidence(top_docs.items, p.topics, now);

    // Extractive answer: one evidence sentence per top doc (max 3), each
    // cited with its result number. Text comes from the documents only.
    var answer_parts: std.ArrayList([]const u8) = .empty;
    const cite_n = @min(top.len, 3);
    for (0..cite_n) |i| {
        const doc = top[i].doc;
        const sentence = try firstEvidenceSentence(alloc, doc.text, p.terms) orelse
            try std.fmt.allocPrint(alloc, "{s}.", .{doc.title});
        try answer_parts.append(alloc, try std.fmt.allocPrint(alloc, "{s} [{d}]", .{ sentence, i + 1 }));
    }
    const answer = try std.mem.join(alloc, " ", answer_parts.items);

    return .{
        .answer = answer,
        .results = try ranked.toOwnedSlice(alloc),
        .confidence = conf,
        .sufficient = true,
        .insufficient_reason = null,
    };
}

test "searchAndRank answers from evidence with citations" {
    const memory = @import("../storage/memory.zig");
    const now: i64 = 1_800_000_000;
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    const doc = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues as the fuel shortage continues across the city.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{ "energy", "economy" },
        .content_hash = "d1",
    };
    try repo.insertDocument(doc);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try planner.plan(alloc, "fuel shortage in Monrovia", &.{ "new-dawn" }, now, 0);
    const out = try searchAndRank(alloc, repo, p, now);
    try std.testing.expect(out.sufficient);
    try std.testing.expect(out.answer != null);
    try std.testing.expect(std.mem.indexOf(u8, out.answer.?, "[1]") != null);
    try std.testing.expectEqual(@as(usize, 1), out.results.len);
    try std.testing.expect(out.confidence > 0);
}

test "searchAndRank says it does not know when there is no evidence" {
    const memory = @import("../storage/memory.zig");
    const now: i64 = 1_800_000_000;
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try planner.plan(alloc, "quantum computing breakthrough in Lofa", &.{ "new-dawn" }, now, 0);
    const out = try searchAndRank(alloc, repo, p, now);
    try std.testing.expect(!out.sufficient);
    try std.testing.expect(out.answer == null);
    try std.testing.expect(out.insufficient_reason != null);
    try std.testing.expectEqual(@as(f32, 0), out.confidence);
}

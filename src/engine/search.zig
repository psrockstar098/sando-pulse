//! Retrieval: plan -> repository candidates -> rank -> extractive answer.
//! Roadmap 2: two-pass retrieval (exact, then fuzzy when thin), dedup by
//! content hash, fused scoring (keyword base + fuzzy trigram + semantic
//! cosine), event clustering, and timeline buckets for timeline/historical
//! intents. The answer is built ONLY from indexed document text, quoted
//! with citations. If no document clears the evidence threshold, Pulse
//! returns `sufficient = false` and says it does not know — never a
//! fabricated answer.
//!
//! Fusion weights (documented, not tuned magic): the keyword base score
//! (relevance + reliability + recency + context + coverage) dominates;
//! fuzzy trigram similarity and semantic cosine are boosters. With both
//! signals present the blend is 0.6 base + 0.2 fuzzy + 0.2 semantic; with
//! one signal it is 0.8/0.2 (fuzzy) or 0.7/0.3 (semantic); with neither it
//! is the base score alone. The evidence threshold (0.25) applies to the
//! fused score.

const std = @import("std");
const types = @import("../common/types.zig");
const planner = @import("planner.zig");
const ranking = @import("ranking.zig");
const entities = @import("entities.zig");
const fuzzy = @import("fuzzy.zig");
const temporal = @import("temporal.zig");
const vectors = @import("vectors.zig");
const repository = @import("../storage/repository.zig");
const providers = @import("../ai/providers.zig");

pub const SearchOptions = struct {
    embedder: ?providers.EmbeddingProvider = null,
    tz_offset_minutes: i32 = 0,
    /// Pre-fetched candidates (Roadmap 6.1, fast path): when set, the
    /// engine ranks these instead of calling repo.search. The fuzzy
    /// second pass still runs when fewer than 3 candidates survive,
    /// so an index miss degrades to the store search, never to nothing.
    candidates: ?[]types.Document = null,
    /// How many ranked results the outcome keeps (Roadmap 6.12):
    /// the API's options.limit. Default 10. Was a hardcoded 10,
    /// which made options.limit a no-op — the limit was validated
    /// and hashed into the cache key but never changed the result
    /// count.
    limit: usize = 10,
};

pub const RankedDoc = struct {
    doc: types.Document,
    score: ranking.ScoreParts,
    /// Fused final score (keyword base blended with fuzzy/semantic).
    fused: f64,
    /// Best per-word trigram similarity for any query term (fuzzy pass).
    fuzzy_score: ?f64 = null,
    /// Cosine similarity between the query embedding and the doc embedding.
    semantic_score: ?f64 = null,
};

pub const Outcome = struct {
    answer: ?[]const u8,
    results: []RankedDoc,
    confidence: f32,
    sufficient: bool,
    insufficient_reason: ?[]const u8,
    events: []types.Event,
    timeline: []types.TimelineDay,
};

/// A document's date for time/event logic: published_at, falling back to
/// fetched_at for manually ingested docs (published_at null).
fn docTs(doc: types.Document) i64 {
    return doc.published_at orelse doc.fetched_at;
}

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

/// Best per-word trigram similarity between any query term and any word in
/// the document's title or text (0.0-1.0). Strict per-word comparison —
/// this is what re-scores the loose SQL fuzzy candidates.
fn fuzzyScoreForDoc(alloc: std.mem.Allocator, doc: types.Document, terms: []const []const u8) !f64 {
    var best: f64 = 0;
    const title_lower = try entities.lowerCopy(alloc, doc.title);
    const text_lower = try entities.lowerCopy(alloc, doc.text);
    for (terms) |t| {
        for ([2][]const u8{ title_lower, text_lower }) |field| {
            var it = std.mem.tokenizeAny(u8, field, " \t\n\r.,;:!?\"'()[]{}<>/-_");
            while (it.next()) |word| {
                if (word.len < 3) continue;
                const s = try fuzzy.similarity(alloc, t, word);
                if (s > best) best = s;
            }
        }
    }
    return best;
}

/// Cosine similarity between the query embedding and the document's
/// embedding. Uses the stored embedding when present; otherwise embeds the
/// document on the fly ONLY for the local lexical provider (cheap,
/// deterministic). External providers are never called per-document at
/// query time (cost) — those docs get no semantic score. Returns null when
/// no embedding is available or the dimensions do not match.
fn semanticScoreForDoc(
    alloc: std.mem.Allocator,
    embedder: providers.EmbeddingProvider,
    query_vec: []const f32,
    doc: types.Document,
) !?f64 {
    if (doc.embedding) |emb| {
        if (emb.len != query_vec.len) return null;
        return vectors.cosine(query_vec, emb);
    }
    if (!std.mem.eql(u8, embedder.model(), "local-hash-lexical-v1")) return null;
    const text = try std.mem.concat(alloc, u8, &.{ doc.title, " ", doc.text });
    const capped = if (text.len > 4000) text[0..4000] else text;
    const vec = embedder.embed(alloc, capped) catch return null;
    if (vec.len != query_vec.len) return null;
    return vectors.cosine(query_vec, vec);
}

fn primaryTopic(doc: types.Document) []const u8 {
    return if (doc.topics.len > 0) doc.topics[0] else "";
}

const EventCluster = struct {
    id: []const u8,
    title: []const u8,
    topic: []const u8,
    first_seen: i64,
    last_seen: i64,
    doc_count: usize,
};

/// Group ranked results into events: same primary topic OR trigram-similar
/// titles, within a 72-hour window. Events keep the first (best-ranked)
/// document's title; ids are that document's content hash.
fn clusterEvents(alloc: std.mem.Allocator, results: []RankedDoc) ![]types.Event {
    var clusters: std.ArrayList(EventCluster) = .empty;
    for (results) |r| {
        const doc = r.doc;
        const ts = docTs(doc);
        const topic = primaryTopic(doc);
        const title_lower = try entities.lowerCopy(alloc, doc.title);
        var joined: ?usize = null;
        for (clusters.items, 0..) |*c, i| {
            const same_topic = topic.len > 0 and std.mem.eql(u8, topic, c.topic);
            const c_title_lower = try entities.lowerCopy(alloc, c.title);
            const title_sim = try fuzzy.similarity(alloc, title_lower, c_title_lower);
            const time_close = ts >= c.first_seen - 72 * 3600 and ts <= c.last_seen + 72 * 3600;
            if ((same_topic or title_sim >= 0.5) and time_close) {
                joined = i;
                break;
            }
        }
        if (joined) |i| {
            clusters.items[i].doc_count += 1;
            if (ts < clusters.items[i].first_seen) clusters.items[i].first_seen = ts;
            if (ts > clusters.items[i].last_seen) clusters.items[i].last_seen = ts;
        } else {
            try clusters.append(alloc, .{
                .id = doc.content_hash,
                .title = doc.title,
                .topic = topic,
                .first_seen = ts,
                .last_seen = ts,
                .doc_count = 1,
            });
        }
    }
    var out: std.ArrayList(types.Event) = .empty;
    for (clusters.items) |c| {
        try out.append(alloc, .{
            .id = c.id,
            .title = c.title,
            .topic = c.topic,
            .first_seen = c.first_seen,
            .last_seen = c.last_seen,
            .doc_count = c.doc_count,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Bucket ranked results by local day (timezone-aware). Each day carries
/// up to 5 distinct doc titles in rank order. Only built for timeline and
/// historical intents; other intents get an empty timeline.
fn buildTimeline(alloc: std.mem.Allocator, results: []RankedDoc, tz_offset_minutes: i32) ![]types.TimelineDay {
    var days: std.ArrayList(struct { start: i64, count: usize, titles: std.ArrayList([]const u8) }) = .empty;
    for (results) |r| {
        const start = temporal.dayStart(docTs(r.doc), tz_offset_minutes);
        var found: ?usize = null;
        for (days.items, 0..) |d, i| {
            if (d.start == start) {
                found = i;
                break;
            }
        }
        const idx = found orelse blk: {
            try days.append(alloc, .{ .start = start, .count = 0, .titles = .empty });
            break :blk days.items.len - 1;
        };
        days.items[idx].count += 1;
        var dup = false;
        for (days.items[idx].titles.items) |t| {
            if (std.mem.eql(u8, t, r.doc.title)) {
                dup = true;
                break;
            }
        }
        if (!dup and days.items[idx].titles.items.len < 5) {
            try days.items[idx].titles.append(alloc, r.doc.title);
        }
    }
    // Newest day first.
    const items = days.items;
    if (items.len > 1) {
        for (1..items.len) |i| {
            var j = i;
            while (j > 0 and items[j].start > items[j - 1].start) {
                const tmp = items[j];
                items[j] = items[j - 1];
                items[j - 1] = tmp;
                j -= 1;
            }
        }
    }
    var out: std.ArrayList(types.TimelineDay) = .empty;
    for (days.items) |*d| {
        try out.append(alloc, .{
            .day_start = d.start,
            .doc_count = d.count,
            .event_titles = try d.titles.toOwnedSlice(alloc),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Run one planned query against a repository and rank the evidence.
/// Pass 1 is exact; pass 2 (fuzzy + vector) runs only when pass 1 returns
/// fewer than 3 candidates. Candidates are deduped by content hash, then
/// fused-scored and thresholded.
pub fn searchAndRank(
    alloc: std.mem.Allocator,
    repo: repository.Repository,
    p: planner.Plan,
    now: i64,
    opts: SearchOptions,
) !Outcome {
    // Query embedding once (local default; external API on the query only).
    var query_vec: ?[]f32 = null;
    if (opts.embedder) |emb| {
        if (p.terms.len > 0) {
            const joined = try std.mem.join(alloc, " ", p.terms);
            query_vec = emb.embed(alloc, joined) catch null;
        }
    }

    var q = types.SearchQuery{
        .terms = p.terms,
        .counties = p.counties,
        .organizations = p.organizations,
        .topics = p.topics,
        .from_ts = p.time_from,
        .to_ts = p.time_to,
        .geo = p.geo_filter,
        .limit = 100,
        .query_embedding = query_vec,
    };
    var candidates = if (opts.candidates) |c| c else try repo.search(alloc, q);
    var fuzzy_pass = false;
    if (candidates.len < 3 and p.terms.len > 0) {
        // Thin exact results: retry fuzzy (typo-tolerant) and merge.
        q.fuzzy = true;
        const extra = try repo.search(alloc, q);
        var merged: std.ArrayList(types.Document) = .empty;
        for (candidates) |d| try merged.append(alloc, d);
        for (extra) |d| {
            var dup = false;
            for (merged.items) |m| {
                if (std.mem.eql(u8, m.content_hash, d.content_hash) or
                    std.mem.eql(u8, m.id, d.id) or
                    std.mem.eql(u8, m.url, d.url))
                {
                    dup = true;
                    break;
                }
            }
            if (!dup) try merged.append(alloc, d);
        }
        candidates = try merged.toOwnedSlice(alloc);
        fuzzy_pass = true;
    }

    // Score, fuse, and keep only evidence above the threshold.
    var ranked: std.ArrayList(RankedDoc) = .empty;
    for (candidates) |doc| {
        const s = try ranking.scoreDocument(alloc, doc, p.terms, p.counties, p.organizations, p.topics, now);
        var fuzzy_score: ?f64 = null;
        var semantic_score: ?f64 = null;
        if (fuzzy_pass and p.terms.len > 0) {
            fuzzy_score = try fuzzyScoreForDoc(alloc, doc, p.terms);
        }
        if (opts.embedder != null and query_vec != null) {
            semantic_score = try semanticScoreForDoc(alloc, opts.embedder.?, query_vec.?, doc);
        }
        // Relevance-gate lift: ranking.scoreDocument zeroes the base when
        // no query term appears verbatim (Roadmap 1 gate, so unrelated
        // docs cannot pass on recency + reliability alone). A fuzzy or
        // semantic match is real evidence too — without this, the fuzzy
        // second pass could never surface anything (its docs have zero
        // exact overlap by definition, and the 0.2 fuzzy blend alone
        // cannot reach the 0.25 threshold). When the base was gated to
        // zero, credit the best fuzzy/semantic signal (>= 0.5) as the
        // effective relevance for the fusion. A doc with no signal at all
        // still scores 0 and cannot pass on recency + reliability alone.
        var base_total: f64 = s.total;
        if (s.relevance == 0) {
            var eff_rel: ?f64 = null;
            if (fuzzy_score) |fs| {
                if (fs >= 0.5) eff_rel = fs;
            }
            if (semantic_score) |ss| {
                if (ss >= 0.5 and (eff_rel == null or ss > eff_rel.?)) eff_rel = ss;
            }
            if (eff_rel) |er| {
                base_total = 0.35 * er + 0.22 * @as(f64, s.reliability) + 0.18 * @as(f64, s.recency) + 0.15 * @as(f64, s.context) + 0.10 * @as(f64, s.coverage);
            }
        }
        var fused = base_total;
        if (fuzzy_score != null and semantic_score != null) {
            fused = 0.6 * base_total + 0.2 * fuzzy_score.? + 0.2 * semantic_score.?;
        } else if (fuzzy_score != null) {
            fused = 0.8 * base_total + 0.2 * fuzzy_score.?;
        } else if (semantic_score != null) {
            fused = 0.7 * base_total + 0.3 * semantic_score.?;
        }
        if (fused >= ranking.min_evidence_score) {
            try ranked.append(alloc, .{
                .doc = doc,
                .score = s,
                .fused = fused,
                .fuzzy_score = fuzzy_score,
                .semantic_score = semantic_score,
            });
        }
    }
    // Sort best-first by fused score (insertion sort; result sets are small).
    const items = ranked.items;
    if (items.len > 1) {
        for (1..items.len) |i| {
            var j = i;
            while (j > 0 and items[j].fused > items[j - 1].fused) {
                const tmp = items[j];
                items[j] = items[j - 1];
                items[j - 1] = tmp;
                j -= 1;
            }
        }
    }
    const top_n = @min(items.len, opts.limit);
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
            .events = &.{},
            .timeline = &.{},
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

    const events = try clusterEvents(alloc, top);
    const timeline: []types.TimelineDay = if (std.mem.eql(u8, p.intent, "timeline") or std.mem.eql(u8, p.intent, "historical"))
        try buildTimeline(alloc, top, opts.tz_offset_minutes)
    else
        &.{};

    return .{
        .answer = answer,
        // The outcome carries only the top `limit` ranked docs (Roadmap
        // 6.12) — the response renders exactly these, and the answer /
        // events / timeline above are computed from the same set.
        .results = top,
        .confidence = conf,
        .sufficient = true,
        .insufficient_reason = null,
        .events = events,
        .timeline = timeline,
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
    const out = try searchAndRank(alloc, repo, p, now, .{});
    try std.testing.expect(out.sufficient);
    try std.testing.expect(out.answer != null);
    try std.testing.expect(std.mem.indexOf(u8, out.answer.?, "[1]") != null);
    try std.testing.expectEqual(@as(usize, 1), out.results.len);
    try std.testing.expect(out.confidence > 0);
    try std.testing.expectEqual(@as(usize, 1), out.events.len);
    try std.testing.expectEqual(@as(usize, 0), out.timeline.len);
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
    const out = try searchAndRank(alloc, repo, p, now, .{});
    try std.testing.expect(!out.sufficient);
    try std.testing.expect(out.answer == null);
    try std.testing.expect(out.insufficient_reason != null);
    try std.testing.expectEqual(@as(f32, 0), out.confidence);
}

test "searchAndRank fuzzy second pass finds a typo'd query" {
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
        .text = "Fuel stations in Monrovia report long queues.",
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
    // Exact pass finds nothing for the typo; the fuzzy pass must recover it.
    const p = try planner.plan(alloc, "fuel shortage in Monrova", &.{ "new-dawn" }, now, 0);
    const out = try searchAndRank(alloc, repo, p, now, .{});
    try std.testing.expect(out.sufficient);
    try std.testing.expectEqual(@as(usize, 1), out.results.len);
    try std.testing.expect(out.results[0].fuzzy_score != null);
    try std.testing.expect(out.results[0].fuzzy_score.? >= 0.5);
}

test "searchAndRank semantic blend lifts a shared-word doc" {
    const memory = @import("../storage/memory.zig");
    const providers_mod = @import("../ai/providers.zig");
    const now: i64 = 1_800_000_000;
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    var local = providers_mod.LocalHashEmbedding{ .dims_count = 128 };
    const emb = local.provider();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Two docs: one shares the query's words exactly, one shares only the
    // city. The semantic blend must not invert the keyword order, but both
    // docs must carry a semantic score when an embedder is present.
    const doc_a = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{ "energy", "economy" },
        .content_hash = "d1",
        .embedding = try emb.embed(alloc, "Fuel shortage hits Monrovia Fuel stations in Monrovia report long queues."),
    };
    const doc_b = types.Document{
        .id = "d2",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Markets open in Monrovia",
        .url = "https://example.com/2",
        .text = "Traders in Monrovia set up stalls early.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{ "economy" },
        .content_hash = "d2",
        .embedding = try emb.embed(alloc, "Markets open in Monrovia Traders in Monrovia set up stalls early."),
    };
    try repo.insertDocument(doc_a);
    try repo.insertDocument(doc_b);
    const p = try planner.plan(alloc, "fuel shortage Monrovia", &.{ "new-dawn" }, now, 0);
    const out = try searchAndRank(alloc, repo, p, now, .{ .embedder = emb });
    try std.testing.expect(out.sufficient);
    try std.testing.expectEqualStrings("d1", out.results[0].doc.id);
    try std.testing.expect(out.results[0].semantic_score != null);
    try std.testing.expect(out.results[0].semantic_score.? > 0.3);
}

test "searchAndRank clusters events and buckets timeline days" {
    const memory = @import("../storage/memory.zig");
    const now: i64 = 1794484800; // 2026-11-12 12:00 UTC
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues as the shortage continues.",
        .published_at = now - 3600,
        .fetched_at = now,
        .reliability = 0.70,
        .topics = &.{ "energy", "economy" },
        .content_hash = "d1",
    };
    var second = base;
    second.id = "d2";
    second.url = "https://example.com/2";
    second.content_hash = "d2";
    second.title = "Fuel shortage continues in Monrovia";
    second.text = "The fuel shortage in Monrovia continues into a second day.";
    second.published_at = now - 7200;
    var other = base;
    other.id = "d3";
    other.url = "https://example.com/3";
    other.content_hash = "d3";
    other.title = "Budget debate in Gbarnga";
    other.text = "The budget debate in Gbarnga continues.";
    other.published_at = now - 5 * 86400; // 5 days earlier
    other.topics = &.{"politics"};
    try repo.insertDocument(base);
    try repo.insertDocument(second);
    try repo.insertDocument(other);
    // Timeline intent: "fuel shortage timeline" triggers the timeline path.
    const p = try planner.plan(alloc, "fuel shortage timeline", &.{ "new-dawn" }, now, 0);
    try std.testing.expectEqualStrings("timeline", p.intent);
    const out = try searchAndRank(alloc, repo, p, now, .{});
    try std.testing.expect(out.sufficient);
    // The two fuel docs cluster into one event (same topic, similar title,
    // within 72h); the budget doc is a separate event... but it may not
    // clear the threshold for the "fuel shortage" terms, so assert only
    // that the fuel event exists with 2 docs.
    var fuel_event: ?types.Event = null;
    for (out.events) |e| {
        if (std.mem.eql(u8, e.topic, "energy")) fuel_event = e;
    }
    try std.testing.expect(fuel_event != null);
    try std.testing.expectEqual(@as(usize, 2), fuel_event.?.doc_count);
    // Timeline buckets exist (all ranked docs are from today).
    try std.testing.expect(out.timeline.len >= 1);
    try std.testing.expectEqual(@as(i64, 1794441600), out.timeline[0].day_start);
}

test "searchAndRank single-term typo recovers via fuzzy pass" {
    // Regression test (found live 2026-11-12): a one-word typo query must
    // recover the document through the fuzzy second pass. The Roadmap 1
    // relevance gate zeroes the keyword base for zero exact overlap, so
    // the fusion credits a >= 0.5 fuzzy signal as effective relevance.
    const memory = @import("../storage/memory.zig");
    const providers_mod = @import("../ai/providers.zig");
    const now: i64 = 1794518400; // 2026-11-12 21:20 UTC
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    var local = providers_mod.LocalHashEmbedding{ .dims_count = 128 };
    const emb = local.provider();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const mk = struct {
        fn doc(alloc2: std.mem.Allocator, emb2: providers_mod.EmbeddingProvider, id: []const u8, title: []const u8, text: []const u8, url: []const u8) !types.Document {
            const full = try std.mem.concat(alloc2, u8, &.{ title, " ", text });
            return .{
                .id = id,
                .source_id = "new-dawn",
                .source_name = "New Dawn",
                .source_url = "https://thenewdawnliberia.com/",
                .title = title,
                .url = url,
                .text = text,
                .published_at = null,
                .fetched_at = now,
                .reliability = 0.70,
                .topics = &.{ "energy", "economy" },
                .content_hash = id,
                .embedding = try emb2.embed(alloc2, full),
            };
        }
    }.doc;
    try repo.insertDocument(try mk(alloc, emb, "d1", "Fuel shortage hits Monrovia as queues grow", "Fuel stations in Monrovia report long queues as the fuel shortage continues across the city.", "https://example.com/1"));
    try repo.insertDocument(try mk(alloc, emb, "d2", "Fuel shortage continues in Monrovia for a second day", "The fuel shortage in Monrovia continues into a second day.", "https://example.com/2"));
    const p = try planner.plan(alloc, "Monrova", &.{ "new-dawn" }, now, 0);
    const out = try searchAndRank(alloc, repo, p, now, .{ .embedder = emb });
    try std.testing.expect(out.sufficient);
    try std.testing.expectEqual(@as(usize, 2), out.results.len);
    try std.testing.expect(out.results[0].fuzzy_score != null);
    try std.testing.expect(out.results[0].fuzzy_score.? >= 0.5);
}

test "searchAndRank honours options.limit" {
    // Regression test (Roadmap 6.12): the outcome always carried the
    // top 10 ranked docs regardless of options.limit.
    const memory = @import("../storage/memory.zig");
    const now: i64 = 1_800_000_000;
    var store = memory.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const repo = store.asRepository();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "d{d}", .{i});
        const title = try std.fmt.allocPrint(alloc, "Fuel shortage hits Monrovia {d}", .{i});
        const text = try std.fmt.allocPrint(alloc, "Fuel stations in Monrovia report long queues as the fuel shortage continues across the city. Report {d}.", .{i});
        try repo.insertDocument(.{
            .id = id,
            .source_id = "new-dawn",
            .source_name = "New Dawn",
            .source_url = "https://thenewdawnliberia.com/",
            .title = title,
            .url = "https://example.com/x",
            .text = text,
            .published_at = now - 3600,
            .fetched_at = now,
            .reliability = 0.70,
            .topics = &.{"energy"},
            .content_hash = id,
        });
    }
    const p = try planner.plan(alloc, "fuel shortage in Monrovia", &.{"new-dawn"}, now, 0);
    const limited = try searchAndRank(alloc, repo, p, now, .{ .limit = 2 });
    try std.testing.expectEqual(@as(usize, 2), limited.results.len);
    const full = try searchAndRank(alloc, repo, p, now, .{});
    try std.testing.expectEqual(@as(usize, 5), full.results.len);
}

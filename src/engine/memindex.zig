//! In-memory inverted index (Roadmap 6.3).
//!
//! term -> postings (doc_id, score). Built from the store at boot,
//! updated incrementally on in-process ingests, rebuilt when the cache
//! epoch moves (worker ingests bump it). Bounded by term count,
//! document count, and approximate bytes; the coldest terms and the
//! oldest documents are evicted first, so the index always holds the
//! hottest, newest slice of the store.
//!
//! The index is an accelerator, never the only source of truth:
//! Postgres (or the memory store) is always the fallback, and every
//! candidate id is resolved through `Repository.getDocument`. Tokenization
//! matches the planner exactly (same delimiters, same stopword list,
//! lowercased) so query terms hit the same terms the documents were
//! indexed under.
//!
//! Single-threaded server: no locking — the same rule as the L1 cache.
//! The worker process holds its own index; indexes are per-process.

const std = @import("std");
const types = @import("../common/types.zig");
const entities = @import("entities.zig");
const repository = @import("../storage/repository.zig");

pub const default_max_terms: usize = 50000;
pub const default_max_docs: usize = 100000;
pub const default_max_bytes: usize = 64 * 1024 * 1024;
/// Only the first N bytes of a document's text are indexed.
pub const max_indexed_text_bytes: usize = 4000;

pub const Candidate = struct {
    doc_id: []const u8,
    score: f32,
};

const Posting = struct {
    doc_id: []u8,
    score: f32,
    last_access_ms: i64,
};

const TermEntry = struct {
    postings: std.ArrayList(Posting),
    last_access_ms: i64,
};

pub const BuildReport = struct {
    docs_seen: usize = 0,
    docs_added: usize = 0,
    docs_evicted: usize = 0,
    terms: usize = 0,
    duration_ms: i64 = 0,
};

pub const MemIndex = struct {
    alloc: std.mem.Allocator,
    terms: std.StringHashMap(*TermEntry),
    /// doc_id -> owned list of indexed terms (for removal/re-index).
    doc_terms: std.StringHashMap([][]u8),
    /// Insertion order (oldest first) for the sliding-window doc cap.
    doc_order: std.ArrayList([]u8),
    max_terms: usize,
    max_docs: usize,
    max_bytes: usize,
    bytes: usize = 0,
    docs_indexed: usize = 0,
    evictions: u64 = 0,
    builds: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, max_terms: usize, max_docs: usize, max_bytes: usize) MemIndex {
        return .{
            .alloc = alloc,
            .terms = std.StringHashMap(*TermEntry).init(alloc),
            .doc_terms = std.StringHashMap([][]u8).init(alloc),
            .doc_order = .empty,
            .max_terms = @max(1, max_terms),
            .max_docs = @max(1, max_docs),
            .max_bytes = @max(1, max_bytes),
        };
    }

    pub fn deinit(self: *MemIndex) void {
        var tit = self.terms.iterator();
        while (tit.next()) |kv| {
            const te = kv.value_ptr.*;
            for (te.postings.items) |p| self.alloc.free(p.doc_id);
            te.postings.deinit(self.alloc);
            self.alloc.destroy(te);
            self.alloc.free(kv.key_ptr.*);
        }
        self.terms.deinit();
        var dit = self.doc_terms.iterator();
        while (dit.next()) |kv| {
            for (kv.value_ptr.*) |t| self.alloc.free(t);
            self.alloc.free(kv.value_ptr.*);
            self.alloc.free(kv.key_ptr.*);
        }
        self.doc_terms.deinit();
        for (self.doc_order.items) |id| self.alloc.free(id);
        self.doc_order.deinit(self.alloc);
    }

    /// Search the index for documents matching any of `terms`
    /// (lowercased by the caller or here). Returns candidates sorted by
    /// descending summed score, at most `limit`. The doc_id slices are
    /// borrowed from the index; copy them before mutating it.
    pub fn search(self: *MemIndex, alloc: std.mem.Allocator, terms: []const []const u8, now_ms: i64, limit: usize) ![]Candidate {
        var scores = std.StringHashMap(f32).init(alloc);
        defer scores.deinit();
        for (terms) |raw| {
            const term = try entities.lowerCopy(alloc, raw);
            defer alloc.free(term);
            const entry = self.terms.get(term) orelse continue;
            entry.last_access_ms = now_ms;
            for (entry.postings.items) |*p| {
                p.last_access_ms = now_ms;
                const e = try scores.getOrPut(p.doc_id);
                if (!e.found_existing) e.value_ptr.* = 0;
                e.value_ptr.* += p.score;
            }
        }
        var out: std.ArrayList(Candidate) = .empty;
        var it = scores.iterator();
        while (it.next()) |kv| {
            try out.append(alloc, .{ .doc_id = kv.key_ptr.*, .score = kv.value_ptr.* });
        }
        std.mem.sort(Candidate, out.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lt);
        if (out.items.len > limit) out.items.len = limit;
        return out.toOwnedSlice(alloc);
    }

    /// Index (or re-index) one document. Title terms weigh double.
    /// Evicts the oldest documents first when the doc cap is hit, and
    /// the coldest terms first when the term cap is hit.
    pub fn addDocument(self: *MemIndex, doc: types.Document, now_ms: i64) !void {
        if (self.doc_terms.contains(doc.id)) self.removeDocument(doc.id);
        while (self.docs_indexed >= self.max_docs and self.doc_order.items.len > 0) {
            self.removeDocument(self.doc_order.items[0]);
            self.evictions += 1;
        }
        // Count term frequencies: title terms weigh double. The freq
        // map owns duped keys; they are freed with the map below.
        var freq = std.StringHashMap(u32).init(self.alloc);
        defer {
            var kit = freq.keyIterator();
            while (kit.next()) |k| self.alloc.free(k.*);
            freq.deinit();
        }
        try countTerms(self.alloc, doc.title, &freq, 2);
        const text = if (doc.text.len > max_indexed_text_bytes) doc.text[0..max_indexed_text_bytes] else doc.text;
        try countTerms(self.alloc, text, &freq, 1);

        var indexed_terms: std.ArrayList([]u8) = .empty;
        errdefer {
            for (indexed_terms.items) |t| self.alloc.free(t);
            indexed_terms.deinit(self.alloc);
        }
        var fit = freq.iterator();
        while (fit.next()) |kv| {
            const term = kv.key_ptr.*;
            const score: f32 = @floatFromInt(@min(kv.value_ptr.*, 12));
            if (!self.terms.contains(term)) {
                if (self.terms.count() >= self.max_terms or self.bytes >= self.max_bytes) {
                    self.evictColdestTerm();
                    if (!self.terms.contains(term) and (self.terms.count() >= self.max_terms or self.bytes >= self.max_bytes)) {
                        // Still full after evicting one cold term: skip
                        // this term rather than evicting the whole index.
                        continue;
                    }
                }
            }
            const entry = try self.termEntry(term, now_ms);
            var replaced = false;
            for (entry.postings.items) |*p| {
                if (std.mem.eql(u8, p.doc_id, doc.id)) {
                    p.score = score;
                    p.last_access_ms = now_ms;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                const owned_id = try self.alloc.dupe(u8, doc.id);
                errdefer self.alloc.free(owned_id);
                try entry.postings.append(self.alloc, .{ .doc_id = owned_id, .score = score, .last_access_ms = now_ms });
                self.bytes += 24 + owned_id.len;
            }
            const owned_term = try self.alloc.dupe(u8, term);
            errdefer self.alloc.free(owned_term);
            try indexed_terms.append(self.alloc, owned_term);
        }
        const owned_id = try self.alloc.dupe(u8, doc.id);
        errdefer self.alloc.free(owned_id);
        try self.doc_terms.put(owned_id, try indexed_terms.toOwnedSlice(self.alloc));
        try self.doc_order.append(self.alloc, try self.alloc.dupe(u8, doc.id));
        self.docs_indexed += 1;
    }

    fn termEntry(self: *MemIndex, term: []const u8, now_ms: i64) !*TermEntry {
        if (self.terms.get(term)) |e| return e;
        const entry = try self.alloc.create(TermEntry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{ .postings = .empty, .last_access_ms = now_ms };
        const owned = try self.alloc.dupe(u8, term);
        errdefer self.alloc.free(owned);
        try self.terms.put(owned, entry);
        self.bytes += owned.len + 48;
        return entry;
    }

    fn evictColdestTerm(self: *MemIndex) void {
        var victim_key: ?[]const u8 = null;
        var victim_access: i64 = std.math.maxInt(i64);
        var it = self.terms.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.last_access_ms < victim_access) {
                victim_access = kv.value_ptr.*.last_access_ms;
                victim_key = kv.key_ptr.*;
            }
        }
        const k = victim_key orelse return;
        const entry = self.terms.get(k).?;
        _ = self.terms.remove(k);
        for (entry.postings.items) |p| {
            self.bytes -= 24 + p.doc_id.len;
            self.alloc.free(p.doc_id);
        }
        entry.postings.deinit(self.alloc);
        self.alloc.destroy(entry);
        self.bytes -= k.len + 48;
        self.alloc.free(k);
        self.evictions += 1;
    }

    /// Remove a document from the index entirely. No-op when absent.
    pub fn removeDocument(self: *MemIndex, doc_id: []const u8) void {
        const term_list = self.doc_terms.get(doc_id) orelse return;
        for (term_list) |term| {
            if (self.terms.get(term)) |entry| {
                var i: usize = 0;
                while (i < entry.postings.items.len) {
                    if (std.mem.eql(u8, entry.postings.items[i].doc_id, doc_id)) {
                        const p = entry.postings.orderedRemove(i);
                        self.bytes -= 24 + p.doc_id.len;
                        self.alloc.free(p.doc_id);
                    } else i += 1;
                }
                if (entry.postings.items.len == 0) {
                    const k = self.terms.getKey(term).?;
                    _ = self.terms.remove(term);
                    entry.postings.deinit(self.alloc);
                    self.alloc.destroy(entry);
                    self.bytes -= k.len + 48;
                    self.alloc.free(k);
                }
            }
            self.alloc.free(term);
        }
        const owned_list = term_list;
        const key = self.doc_terms.getKey(doc_id).?;
        _ = self.doc_terms.remove(doc_id);
        self.alloc.free(owned_list);
        self.alloc.free(key);
        for (self.doc_order.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, doc_id)) {
                const removed = self.doc_order.orderedRemove(i);
                self.alloc.free(removed);
                break;
            }
        }
        self.docs_indexed -= 1;
    }

    /// Rebuild the index from the store. Scans in batches of 1000 with
    /// a moving cutoff; a seen-set dedupes the boundary timestamp so no
    /// document is indexed twice. The sliding doc cap keeps the NEWEST
    /// documents: older ones are evicted as the scan proceeds. Returns
    /// a report with measured counts and wall time.
    pub fn buildFromRepo(self: *MemIndex, alloc: std.mem.Allocator, repo: repository.Repository, now_ms: i64, start_ms: i64) !BuildReport {
        var report = BuildReport{};
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var before_ts: ?i64 = null;
        while (true) {
            const batch = try repo.scanDocuments(alloc, before_ts, 1000);
            defer alloc.free(batch);
            if (batch.len == 0) break;
            var added_this_batch: usize = 0;
            var newest: i64 = 0;
            for (batch) |doc| {
                report.docs_seen += 1;
                if (doc.fetched_at > newest) newest = doc.fetched_at;
                if (seen.contains(doc.id)) continue;
                try seen.put(doc.id, {});
                const before_evictions = self.evictions;
                try self.addDocument(doc, now_ms);
                report.docs_added += 1;
                added_this_batch += 1;
                report.docs_evicted += @intCast(self.evictions - before_evictions);
            }
            if (added_this_batch == 0) break;
            // Next window: documents fetched at or after the newest
            // timestamp in this batch (the boundary second is re-scanned
            // and deduped by the seen-set).
            before_ts = newest + 1;
            if (batch.len < 1000) break;
        }
        report.terms = self.terms.count();
        report.duration_ms = now_ms - start_ms;
        self.builds += 1;
        return report;
    }
};

const stopwords: []const []const u8 = &.{
    "the", "a", "an", "in", "on", "at", "of", "for", "to", "and", "or",
    "what", "is", "are", "was", "were", "how", "when", "where", "who",
    "why", "did", "do", "does", "latest", "news", "about", "with",
    "from", "by", "this", "that", "it", "its", "there", "here", "today",
    "now", "happening", "going", "tell", "me", "please", "any", "some",
    "has", "have", "been", "being", "will", "would", "can", "could",
    "should", "i", "you", "we", "they", "he", "she", "his", "her",
    "their", "our", "your", "as", "if", "but", "not", "no", "yes",
};

fn isStopword(w: []const u8) bool {
    for (stopwords) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

/// Count term frequencies in `text` (lowercased, same delimiters as the
/// planner), adding `weight` per occurrence. Keys are owned by `freq`'s
/// allocator and freed with it.
fn countTerms(alloc: std.mem.Allocator, text: []const u8, freq: *std.StringHashMap(u32), weight: u32) !void {
    const lower = try entities.lowerCopy(alloc, text);
    defer alloc.free(lower);
    var it = std.mem.tokenizeAny(u8, lower, " \t\n\r.,;:!?()[]{}\"'/\\-_");
    while (it.next()) |tok| {
        if (tok.len < 2) continue;
        if (isStopword(tok)) continue;
        const e = try freq.getOrPut(tok);
        if (!e.found_existing) {
            e.key_ptr.* = try alloc.dupe(u8, tok);
            e.value_ptr.* = 0;
        }
        e.value_ptr.* += weight;
    }
}

fn testDoc(id: []const u8, title: []const u8, text: []const u8) types.Document {
    return .{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = title,
        .url = "https://example.com/x",
        .text = text,
        .published_at = null,
        .fetched_at = 1000,
        .reliability = 0.7,
        .topics = &.{},
        .content_hash = "h",
        .lang = "en",
    };
}

test "memindex add/search ranks by term frequency and title weight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var idx = MemIndex.init(alloc, 1000, 100, 1024 * 1024);
    defer idx.deinit();
    try idx.addDocument(testDoc("d1", "fuel shortage", "fuel fuel fuel queues in Monrovia"), 1000);
    try idx.addDocument(testDoc("d2", "sports roundup", "fuel prices mentioned once"), 1000);
    const cands = try idx.search(alloc, &.{"fuel"}, 2000, 10);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    // d1: title fuel x2 weight + 3 in text = 7; d2: 1 in text = 1.
    try std.testing.expectEqualStrings("d1", cands[0].doc_id);
    try std.testing.expect(cands[0].score > cands[1].score);
    // A stopword-only query finds nothing.
    const none = try idx.search(alloc, &.{"the"}, 2000, 10);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "memindex removeDocument drops the doc from every term" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var idx = MemIndex.init(alloc, 1000, 100, 1024 * 1024);
    defer idx.deinit();
    try idx.addDocument(testDoc("d1", "fuel shortage", "fuel queues"), 1000);
    try std.testing.expectEqual(@as(usize, 1), (try idx.search(alloc, &.{"fuel"}, 1000, 10)).len);
    idx.removeDocument("d1");
    try std.testing.expectEqual(@as(usize, 0), (try idx.search(alloc, &.{"fuel"}, 1000, 10)).len);
    try std.testing.expectEqual(@as(usize, 0), idx.docs_indexed);
}

test "memindex re-index replaces the old terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var idx = MemIndex.init(alloc, 1000, 100, 1024 * 1024);
    defer idx.deinit();
    try idx.addDocument(testDoc("d1", "fuel shortage", "fuel queues"), 1000);
    try idx.addDocument(testDoc("d1", "health workers", "nurses strike"), 1000);
    try std.testing.expectEqual(@as(usize, 0), (try idx.search(alloc, &.{"fuel"}, 1000, 10)).len);
    try std.testing.expectEqual(@as(usize, 1), (try idx.search(alloc, &.{"nurses"}, 1000, 10)).len);
    try std.testing.expectEqual(@as(usize, 1), idx.docs_indexed);
}

test "memindex doc cap keeps the newest documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var idx = MemIndex.init(alloc, 1000, 2, 1024 * 1024);
    defer idx.deinit();
    try idx.addDocument(testDoc("d1", "aaa bbb", "aaa"), 1000);
    try idx.addDocument(testDoc("d2", "ccc ddd", "ccc"), 1000);
    try idx.addDocument(testDoc("d3", "eee fff", "eee"), 1000);
    try std.testing.expectEqual(@as(usize, 2), idx.docs_indexed);
    try std.testing.expectEqual(@as(usize, 0), (try idx.search(alloc, &.{"aaa"}, 1000, 10)).len);
    try std.testing.expectEqual(@as(usize, 1), (try idx.search(alloc, &.{"eee"}, 1000, 10)).len);
}

test "memindex term cap evicts a cold term instead of failing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var idx = MemIndex.init(alloc, 2, 100, 1024 * 1024);
    defer idx.deinit();
    try idx.addDocument(testDoc("d1", "alpha beta", "alpha beta"), 1000);
    try std.testing.expectEqual(@as(usize, 2), idx.terms.count());
    try idx.addDocument(testDoc("d2", "gamma delta", "gamma delta"), 2000);
    try std.testing.expect(idx.terms.count() <= 2);
    try std.testing.expect(idx.evictions > 0);
}

test "memindex live: build from Postgres, search, resolve by id" {
    const postgres = @import("../storage/postgres.zig");
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = (try postgres.getTestEnvVar(alloc, io, "PULSE_TEST_POSTGRES_URL")) orelse {
        std.debug.print("skip: PULSE_TEST_POSTGRES_URL not set\n", .{});
        return;
    };
    defer alloc.free(url);
    var store = try postgres.PostgresStore.init(alloc, io, url);
    defer store.deinit();
    var repo = store.repository();

    // Insert a doc with a marker term that cannot collide with real data.
    const id = try types.contentHash(alloc, "new-dawn", "https://example.com/pg-memindex", "Pulse memindex live test");
    defer alloc.free(id);
    const doc = types.Document{
        .id = id,
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Pulse memindex live test",
        .url = "https://example.com/pg-memindex",
        .text = "A unique quixotry marker for the memindex live test.",
        .published_at = null,
        .fetched_at = 1762953600,
        .reliability = 0.70,
        .topics = &.{"politics"},
        .content_hash = id,
    };
    try repo.insertDocument(doc);
    defer _ = repo.deleteDocuments(&.{id}) catch 0;

    // getDocument resolves the id directly.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const got = try repo.getDocument(arena.allocator(), id);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("Pulse memindex live test", got.?.title);
    try std.testing.expect((try repo.getDocument(arena.allocator(), "no-such-id")) == null);

    // Build the index from the store and resolve the marker through it.
    var idx = MemIndex.init(alloc, 50000, 100000, 64 * 1024 * 1024);
    defer idx.deinit();
    const report = try idx.buildFromRepo(arena.allocator(), repo, 2000, 1000);
    try std.testing.expect(report.docs_seen >= 1);
    try std.testing.expect(report.docs_added >= 1);
    const cands = try idx.search(arena.allocator(), &.{"quixotry"}, 3000, 10);
    var saw_it = false;
    for (cands) |c| {
        if (std.mem.eql(u8, c.doc_id, id)) saw_it = true;
    }
    try std.testing.expect(saw_it);
}

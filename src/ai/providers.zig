//! AI integration interfaces (Roadmap 2.4): embedding, summarization,
//! entity extraction, and classification providers. ALL application-side
//! integration code remains Zig. Models can run locally (the built-in
//! adapters below) or through external inference APIs (OpenAI-compatible
//! endpoints via the fetcher's POST). No model code lives in this repo;
//! providers are swappable at runtime through config, and every provider
//! reports its model name so answers can say where an embedding or a
//! summary came from.
//!
//! The local embedding adapter is a deterministic hashed lexical embedding:
//! it places texts with shared words near each other, which is enough for
//! retrieval over a small news corpus, and it is HONESTLY labelled as
//! lexical, not semantic. A real semantic embedding needs either pgvector
//! with a model-produced vector or an external embedding API.

const std = @import("std");
const fetchers = @import("../ingestion/fetchers.zig");
const entities = @import("../engine/entities.zig");

/// ---------------------------------------------------------------------------
/// Embedding providers
/// ---------------------------------------------------------------------------

pub const EmbeddingProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        embed: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) anyerror![]f32,
        dims: *const fn (ptr: *anyopaque) usize,
        model: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    /// L2-normalized embedding. Caller owns the result.
    pub fn embed(self: EmbeddingProvider, alloc: std.mem.Allocator, text: []const u8) ![]f32 {
        return self.vtable.embed(self.ptr, alloc, text);
    }

    pub fn dims(self: EmbeddingProvider) usize {
        return self.vtable.dims(self.ptr);
    }

    pub fn model(self: EmbeddingProvider) []const u8 {
        return self.vtable.model(self.ptr);
    }

    pub fn deinit(self: EmbeddingProvider, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

/// Local hashed lexical embedding. Tokenizes to lowercase words, hashes
/// each word into one of `dims` buckets (FNV-1a), adds 1 per occurrence,
/// then L2-normalizes. Deterministic across runs; same text -> same vector.
/// NOT a semantic model: it measures word overlap, not meaning.
pub const LocalHashEmbedding = struct {
    dims_count: usize,
    model_name: []const u8 = "local-hash-lexical-v1",

    pub fn provider(self: *LocalHashEmbedding) EmbeddingProvider {
        return .{ .ptr = self, .vtable = &.{
            .embed = embedFn,
            .dims = dimsFn,
            .model = modelFn,
            .deinit = deinitFn,
        } };
    }

    fn embedFn(ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]f32 {
        const self: *LocalHashEmbedding = @ptrCast(@alignCast(ptr));
        const vec = try alloc.alloc(f32, self.dims_count);
        @memset(vec, 0);
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}<>/-_");
        while (it.next()) |tok| {
            if (tok.len < 2) continue;
            var lower_buf: [64]u8 = undefined;
            const word = if (tok.len <= lower_buf.len) std.ascii.lowerString(lower_buf[0..tok.len], tok) else tok;
            var h = std.hash.Fnv1a_64.init();
            h.update(word);
            const bucket: usize = @intCast(h.final() % @as(u64, @intCast(self.dims_count)));
            vec[bucket] += 1;
        }
        // L2-normalize.
        var sum: f64 = 0;
        for (vec) |x| sum += @as(f64, x) * @as(f64, x);
        const n = @sqrt(sum);
        if (n > 0) {
            for (vec) |*x| x.* = @floatCast(@as(f64, x.*) / n);
        }
        return vec;
    }

    fn dimsFn(ptr: *anyopaque) usize {
        const self: *LocalHashEmbedding = @ptrCast(@alignCast(ptr));
        return self.dims_count;
    }

    fn modelFn(ptr: *anyopaque) []const u8 {
        const self: *LocalHashEmbedding = @ptrCast(@alignCast(ptr));
        return self.model_name;
    }

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
};

/// External OpenAI-compatible embedding adapter: POST {base_url}/embeddings
/// {"model": ..., "input": ...} and parse the `data[0].embedding` array.
/// The API key comes from the environment at runtime, never from a file.
pub const ExternalEmbedding = struct {
    base_url: []const u8, // e.g. "https://api.openai.com/v1"
    model_name: []const u8,
    api_key: []const u8, // borrowed; never logged
    dims_count: usize, // expected dims; 0 = accept whatever the API returns
    io: std.Io,
    environ: ?*const std.process.Environ.Map,

    pub fn provider(self: *ExternalEmbedding) EmbeddingProvider {
        return .{ .ptr = self, .vtable = &.{
            .embed = embedFn,
            .dims = dimsFn,
            .model = modelFn,
            .deinit = deinitFn,
        } };
    }

    fn embedFn(ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]f32 {
        const self: *ExternalEmbedding = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(alloc, "{s}/embeddings", .{self.base_url});
        defer alloc.free(url);
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try std.json.Stringify.value(.{ .model = self.model_name, .input = text }, .{}, &aw.writer);
        const req = try aw.toOwnedSlice();
        var res = try fetchers.postJson(alloc, self.io, url, req, self.api_key, self.environ);
        defer res.deinit(alloc);
        if (res.status != 200) return error.EmbeddingApiFailed;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, res.body, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data") orelse return error.EmbeddingApiFailed;
        if (data != .array or data.array.items.len == 0) return error.EmbeddingApiFailed;
        const emb = data.array.items[0].object.get("embedding") orelse return error.EmbeddingApiFailed;
        if (emb != .array) return error.EmbeddingApiFailed;
        const vec = try alloc.alloc(f32, emb.array.items.len);
        for (emb.array.items, 0..) |item, i| {
            if (item != .float and item != .integer) {
                alloc.free(vec);
                return error.EmbeddingApiFailed;
            }
            vec[i] = @floatCast(if (item == .float) item.float else @as(f64, @floatFromInt(item.integer)));
        }
        return vec;
    }

    fn dimsFn(ptr: *anyopaque) usize {
        const self: *ExternalEmbedding = @ptrCast(@alignCast(ptr));
        return self.dims_count;
    }

    fn modelFn(ptr: *anyopaque) []const u8 {
        const self: *ExternalEmbedding = @ptrCast(@alignCast(ptr));
        return self.model_name;
    }

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
};

/// Build the configured embedding provider. "none" returns null (keyword
/// search only). "external" needs both a URL and a key and returns null
/// without them. Anything else (including the "local" default) returns the
/// local hashed lexical embedding. The concrete provider structs are
/// allocated from `alloc` and borrowed by the returned value — in main they
/// live in the process arena, so they outlive the server/worker.
pub fn makeEmbeddingProvider(
    alloc: std.mem.Allocator,
    io: std.Io,
    provider_name: []const u8,
    api_url: ?[]const u8,
    api_key: ?[]const u8,
    model: []const u8,
    dims: usize,
    environ: ?*const std.process.Environ.Map,
) !?EmbeddingProvider {
    if (std.mem.eql(u8, provider_name, "none")) return null;
    if (std.mem.eql(u8, provider_name, "external")) {
        const url = api_url orelse return null;
        const key = api_key orelse return null;
        const ext = try alloc.create(ExternalEmbedding);
        ext.* = .{
            .base_url = url,
            .model_name = model,
            .api_key = key,
            .dims_count = dims,
            .io = io,
            .environ = environ,
        };
        return ext.provider();
    }
    const local = try alloc.create(LocalHashEmbedding);
    local.* = .{ .dims_count = dims };
    return local.provider();
}

/// ---------------------------------------------------------------------------
/// Summarization providers
/// ---------------------------------------------------------------------------

pub const SummarizationProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        summarize: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8, max_sentences: usize) anyerror![]u8,
        model: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    /// Extractive summary: the top `max_sentences` sentences by term
    /// overlap with the rest of the text. Caller owns the result.
    pub fn summarize(self: SummarizationProvider, alloc: std.mem.Allocator, text: []const u8, max_sentences: usize) ![]u8 {
        return self.vtable.summarize(self.ptr, alloc, text, max_sentences);
    }

    pub fn model(self: SummarizationProvider) []const u8 {
        return self.vtable.model(self.ptr);
    }

    pub fn deinit(self: SummarizationProvider, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

/// Local extractive summarizer. Splits on sentence boundaries, scores each
/// sentence by how many of its words appear elsewhere in the text (a
/// centrality proxy), keeps the top N in original order. It only repeats
/// the source's own sentences — it never writes new claims.
pub const ExtractiveSummarizer = struct {
    model_name: []const u8 = "local-extractive-v1",

    pub fn provider(self: *ExtractiveSummarizer) SummarizationProvider {
        return .{ .ptr = self, .vtable = &.{
            .summarize = summarizeFn,
            .model = modelFn,
            .deinit = deinitFn,
        } };
    }

    fn summarizeFn(ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8, max_sentences: usize) ![]u8 {
        _ = ptr;
        // Split into sentences.
        var sentences: std.ArrayList([]const u8) = .empty;
        defer sentences.deinit(alloc);
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == '.' or c == '!' or c == '?') {
                const end = i + 1;
                const s = std.mem.trim(u8, text[start..end], " \t\n\r");
                if (s.len > 0) try sentences.append(alloc, s);
                start = end;
            }
        }
        const tail = std.mem.trim(u8, text[start..], " \t\n\r");
        if (tail.len > 0) try sentences.append(alloc, tail);
        if (sentences.items.len == 0) return alloc.dupe(u8, text);
        if (sentences.items.len <= max_sentences) return alloc.dupe(u8, text);

        // Word frequency over the whole text.
        var freq = std.StringHashMap(usize).init(alloc);
        defer {
            // Map keys are owned dupes: free them, not just the table.
            var kit = freq.keyIterator();
            while (kit.next()) |k| alloc.free(k.*);
            freq.deinit();
        }
        {
            var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}<>/-_");
            while (it.next()) |tok| {
                if (tok.len < 3) continue;
                var buf: [64]u8 = undefined;
                const w = if (tok.len <= buf.len) std.ascii.lowerString(buf[0..tok.len], tok) else tok;
                const gop = try freq.getOrPut(w);
                if (!gop.found_existing) {
                    const owned = try alloc.dupe(u8, w);
                    gop.key_ptr.* = owned;
                    gop.value_ptr.* = 1;
                } else {
                    gop.value_ptr.* += 1;
                }
            }
        }
        // Score each sentence by the sum of its words' frequencies.
        const Scored = struct { idx: usize, score: usize };
        var scored = try alloc.alloc(Scored, sentences.items.len);
        defer alloc.free(scored);
        for (sentences.items, 0..) |s, idx| {
            var score: usize = 0;
            var it = std.mem.tokenizeAny(u8, s, " \t\n\r.,;:!?\"'()[]{}<>/-_");
            while (it.next()) |tok| {
                if (tok.len < 3) continue;
                var buf: [64]u8 = undefined;
                const w = if (tok.len <= buf.len) std.ascii.lowerString(buf[0..tok.len], tok) else tok;
                if (freq.get(w)) |f| score += f;
            }
            scored[idx] = .{ .idx = idx, .score = score };
        }
        std.mem.sort(Scored, scored, {}, struct {
            fn lessThan(_: void, a: Scored, b: Scored) bool {
                return a.score > b.score;
            }
        }.lessThan);
        // Keep the top N, then restore original order.
        const keep = @min(max_sentences, scored.len);
        var chosen = try alloc.alloc(usize, keep);
        defer alloc.free(chosen);
        for (0..keep) |k| chosen[k] = scored[k].idx;
        std.mem.sort(usize, chosen, {}, struct {
            fn lessThan(_: void, a: usize, b: usize) bool {
                return a < b;
            }
        }.lessThan);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (chosen, 0..) |idx, k| {
            if (k > 0) try out.appendSlice(alloc, " ");
            try out.appendSlice(alloc, sentences.items[idx]);
        }
        return out.toOwnedSlice(alloc);
    }

    fn modelFn(ptr: *anyopaque) []const u8 {
        const self: *ExtractiveSummarizer = @ptrCast(@alignCast(ptr));
        return self.model_name;
    }

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
};

/// ---------------------------------------------------------------------------
/// Entity extraction + classification providers
/// ---------------------------------------------------------------------------

/// Entity extraction backed by the local Liberian entity lists. A model
/// adapter can replace this; the interface keeps the shape identical.
pub const EntityExtractionProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        extract: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) anyerror!entities.Entities,
        model: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    pub fn extract(self: EntityExtractionProvider, alloc: std.mem.Allocator, text: []const u8) !entities.Entities {
        return self.vtable.extract(self.ptr, alloc, text);
    }

    pub fn model(self: EntityExtractionProvider) []const u8 {
        return self.vtable.model(self.ptr);
    }

    pub fn deinit(self: EntityExtractionProvider, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

pub const LocalEntityExtractor = struct {
    model_name: []const u8 = "local-liberian-lists-v1",

    pub fn provider(self: *LocalEntityExtractor) EntityExtractionProvider {
        return .{ .ptr = self, .vtable = &.{
            .extract = extractFn,
            .model = modelFn,
            .deinit = deinitFn,
        } };
    }

    fn extractFn(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) !entities.Entities {
        return entities.extract(alloc, text);
    }

    fn modelFn(ptr: *anyopaque) []const u8 {
        const self: *LocalEntityExtractor = @ptrCast(@alignCast(ptr));
        return self.model_name;
    }

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
};

/// Classification backed by the local topic rules. A model adapter can
/// replace this; the interface keeps the shape identical.
pub const ClassificationProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        classify: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) anyerror![]const u8,
        model: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    /// Returns the best-matching topic label (borrowed string).
    pub fn classify(self: ClassificationProvider, alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
        return self.vtable.classify(self.ptr, alloc, text);
    }

    pub fn model(self: ClassificationProvider) []const u8 {
        return self.vtable.model(self.ptr);
    }

    pub fn deinit(self: ClassificationProvider, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

pub const LocalTopicClassifier = struct {
    model_name: []const u8 = "local-topic-rules-v1",

    pub fn provider(self: *LocalTopicClassifier) ClassificationProvider {
        return .{ .ptr = self, .vtable = &.{
            .classify = classifyFn,
            .model = modelFn,
            .deinit = deinitFn,
        } };
    }

    fn classifyFn(_: *anyopaque, alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
        const ent = try entities.extract(alloc, text);
        defer entities.freeEntities(alloc, ent);
        if (ent.topics.len == 0) return "general";
        return ent.topics[0];
    }

    fn modelFn(ptr: *anyopaque) []const u8 {
        const self: *LocalTopicClassifier = @ptrCast(@alignCast(ptr));
        return self.model_name;
    }

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
};

/// ---------------------------------------------------------------------------
/// Optional answer synthesis (Roadmap 2.4): stitch an answer from evidence.
/// The synthesizer NEVER invents facts: it only reorders and quotes the
/// evidence sentences it is given, with citations. A model-based adapter
/// can replace the template, but the no-invention rule stays.
/// ---------------------------------------------------------------------------

/// Build a grounded answer from evidence sentences. `evidence` is a list of
/// (sentence, citation index) pairs; the output quotes them in order with
/// [n] markers. Caller owns the result.
pub fn synthesizeGrounded(alloc: std.mem.Allocator, evidence: []const struct { sentence: []const u8, citation: usize }) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (evidence) |ev| {
        if (ev.sentence.len == 0) continue;
        try out.writer.print("{s} [{d}] ", .{ std.mem.trim(u8, ev.sentence, " \t\n\r"), ev.citation });
    }
    const raw = try out.toOwnedSlice();
    defer alloc.free(raw);
    return alloc.dupe(u8, std.mem.trim(u8, raw, " "));
}

test "providers: local hash embedding is deterministic and lexical" {
    const alloc = std.testing.allocator;
    var local = LocalHashEmbedding{ .dims_count = 128 };
    const p = local.provider();
    try std.testing.expectEqual(@as(usize, 128), p.dims());
    const a = try p.embed(alloc, "fuel shortage hits Monrovia");
    defer alloc.free(a);
    const b = try p.embed(alloc, "fuel shortage hits Monrovia");
    defer alloc.free(b);
    try std.testing.expectEqualSlices(f32, a, b);
    const c = try p.embed(alloc, "zebra crossing in the rainforest");
    defer alloc.free(c);
    // Same words -> cosine 1; disjoint words -> near 0.
    const vectors = @import("../engine/vectors.zig");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), vectors.cosine(a, b), 0.001);
    try std.testing.expect(vectors.cosine(a, c) < 0.5);
    // L2-normalized.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), vectors.norm(a), 0.001);
}

test "providers: extractive summarizer keeps source sentences" {
    const alloc = std.testing.allocator;
    var s = ExtractiveSummarizer{};
    const p = s.provider();
    const text = "Fuel prices rose again in Monrovia. The shortage has lasted three weeks. " ++
        "Drivers queue for hours at filling stations. Fuel prices rose again in Monrovia. " ++
        "The government says supply ships are on the way. Fuel prices rose again in Monrovia.";
    const summary = try p.summarize(alloc, text, 2);
    defer alloc.free(summary);
    // The repeated sentence is the most central; the summary must only
    // contain sentences from the source.
    try std.testing.expect(std.mem.indexOf(u8, summary, "Fuel prices rose again in Monrovia") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "invented") == null);
}

test "providers: local entity + topic classification" {
    const alloc = std.testing.allocator;
    var e = LocalEntityExtractor{};
    const ep = e.provider();
    const ent = try ep.extract(alloc, "The President spoke in Monrovia about the budget.");
    defer entities.freeEntities(alloc, ent);
    try std.testing.expect(ent.cities.len > 0);
    var c = LocalTopicClassifier{};
    const cp = c.provider();
    const topic = try cp.classify(alloc, "Fuel prices rose at the pump today.");
    try std.testing.expect(topic.len > 0);
}

test "providers: grounded synthesis only quotes evidence" {
    const alloc = std.testing.allocator;
    const out = try synthesizeGrounded(alloc, &.{
        .{ .sentence = "Fuel prices rose.", .citation = 1 },
        .{ .sentence = "The shortage lasted three weeks.", .citation = 2 },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Fuel prices rose. [1] The shortage lasted three weeks. [2]", out);
}

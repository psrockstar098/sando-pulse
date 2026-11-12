//! Vector math and an in-memory vector store (Roadmap 2.2 semantic search).
//! The Postgres store keeps embeddings in a `vector` column and ranks with
//! pgvector's `<=>` operator; this module provides the same operations in
//! pure Zig for the memory store and for tests, plus the shared similarity
//! functions used by the hybrid engine.

const std = @import("std");

pub const Vector = []const f32;

pub fn dot(a: Vector, b: Vector) f64 {
    std.debug.assert(a.len == b.len);
    var sum: f64 = 0;
    for (a, b) |x, y| sum += @as(f64, x) * @as(f64, y);
    return sum;
}

pub fn norm(a: Vector) f64 {
    return @sqrt(dot(a, a));
}

/// Cosine similarity in [-1, 1]. 1.0 = same direction.
pub fn cosine(a: Vector, b: Vector) f64 {
    const na = norm(a);
    const nb = norm(b);
    if (na == 0 or nb == 0) return 0;
    return dot(a, b) / (na * nb);
}

/// Cosine distance in [0, 2], matching pgvector's `<=>` operator.
pub fn cosineDistance(a: Vector, b: Vector) f64 {
    return 1.0 - cosine(a, b);
}

/// L2-normalize a vector in place.
pub fn normalizeInPlace(v: []f32) void {
    const n = norm(v);
    if (n == 0) return;
    for (v) |*x| x.* = @floatCast(@as(f64, x.*) / n);
}

/// L2-normalized copy. Caller owns the result.
pub fn normalized(alloc: std.mem.Allocator, v: Vector) ![]f32 {
    const out = try alloc.dupe(f32, v);
    normalizeInPlace(out);
    return out;
}

pub const Hit = struct {
    doc_id: []const u8,
    /// Cosine similarity to the query vector.
    score: f64,
};

/// In-memory nearest-neighbour store: doc id -> embedding.
/// Used by the memory repository and as the fallback when pgvector is
/// unavailable. Linear scan is fine at this scale (thousands of docs).
pub const VectorStore = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap([]f32),

    pub fn init(alloc: std.mem.Allocator) VectorStore {
        return .{ .alloc = alloc, .map = std.StringHashMap([]f32).init(alloc) };
    }

    pub fn deinit(self: *VectorStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn upsert(self: *VectorStore, doc_id: []const u8, vector: Vector) !void {
        const owned = try self.alloc.dupe(f32, vector);
        if (self.map.fetchRemove(doc_id)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        const key = try self.alloc.dupe(u8, doc_id);
        try self.map.put(key, owned);
    }

    pub fn count(self: *const VectorStore) usize {
        return self.map.count();
    }

    pub fn get(self: *const VectorStore, doc_id: []const u8) ?Vector {
        return self.map.get(doc_id);
    }

    /// Top-k nearest by cosine similarity, highest first.
    /// Caller owns the returned slice (doc_id slices borrow the store).
    pub fn topK(self: *const VectorStore, alloc: std.mem.Allocator, query: Vector, k: usize) ![]Hit {
        var hits: std.ArrayList(Hit) = .empty;
        errdefer hits.deinit(alloc);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.len != query.len) continue;
            try hits.append(alloc, .{ .doc_id = entry.key_ptr.*, .score = cosine(query, entry.value_ptr.*) });
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lessThan(_: void, a: Hit, b: Hit) bool {
                return a.score > b.score;
            }
        }.lessThan);
        const owned = try blk: {
            if (hits.items.len > k) hits.items.len = k;
            break :blk hits.toOwnedSlice(alloc);
        };
        return owned;
    }
};

test "vectors: cosine similarity" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 1, 0, 0 };
    const c = [_]f32{ 0, 1, 0 };
    const d = [_]f32{ -1, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&a, &b), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosine(&a, &c), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), cosine(&a, &d), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineDistance(&a, &b), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineDistance(&a, &c), 0.0001);
}

test "vectors: store top-k" {
    const alloc = std.testing.allocator;
    var store = VectorStore.init(alloc);
    defer store.deinit();
    try store.upsert("doc1", &[_]f32{ 1, 0, 0 });
    try store.upsert("doc2", &[_]f32{ 0, 1, 0 });
    try store.upsert("doc3", &[_]f32{ 0.9, 0.1, 0 });
    try std.testing.expectEqual(@as(usize, 3), store.count());
    const hits = try store.topK(alloc, &[_]f32{ 1, 0, 0 }, 2);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("doc1", hits[0].doc_id);
    try std.testing.expectEqualStrings("doc3", hits[1].doc_id);
    try std.testing.expect(hits[0].score > hits[1].score);
}

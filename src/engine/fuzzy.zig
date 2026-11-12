//! Fuzzy matching (Roadmap 2.2): trigram similarity and Levenshtein
//! distance, in pure Zig. The trigram implementation pads like pg_trgm
//! (two spaces before, one after) so its scores track PostgreSQL's
//! similarity() closely enough for the memory store to behave the same
//! way the Postgres store does with pg_trgm.

const std = @import("std");

/// Build the trigram set of a string, lowercased, padded like pg_trgm.
/// Caller owns the returned list and its items.
pub fn trigrams(alloc: std.mem.Allocator, s: []const u8) ![][]const u8 {
    const lower = try alloc.alloc(u8, s.len);
    defer alloc.free(lower);
    _ = std.ascii.lowerString(lower, s);

    var padded = try alloc.alloc(u8, s.len + 3);
    defer alloc.free(padded);
    padded[0] = ' ';
    padded[1] = ' ';
    @memcpy(padded[2 .. 2 + s.len], lower);
    padded[s.len + 2] = ' ';

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |t| alloc.free(t);
        list.deinit(alloc);
    }
    if (padded.len < 3) return list.toOwnedSlice(alloc);
    for (0..padded.len - 2) |i| {
        const tri = try alloc.dupe(u8, padded[i .. i + 3]);
        try list.append(alloc, tri);
    }
    return list.toOwnedSlice(alloc);
}

fn freeTrigrams(alloc: std.mem.Allocator, tris: [][]const u8) void {
    for (tris) |t| alloc.free(t);
    alloc.free(tris);
}

/// Dice coefficient over trigram sets: 2*|A∩B| / (|A|+|B|).
/// 1.0 for identical strings, 0.0 for nothing in common.
pub fn similarity(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !f64 {
    const ta = try trigrams(alloc, a);
    defer freeTrigrams(alloc, ta);
    const tb = try trigrams(alloc, b);
    defer freeTrigrams(alloc, tb);
    if (ta.len == 0 or tb.len == 0) return 0;
    var shared: usize = 0;
    // Count with multiplicity: each trigram in A matches at most one in B.
    var used = try alloc.alloc(bool, tb.len);
    defer alloc.free(used);
    @memset(used, false);
    for (ta) |x| {
        for (tb, 0..) |y, j| {
            if (!used[j] and std.mem.eql(u8, x, y)) {
                used[j] = true;
                shared += 1;
                break;
            }
        }
    }
    return 2.0 * @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(ta.len + tb.len));
}

/// True when `a` is similar enough to `b` to count as a fuzzy match.
pub fn isSimilar(alloc: std.mem.Allocator, a: []const u8, b: []const u8, threshold: f64) !bool {
    return (try similarity(alloc, a, b)) >= threshold;
}

/// Levenshtein edit distance (insert/delete/substitute cost 1).
/// Caller owns nothing; allocates two rows.
pub fn levenshtein(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    const prev = try alloc.alloc(usize, b.len + 1);
    defer alloc.free(prev);
    const cur = try alloc.alloc(usize, b.len + 1);
    defer alloc.free(cur);
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ac, i| {
        cur[0] = i;
        for (b, 1..) |bc, j| {
            const cost: usize = if (ac == bc) 0 else 1;
            cur[j] = @min(prev[j] + 1, @min(cur[j - 1] + 1, prev[j - 1] + cost));
        }
        @memcpy(prev, cur);
    }
    return prev[b.len];
}

test "fuzzy: trigram similarity" {
    const alloc = std.testing.allocator;
    const same = try similarity(alloc, "fuel shortage", "fuel shortage");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), same, 0.001);
    const near = try similarity(alloc, "fuel shortage", "fuel shortag");
    try std.testing.expect(near > 0.7 and near < 0.95);
    const far = try similarity(alloc, "fuel shortage", "zebra crossing");
    try std.testing.expect(far < 0.3);
    const empty = try similarity(alloc, "", "fuel");
    try std.testing.expectEqual(@as(f64, 0), empty);
    try std.testing.expect(try isSimilar(alloc, "monrovia", "monrova", 0.5));
    try std.testing.expect(!try isSimilar(alloc, "monrovia", "gbarnga", 0.5));
}

test "fuzzy: levenshtein" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try levenshtein(alloc, "fuel", "fuel"));
    try std.testing.expectEqual(@as(usize, 1), try levenshtein(alloc, "fuel", "fue"));
    try std.testing.expectEqual(@as(usize, 1), try levenshtein(alloc, "monrovia", "monrova"));
    try std.testing.expectEqual(@as(usize, 3), try levenshtein(alloc, "kitten", "sitting"));
    try std.testing.expectEqual(@as(usize, 4), try levenshtein(alloc, "", "fuel"));
}

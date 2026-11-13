//! Stat answers from the knowledge store (Roadmap 7.2): the planner
//! detects count/stat questions ("How many schools are in Montserrado
//! County?", "What is the population of Nimba?") and answers them
//! from the seeded locations/facilities/statistics, with citations,
//! provenance, and verification date. Unanswerable counts refuse
//! honestly (sufficient:false) — never guessed.
//!
//! Koloqua/dialect queries: NO translation layer in this roadmap.
//! Recorded as a future gap; nothing here fakes understanding.

const std = @import("std");
const knowledge = @import("../storage/knowledge.zig");
const entities_mod = @import("../engine/entities.zig");

/// What kind of stat the question asks for.
pub const StatKind = enum {
    facility_count,
    population,
    statistic,

    pub fn toString(self: StatKind) []const u8 {
        return switch (self) {
            .facility_count => "facility_count",
            .population => "population",
            .statistic => "statistic",
        };
    }
};

pub const StatQuestion = struct {
    kind: StatKind,
    /// Facility kind for a count ("school", "hospital", ...), null
    /// for population/statistic questions.
    facility_kind: ?[]const u8 = null,
    /// Place name as written in the store (canonical case), or null
    /// when the question names no known place.
    place: ?[]const u8 = null,
    /// "county" | "city" | null, matching `place`.
    place_kind: ?[]const u8 = null,
    /// Statistic key for a statistic question
    /// ("liberia_population_2022"), null otherwise.
    stat_key: ?[]const u8 = null,
};

/// The answer, rendered into the query response as `stat_answer`.
/// `sufficient` is false when the store cannot answer — the response
/// then refuses with `insufficient_reason`, never a guess.
pub const StatAnswer = struct {
    question: []const u8,
    kind: []const u8,
    sufficient: bool,
    answer_text: ?[]const u8 = null,
    value: ?f64 = null,
    unit: ?[]const u8 = null,
    period: ?[]const u8 = null,
    /// How many rows backed a count (0 for a population/statistic).
    rows_counted: usize = 0,
    source: ?[]const u8 = null,
    verified_at: ?[]const u8 = null,
    insufficient_reason: ?[]const u8 = null,
};

const facility_words: []const struct { word: []const u8, kind: []const u8 } = &.{
    .{ .word = "schools", .kind = "school" },
    .{ .word = "school", .kind = "school" },
    .{ .word = "hospitals", .kind = "hospital" },
    .{ .word = "hospital", .kind = "hospital" },
    .{ .word = "universities", .kind = "university" },
    .{ .word = "university", .kind = "university" },
    .{ .word = "markets", .kind = "market" },
    .{ .word = "market", .kind = "market" },
    .{ .word = "clinics", .kind = "clinic" },
    .{ .word = "clinic", .kind = "clinic" },
    .{ .word = "institutes", .kind = "institute" },
    .{ .word = "institute", .kind = "institute" },
};

/// Find a known Liberian place (county first, then city) named in
/// the lowercased query. Returns the canonical name + kind, or null.
/// Longest match wins ("Grand Cape Mount" before "Grand").
fn findPlace(lower: []const u8) ?struct { name: []const u8, kind: []const u8 } {
    var best: ?struct { name: []const u8, kind: []const u8 } = null;
    var best_len: usize = 0;
    for (entities_mod.counties) |c| {
        if (c.len <= best_len) continue;
        var buf: [64]u8 = undefined;
        if (c.len > buf.len) continue;
        const lc = std.ascii.lowerString(buf[0..c.len], c);
        if (std.mem.indexOf(u8, lower, lc) != null) {
            best = .{ .name = c, .kind = "county" };
            best_len = c.len;
        }
    }
    for (entities_mod.cities) |c| {
        if (c.len <= best_len) continue;
        var buf: [64]u8 = undefined;
        if (c.len > buf.len) continue;
        const lc = std.ascii.lowerString(buf[0..c.len], c);
        if (std.mem.indexOf(u8, lower, lc) != null) {
            best = .{ .name = c, .kind = "city" };
            best_len = c.len;
        }
    }
    // "Liberia" itself is a place for population questions.
    if (best == null and std.mem.indexOf(u8, lower, "liberia") != null) {
        return .{ .name = "Liberia", .kind = "country" };
    }
    return best;
}

/// Detect a stat question. Returns null for anything else — the
/// normal search pipeline then handles the query untouched.
pub fn detectStatQuestion(alloc: std.mem.Allocator, query: []const u8) !?StatQuestion {
    const lower = try std.ascii.allocLowerString(alloc, query);
    defer alloc.free(lower);
    const place = findPlace(lower);
    // "How many <facility> are in <place>?" — the count question.
    if (std.mem.indexOf(u8, lower, "how many") != null) {
        for (facility_words) |fw| {
            if (std.mem.indexOf(u8, lower, fw.word) != null) {
                return .{
                    .kind = .facility_count,
                    .facility_kind = fw.kind,
                    .place = if (place) |p| p.name else null,
                    .place_kind = if (place) |p| p.kind else null,
                };
            }
        }
        return null;
    }
    // "What is the population of <place>?" — a population question.
    // A bare "population" without a place is not answerable.
    if (std.mem.indexOf(u8, lower, "population") != null) {
        if (place) |p| {
            return .{
                .kind = .population,
                .place = p.name,
                .place_kind = p.kind,
            };
        }
        return null;
    }
    return null;
}

fn placeMatches(row_county: ?[]const u8, row_city: ?[]const u8, q: StatQuestion) bool {
    const place = q.place orelse return false;
    if (std.mem.eql(u8, q.place_kind orelse "", "county")) {
        if (row_county) |c| return std.ascii.eqlIgnoreCase(c, place);
        return false;
    }
    if (std.mem.eql(u8, q.place_kind orelse "", "city")) {
        if (row_city) |c| return std.ascii.eqlIgnoreCase(c, place);
        // A facility in the county of the same name still counts
        // when the city row has no city set.
        if (row_county) |c| return std.ascii.eqlIgnoreCase(c, place);
        return false;
    }
    return false;
}

/// Answer a detected stat question from the knowledge store. Every
/// branch either answers with provenance or refuses with a reason.
pub fn answerStat(alloc: std.mem.Allocator, ks: knowledge.KnowledgeStore, q: StatQuestion, question_text: []const u8) !StatAnswer {
    switch (q.kind) {
        .facility_count => {
            const kind = q.facility_kind.?;
            if (q.place == null) {
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = false,
                    .insufficient_reason = "stat_no_place: a count needs a named county or city",
                };
            }
            const rows = try ks.listFacilities(alloc, kind, 500);
            var counted: usize = 0;
            var verified: ?[]const u8 = null;
            for (rows) |r| {
                if (!placeMatches(r.county, r.city, q)) continue;
                counted += 1;
                if (r.verified_at) |v| {
                    if (verified == null or std.mem.lessThan(u8, verified.?, v)) verified = v;
                }
            }
            if (counted == 0) {
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = false,
                    .insufficient_reason = try std.fmt.allocPrint(alloc, "stat_not_in_knowledge_store: no {s} recorded for {s}", .{ kind, q.place.? }),
                };
            }
            const plural = if (counted == 1) kind else try std.fmt.allocPrint(alloc, "{s}s", .{kind});
            return .{
                .question = question_text,
                .kind = q.kind.toString(),
                .sufficient = true,
                .answer_text = try std.fmt.allocPrint(alloc, "There {s} {d} {s} recorded in {s}.", .{
                    if (counted == 1) "is" else "are",
                    counted,
                    plural,
                    q.place.?,
                }),
                .value = @floatFromInt(counted),
                .unit = "facilities",
                .rows_counted = counted,
                .source = "Pulse knowledge store (seeded facilities)",
                .verified_at = verified,
            };
        },
        .population => {
            const place = q.place.?;
            // Country-level: the seeded Liberia statistics.
            if (std.mem.eql(u8, q.place_kind orelse "", "country")) {
                const stats = try ks.listStatistics(alloc);
                var best: ?knowledge.StatisticRow = null;
                for (stats) |s| {
                    if (!std.mem.startsWith(u8, s.key, "liberia_population_")) continue;
                    if (best == null or std.mem.lessThan(u8, best.?.period, s.period)) best = s;
                }
                if (best) |s| {
                    return .{
                        .question = question_text,
                        .kind = q.kind.toString(),
                        .sufficient = true,
                        .answer_text = try std.fmt.allocPrint(alloc, "The population of Liberia is {d} ({s}).", .{ @as(i64, @intFromFloat(s.value)), s.period }),
                        .value = s.value,
                        .unit = s.unit,
                        .period = s.period,
                        .source = s.source,
                        .verified_at = s.verified_at,
                    };
                }
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = false,
                    .insufficient_reason = "stat_not_in_knowledge_store: no Liberia population statistic recorded",
                };
            }
            // County/city: the location row's census population.
            const locs = try ks.listLocations(alloc, null, 500);
            for (locs) |l| {
                if (!std.ascii.eqlIgnoreCase(l.name, place)) continue;
                if (l.population) |pop| {
                    return .{
                        .question = question_text,
                        .kind = q.kind.toString(),
                        .sufficient = true,
                        .answer_text = try std.fmt.allocPrint(alloc, "The population of {s} is {d} (2008 census).", .{ l.name, pop }),
                        .value = @floatFromInt(pop),
                        .unit = "people",
                        .period = "2008",
                        .source = l.source,
                        .verified_at = l.verified_at,
                    };
                }
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = false,
                    .insufficient_reason = try std.fmt.allocPrint(alloc, "stat_not_published: no census population published for {s}", .{l.name}),
                };
            }
            return .{
                .question = question_text,
                .kind = q.kind.toString(),
                .sufficient = false,
                .insufficient_reason = try std.fmt.allocPrint(alloc, "stat_not_in_knowledge_store: {s} is not in the knowledge store", .{place}),
            };
        },
        .statistic => {
            // Reached only via a stat_key (currently unused by the
            // detector — population questions answer from locations
            // or the Liberia statistics directly). Kept for the
            // statistic-question shape the API documents.
            const key = q.stat_key orelse {
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = false,
                    .insufficient_reason = "stat_not_in_knowledge_store: no statistic key in the question",
                };
            };
            const stats = try ks.listStatistics(alloc);
            for (stats) |s| {
                if (!std.mem.eql(u8, s.key, key)) continue;
                return .{
                    .question = question_text,
                    .kind = q.kind.toString(),
                    .sufficient = true,
                    .answer_text = try std.fmt.allocPrint(alloc, "{s} is {d} {s} ({s}).", .{ s.key, s.value, s.unit, s.period }),
                    .value = s.value,
                    .unit = s.unit,
                    .period = s.period,
                    .source = s.source,
                    .verified_at = s.verified_at,
                };
            }
            return .{
                .question = question_text,
                .kind = q.kind.toString(),
                .sufficient = false,
                .insufficient_reason = try std.fmt.allocPrint(alloc, "stat_not_in_knowledge_store: no statistic named {s}", .{key}),
            };
        },
    }
}

test "detectStatQuestion finds counts and populations, ignores the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const q1 = (try detectStatQuestion(alloc, "How many schools are in Montserrado County?")).?;
    try std.testing.expectEqual(StatKind.facility_count, q1.kind);
    try std.testing.expectEqualStrings("school", q1.facility_kind.?);
    try std.testing.expectEqualStrings("Montserrado", q1.place.?);
    try std.testing.expectEqualStrings("county", q1.place_kind.?);
    const q2 = (try detectStatQuestion(alloc, "What is the population of Nimba?")).?;
    try std.testing.expectEqual(StatKind.population, q2.kind);
    try std.testing.expectEqualStrings("Nimba", q2.place.?);
    const q3 = (try detectStatQuestion(alloc, "What is the population of Liberia?")).?;
    try std.testing.expectEqual(StatKind.population, q3.kind);
    try std.testing.expectEqualStrings("Liberia", q3.place.?);
    try std.testing.expectEqualStrings("country", q3.place_kind.?);
    // No facility word, no population word: not a stat question.
    try std.testing.expect(try detectStatQuestion(alloc, "How many people attended the rally?") == null);
    try std.testing.expect(try detectStatQuestion(alloc, "Fuel prices in Monrovia") == null);
    try std.testing.expect(try detectStatQuestion(alloc, "What is the population?") == null);
    // Count without a place still detects (the answer refuses).
    const q4 = (try detectStatQuestion(alloc, "How many hospitals are there?")).?;
    try std.testing.expectEqual(StatKind.facility_count, q4.kind);
    try std.testing.expect(q4.place == null);
}

test "answerStat counts facilities from the store with provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mk = knowledge.MemoryKnowledge.init(alloc);
    defer mk.deinit();
    const ks = mk.asKnowledge();
    try ks.upsertFacility(alloc, .{ .name = "A School", .kind = "school", .county = "Montserrado", .city = "Monrovia", .source = "test fixture", .verified_at = "2026-11-13" });
    try ks.upsertFacility(alloc, .{ .name = "B School", .kind = "school", .county = "Montserrado", .city = "Virginia", .source = "test fixture", .verified_at = "2026-11-13" });
    try ks.upsertFacility(alloc, .{ .name = "C Hospital", .kind = "hospital", .county = "Montserrado", .city = "Monrovia", .source = "test fixture", .verified_at = "2026-11-13" });
    try ks.upsertFacility(alloc, .{ .name = "D School", .kind = "school", .county = "Nimba", .city = "Ganta", .source = "test fixture", .verified_at = "2026-11-13" });
    const q = StatQuestion{ .kind = .facility_count, .facility_kind = "school", .place = "Montserrado", .place_kind = "county" };
    const a = try answerStat(alloc, ks, q, "How many schools are in Montserrado County?");
    try std.testing.expect(a.sufficient);
    try std.testing.expectEqual(@as(f64, 2), a.value.?);
    try std.testing.expectEqual(@as(usize, 2), a.rows_counted);
    try std.testing.expect(std.mem.indexOf(u8, a.answer_text.?, "2 schools") != null);
    try std.testing.expectEqualStrings("2026-11-13", a.verified_at.?);
    // A county with no schools of that kind refuses, honestly.
    const q2 = StatQuestion{ .kind = .facility_count, .facility_kind = "school", .place = "Lofa", .place_kind = "county" };
    const a2 = try answerStat(alloc, ks, q2, "How many schools are in Lofa County?");
    try std.testing.expect(!a2.sufficient);
    try std.testing.expect(std.mem.indexOf(u8, a2.insufficient_reason.?, "stat_not_in_knowledge_store") != null);
    // No place at all refuses too.
    const q3 = StatQuestion{ .kind = .facility_count, .facility_kind = "hospital", .place = null, .place_kind = null };
    const a3 = try answerStat(alloc, ks, q3, "How many hospitals are there?");
    try std.testing.expect(!a3.sufficient);
}

test "answerStat answers populations and refuses unpublished ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mk = knowledge.MemoryKnowledge.init(alloc);
    defer mk.deinit();
    const ks = mk.asKnowledge();
    try ks.upsertLocation(alloc, .{ .name = "Montserrado", .kind = "county", .population = 1144806, .source = "Wikipedia 2008 census", .verified_at = "2026-11-12" });
    try ks.upsertLocation(alloc, .{ .name = "Nimba", .kind = "county", .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" });
    try ks.upsertStatistic(alloc, .{ .key = "liberia_population_2022", .value = 5250187, .unit = "people", .period = "2022", .source = "Wikipedia Demographics", .verified_at = "2026-11-12" });
    const q = StatQuestion{ .kind = .population, .place = "Montserrado", .place_kind = "county" };
    const a = try answerStat(alloc, ks, q, "What is the population of Montserrado?");
    try std.testing.expect(a.sufficient);
    try std.testing.expectEqual(@as(f64, 1144806), a.value.?);
    try std.testing.expect(std.mem.indexOf(u8, a.answer_text.?, "1144806") != null);
    const q2 = StatQuestion{ .kind = .population, .place = "Nimba", .place_kind = "county" };
    const a2 = try answerStat(alloc, ks, q2, "What is the population of Nimba?");
    try std.testing.expect(!a2.sufficient);
    try std.testing.expect(std.mem.indexOf(u8, a2.insufficient_reason.?, "stat_not_published") != null);
    const q3 = StatQuestion{ .kind = .population, .place = "Liberia", .place_kind = "country" };
    const a3 = try answerStat(alloc, ks, q3, "What is the population of Liberia?");
    try std.testing.expect(a3.sufficient);
    try std.testing.expectEqual(@as(f64, 5250187), a3.value.?);
    try std.testing.expectEqualStrings("2022", a3.period.?);
}

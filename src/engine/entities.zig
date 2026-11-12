//! Entity extraction for Liberian places, organizations, people, and topics.
//! All matching is case-insensitive and word-boundary aware (so "UL" does
//! not match inside "result"). Candidate lists are static; extracted names
//! are canonical spellings from those lists.

const std = @import("std");

pub const Entities = struct {
    counties: []const []const u8 = &.{},
    cities: []const []const u8 = &.{},
    organizations: []const []const u8 = &.{},
    people: []const []const u8 = &.{},
    topics: []const []const u8 = &.{},
};

pub const counties: []const []const u8 = &.{
    "Bomi", "Bong", "Gbarpolu", "Grand Bassa", "Grand Cape Mount",
    "Grand Gedeh", "Grand Kru", "Lofa", "Margibi", "Maryland",
    "Montserrado", "Nimba", "River Cess", "River Gee", "Sinoe",
};

pub const cities: []const []const u8 = &.{
    "Monrovia", "Paynesville", "Gbarnga", "Buchanan", "Ganta",
    "Sanniquellie", "Voinjama", "Zorzor", "Foya", "Harper",
    "Greenville", "Zwedru", "Kakata", "Harbel", "Tubmanburg",
    "Robertsport", "Saclepea", "Tappita", "Pleebo", "Barclayville",
    "Cestos City", "Fish Town", "Bopolu", "Bensonville", "Careysburg",
    "Brewerville", "Virginia", "Caldwell", "Gardnersville",
    "New Kru Town", "Sinkor", "Duala", "Red Light", "Congo Town",
    "West Point", "Clara Town", "Logan Town", "ELWA", "Yekepa",
    "Kolahun", "Suakoko", "Marshall", "Edina",
};

/// Organization display name first, then aliases (acronyms etc.).
pub const organizations: []const []const u8 = &.{
    "LPRC", "Liberia Petroleum Refining Company",
    "CBL", "Central Bank of Liberia",
    "LRA", "Liberia Revenue Authority",
    "NEC", "National Elections Commission",
    "Ministry of Commerce", "Commerce Ministry",
    "Ministry of Information", "MICAT",
    "Ministry of Finance", "Finance Ministry",
    "Ministry of Health", "Health Ministry",
    "Ministry of Education", "Education Ministry",
    "National Legislature", "Legislature",
    "House of Representatives",
    "Senate",
    "LEC", "Liberia Electricity Corporation",
    "LWSC", "Liberia Water and Sewer Corporation",
    "NPA", "National Port Authority",
    "LNP", "Liberia National Police",
    "AFL", "Armed Forces of Liberia",
    "University of Liberia",
    "PUL", "Press Union of Liberia",
    "ArcelorMittal", "AML",
    "Firestone",
};

pub const people: []const []const u8 = &.{
    "Joseph Boakai", "Boakai",
    "Jeremiah Koung", "Koung",
    "George Weah", "Weah",
    "Jewel Howard-Taylor", "Howard-Taylor",
};

pub const TopicRule = struct { topic: []const u8, keywords: []const []const u8 };

pub const topic_rules: []const TopicRule = &.{
    .{ .topic = "energy", .keywords = &.{ "fuel", "petrol", "gasoline", "diesel", "electricity", "power", "blackout", "generator", "lec", "petroleum" } },
    .{ .topic = "economy", .keywords = &.{ "economy", "price", "inflation", "budget", "revenue", "tax", "dollar", "exchange rate", "market", "economy" } },
    .{ .topic = "health", .keywords = &.{ "health", "hospital", "clinic", "disease", "malaria", "cholera", "vaccine", "doctor", "medicine", "mpox" } },
    .{ .topic = "politics", .keywords = &.{ "president", "election", "senate", "legislature", "minister", "government", "party", "cdc", "unity party", "boakai", "weah" } },
    .{ .topic = "society", .keywords = &.{ "community", "school", "road", "water", "sanitation", "housing", "youth" } },
    .{ .topic = "culture", .keywords = &.{ "culture", "music", "festival", "tradition", "geez", "entertainment" } },
    .{ .topic = "education", .keywords = &.{ "school", "university", "student", "teacher", "exam", "waec", "education" } },
    .{ .topic = "sports", .keywords = &.{ "football", "soccer", "lone star", "match", "league", "athlete", "sports" } },
    .{ .topic = "crime", .keywords = &.{ "police", "arrest", "court", "robbery", "murder", "drugs", "cocaine", "trial", "prison" } },
    .{ .topic = "business", .keywords = &.{ "company", "investment", "mining", "gold", "iron ore", "rubber", "agriculture", "concession", "business" } },
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '\'' or c == '-';
}

/// Case-insensitive, word-boundary-aware substring search.
pub fn containsWord(haystack_lower: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0 or needle_lower.len > haystack_lower.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack_lower.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack_lower[i .. i + needle_lower.len], needle_lower)) continue;
        const before_ok = i == 0 or !isWordChar(haystack_lower[i - 1]);
        const after_idx = i + needle_lower.len;
        const after_ok = after_idx >= haystack_lower.len or !isWordChar(haystack_lower[after_idx]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

pub fn lowerCopy(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn matchList(alloc: std.mem.Allocator, text_lower: []const u8, candidates: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (candidates) |cand| {
        const cand_lower = try lowerCopy(alloc, cand);
        defer alloc.free(cand_lower);
        if (containsWord(text_lower, cand_lower)) try out.append(alloc, cand);
    }
    return out.toOwnedSlice(alloc);
}

/// Extract all known entities from `text`. Result slices reference the
/// static tables above (except the outer slices, owned by `alloc`).
/// `alloc` should be an arena: results borrow from it.
pub fn extract(alloc: std.mem.Allocator, text: []const u8) !Entities {
    const lower = try lowerCopy(alloc, text);
    defer alloc.free(lower);
    var ent = Entities{};
    ent.counties = try matchList(alloc, lower, counties);
    ent.cities = try matchList(alloc, lower, cities);
    ent.organizations = try matchList(alloc, lower, organizations);
    ent.people = try matchList(alloc, lower, people);
    // Topics: any keyword hit adds the topic once.
    var topics: std.ArrayList([]const u8) = .empty;
    for (topic_rules) |rule| {
        for (rule.keywords) |kw| {
            if (containsWord(lower, kw)) {
                var dup = false;
                for (topics.items) |t| {
                    if (std.mem.eql(u8, t, rule.topic)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try topics.append(alloc, rule.topic);
                break;
            }
        }
    }
    ent.topics = try topics.toOwnedSlice(alloc);
    return ent;
}

test "containsWord is case-insensitive and boundary aware" {
    try std.testing.expect(containsWord("the lprc announced", "lprc"));
    try std.testing.expect(containsWord("lprc announced", "lprc"));
    try std.testing.expect(!containsWord("result announced", "ul"));
    try std.testing.expect(containsWord("at ul today", "ul"));
    try std.testing.expect(containsWord("in monrovia today", "monrovia"));
    try std.testing.expect(!containsWord("in monroviax today", "monrovia"));
    try std.testing.expect(containsWord("grand bassa county", "grand bassa"));
}

test "extract finds counties, cities, orgs, people, topics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ent = try extract(alloc, "Fuel shortage hits Monrovia as LPRC and President Boakai face questions in Montserrado");
    try std.testing.expectEqual(@as(usize, 1), ent.counties.len);
    try std.testing.expectEqualStrings("Montserrado", ent.counties[0]);
    try std.testing.expectEqual(@as(usize, 1), ent.cities.len);
    try std.testing.expectEqualStrings("Monrovia", ent.cities[0]);
    var saw_lprc = false;
    var saw_boakai = false;
    for (ent.organizations) |o| {
        if (std.mem.eql(u8, o, "LPRC")) saw_lprc = true;
    }
    for (ent.people) |p| {
        if (std.mem.eql(u8, p, "Boakai")) saw_boakai = true;
    }
    try std.testing.expect(saw_lprc);
    try std.testing.expect(saw_boakai);
    var saw_energy = false;
    for (ent.topics) |t| {
        if (std.mem.eql(u8, t, "energy")) saw_energy = true;
    }
    try std.testing.expect(saw_energy);
}

test "extract returns empty for unrelated text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ent = try extract(arena.allocator(), "The quick brown fox jumps over the lazy dog");
    try std.testing.expectEqual(@as(usize, 0), ent.counties.len);
    try std.testing.expectEqual(@as(usize, 0), ent.cities.len);
    try std.testing.expectEqual(@as(usize, 0), ent.organizations.len);
    try std.testing.expectEqual(@as(usize, 0), ent.topics.len);
}

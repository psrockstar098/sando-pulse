//! Trust & Intelligence Engine, Phase 6: natural-language request
//! parser for the Live Intelligence Action Engine.
//!
//! A plain-words request ("what is the latest from New Dawn?", "is
//! it true that fuel prices rose?", "watch for fuel shortages in
//! Bong") becomes a typed action with the entities pulled out of
//! it: source ids/names from the registry, counties from the
//! canonical list, topic keywords from a small static table.
//!
//! The parser NEVER guesses: when no action pattern matches, the
//! kind is `unknown` with a plain-words message saying what was
//! understood and what to try instead. A request that names a source
//! or county that does not exist matches nothing for that entity —
//! it does not invent one.

const std = @import("std");
const sources = @import("../../ingestion/sources.zig");
const geo = @import("../../engine/geo.zig");

pub const ActionKind = enum {
    check_source_latest,
    verify_claim,
    monitor_account,
    whats_happening,
    check_status,
    history_person,
    watch_story,
    unknown,

    pub fn toString(self: ActionKind) []const u8 {
        return switch (self) {
            .check_source_latest => "check_source_latest",
            .verify_claim => "verify_claim",
            .monitor_account => "monitor_account",
            .whats_happening => "whats_happening",
            .check_status => "check_status",
            .history_person => "history_person",
            .watch_story => "watch_story",
            .unknown => "unknown",
        };
    }
};

pub const ParsedAction = struct {
    kind: ActionKind,
    /// Registry source id, when the request names a source.
    source_id: ?[]const u8 = null,
    /// Topic keyword (energy, politics, economy, sports, health,
    /// education, crime, weather), when the request names one.
    topic: ?[]const u8 = null,
    /// County name, when the request names a county.
    county: ?[]const u8 = null,
    /// Person name, for history_person.
    person: ?[]const u8 = null,
    /// Claim text, for verify_claim.
    claim: ?[]const u8 = null,
    /// Watch keywords, for watch_story.
    watch_keywords: ?[]const u8 = null,
    /// Plain-words explanation of what was understood (or why not).
    message: []const u8,
};

const TopicWord = struct { word: []const u8, topic: []const u8 };

const topic_words = [_]TopicWord{
    .{ .word = "fuel", .topic = "energy" },
    .{ .word = "petrol", .topic = "energy" },
    .{ .word = "gasoline", .topic = "energy" },
    .{ .word = "electricity", .topic = "energy" },
    .{ .word = "power", .topic = "energy" },
    .{ .word = "energy", .topic = "energy" },
    .{ .word = "politics", .topic = "politics" },
    .{ .word = "election", .topic = "politics" },
    .{ .word = "president", .topic = "politics" },
    .{ .word = "government", .topic = "politics" },
    .{ .word = "senate", .topic = "politics" },
    .{ .word = "economy", .topic = "economy" },
    .{ .word = "money", .topic = "economy" },
    .{ .word = "price", .topic = "economy" },
    .{ .word = "prices", .topic = "economy" },
    .{ .word = "market", .topic = "economy" },
    .{ .word = "business", .topic = "economy" },
    .{ .word = "tax", .topic = "economy" },
    .{ .word = "sports", .topic = "sports" },
    .{ .word = "football", .topic = "sports" },
    .{ .word = "soccer", .topic = "sports" },
    .{ .word = "county meet", .topic = "sports" },
    .{ .word = "health", .topic = "health" },
    .{ .word = "hospital", .topic = "health" },
    .{ .word = "disease", .topic = "health" },
    .{ .word = "clinic", .topic = "health" },
    .{ .word = "education", .topic = "education" },
    .{ .word = "school", .topic = "education" },
    .{ .word = "university", .topic = "education" },
    .{ .word = "crime", .topic = "crime" },
    .{ .word = "police", .topic = "crime" },
    .{ .word = "robbery", .topic = "crime" },
    .{ .word = "weather", .topic = "weather" },
    .{ .word = "rain", .topic = "weather" },
    .{ .word = "flood", .topic = "weather" },
};

fn findSource(alloc: std.mem.Allocator, lower: []const u8) ?[]const u8 {
    for (sources.sources) |s| {
        const lower_id = std.ascii.allocLowerString(alloc, s.id) catch continue;
        defer alloc.free(lower_id);
        const lower_name = std.ascii.allocLowerString(alloc, s.name) catch continue;
        defer alloc.free(lower_name);
        if (std.mem.indexOf(u8, lower, lower_id) != null) return s.id;
        if (std.mem.indexOf(u8, lower, lower_name) != null) return s.id;
    }
    return null;
}

fn findCounty(alloc: std.mem.Allocator, lower: []const u8) ?[]const u8 {
    for (geo.county_capitals) |c| {
        const lower_name = std.ascii.allocLowerString(alloc, c.county) catch continue;
        defer alloc.free(lower_name);
        if (std.mem.indexOf(u8, lower, lower_name) != null) return c.county;
    }
    return null;
}

fn findTopic(lower: []const u8) ?[]const u8 {
    for (topic_words) |t| {
        if (std.mem.indexOf(u8, lower, t.word) != null) return t.topic;
    }
    return null;
}

/// Strip any of the given leading phrases (matched against the
/// lowercased text) and trim the result, slicing the ORIGINAL text
/// so the returned claim keeps the user's casing. Returns the
/// original when nothing matches.
fn stripPrefixes(original: []const u8, lower: []const u8, prefixes: []const []const u8) []const u8 {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, lower, p)) {
            return std.mem.trim(u8, original[p.len..], " \t?");
        }
    }
    return original;
}

/// Parse a natural-language request into a typed action. `request`
/// is the user's words as sent (not lowercased); matching is
/// case-insensitive. The returned strings borrow from `request` or
/// from static tables where noted.
pub fn parse(alloc: std.mem.Allocator, request: []const u8) !ParsedAction {
    const trimmed = std.mem.trim(u8, request, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .kind = .unknown, .message = "Empty request — tell me what to do, for example \"what is the latest from New Dawn?\" or \"is it true that fuel prices rose?\"" };
    }
    const lower = try std.ascii.allocLowerString(alloc, trimmed);
    var source_id = findSource(alloc, lower);
    // "facebook" is not a registry source — it is the separate
    // Facebook connector. Keep it as a sentinel so "monitor
    // facebook" can report the connector's status honestly.
    if (source_id == null and std.mem.indexOf(u8, lower, "facebook") != null) source_id = "facebook";
    const county = findCounty(alloc, lower);
    const topic = findTopic(lower);

    // Verify a claim: "verify ...", "is it true that ...", "fact check ...".
    if (std.mem.indexOf(u8, lower, "verify") != null or
        std.mem.indexOf(u8, lower, "is it true") != null or
        std.mem.indexOf(u8, lower, "is this true") != null or
        std.mem.indexOf(u8, lower, "fact check") != null or
        std.mem.indexOf(u8, lower, "check if") != null)
    {
        const claim = stripPrefixes(trimmed, lower, &.{
            "verify that ",
            "verify ",
            "is it true that ",
            "is this true ",
            "fact check: ",
            "fact check ",
            "check if ",
        });
        const claim_trimmed = std.mem.trim(u8, claim, " \t?");
        if (claim_trimmed.len == 0) {
            return .{ .kind = .unknown, .message = "You asked me to verify something but did not say what — add the claim, for example \"verify that fuel prices rose\"" };
        }
        return .{
            .kind = .verify_claim,
            .source_id = source_id,
            .topic = topic,
            .county = county,
            .claim = claim_trimmed,
            .message = "Checking the claim against the stored documents.",
        };
    }

    // Monitor an account: "monitor ..." or "watch <source>" / "watch <source> account".
    if (std.mem.indexOf(u8, lower, "monitor") != null) {
        return .{
            .kind = .monitor_account,
            .source_id = source_id,
            .topic = topic,
            .county = county,
            .message = "Checking the account's live status.",
        };
    }
    if (std.mem.indexOf(u8, lower, "watch") != null) {
        if (source_id != null or std.mem.indexOf(u8, lower, "account") != null or std.mem.indexOf(u8, lower, "facebook") != null) {
            return .{
                .kind = .monitor_account,
                .source_id = source_id,
                .topic = topic,
                .county = county,
                .message = "Checking the account's live status.",
            };
        }
        const keywords = stripPrefixes(trimmed, lower, &.{
            "watch for ",
            "watch the story ",
            "watch ",
            "keep an eye on ",
        });
        const kw = std.mem.trim(u8, keywords, " \t?");
        if (kw.len == 0) {
            return .{ .kind = .unknown, .message = "You asked me to watch something but did not say what — add the topic, for example \"watch for fuel shortages in Bong\"" };
        }
        return .{
            .kind = .watch_story,
            .topic = topic,
            .county = county,
            .watch_keywords = kw,
            .message = "Recording a watch for that story.",
        };
    }

    // Status of the system.
    if (std.mem.indexOf(u8, lower, "status") != null or
        std.mem.indexOf(u8, lower, "how is pulse") != null or
        std.mem.indexOf(u8, lower, "is pulse") != null)
    {
        return .{ .kind = .check_status, .message = "Checking Pulse's status." };
    }

    // What is happening (optionally in a county / on a topic).
    if (std.mem.indexOf(u8, lower, "what's happening") != null or
        std.mem.indexOf(u8, lower, "what is happening") != null or
        std.mem.indexOf(u8, lower, "what happened") != null or
        std.mem.indexOf(u8, lower, "latest news") != null or
        std.mem.indexOf(u8, lower, "news") != null)
    {
        return .{
            .kind = .whats_happening,
            .topic = topic,
            .county = county,
            .message = "Gathering what is happening.",
        };
    }

    // Latest from a source (or latest overall).
    if (std.mem.indexOf(u8, lower, "latest") != null or
        std.mem.indexOf(u8, lower, "newest") != null or
        std.mem.indexOf(u8, lower, "recent") != null or
        std.mem.indexOf(u8, lower, "what's new") != null)
    {
        return .{
            .kind = .check_source_latest,
            .source_id = source_id,
            .topic = topic,
            .county = county,
            .message = "Fetching the latest stories.",
        };
    }

    // History of a person or a topic.
    if (std.mem.indexOf(u8, lower, "history") != null or
        std.mem.indexOf(u8, lower, "who is") != null or
        std.mem.indexOf(u8, lower, "tell me about") != null or
        std.mem.indexOf(u8, lower, "about ") != null)
    {
        if (topic != null and std.mem.indexOf(u8, lower, "who is") == null) {
            return .{
                .kind = .whats_happening,
                .topic = topic,
                .county = county,
                .message = "Gathering the history of that topic.",
            };
        }
        const person = stripPrefixes(trimmed, lower, &.{
            "history of ",
            "history ",
            "who is ",
            "tell me about ",
            "about ",
        });
        const name = std.mem.trim(u8, person, " \t?");
        if (name.len == 0 or name.len > 60) {
            return .{ .kind = .unknown, .message = "You asked about a person but did not name one — add the name, for example \"who is Joseph Boakai?\"" };
        }
        return .{
            .kind = .history_person,
            .person = name,
            .county = county,
            .message = "Searching the store for that person.",
        };
    }

    return .{
        .kind = .unknown,
        .source_id = source_id,
        .topic = topic,
        .county = county,
        .message = "I could not tell what you want me to do. Try \"what is the latest from New Dawn?\", \"is it true that fuel prices rose?\", \"what is happening in Bong?\", or \"watch for fuel shortages in Bong\".",
    };
}

test "parse latest from a source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try parse(alloc, "What is the latest from New Dawn?");
    try std.testing.expectEqual(ActionKind.check_source_latest, p.kind);
    try std.testing.expectEqualStrings("new-dawn", p.source_id.?);
    const p2 = try parse(alloc, "show me the newest stories");
    try std.testing.expectEqual(ActionKind.check_source_latest, p2.kind);
    try std.testing.expect(p2.source_id == null);
}

test "parse verify claim with county and topic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try parse(alloc, "Is it true that fuel prices rose in Bong?");
    try std.testing.expectEqual(ActionKind.verify_claim, p.kind);
    try std.testing.expectEqualStrings("fuel prices rose in Bong", p.claim.?);
    try std.testing.expectEqualStrings("energy", p.topic.?);
    try std.testing.expectEqualStrings("Bong", p.county.?);
}

test "parse monitor vs watch story" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try parse(alloc, "Monitor the FrontPage Africa account");
    try std.testing.expectEqual(ActionKind.monitor_account, p.kind);
    try std.testing.expectEqualStrings("frontpage-africa", p.source_id.?);
    const p2 = try parse(alloc, "Watch for fuel shortages in Bong");
    try std.testing.expectEqual(ActionKind.watch_story, p2.kind);
    try std.testing.expectEqualStrings("fuel shortages in Bong", p2.watch_keywords.?);
    try std.testing.expectEqualStrings("Bong", p2.county.?);
    const p3 = try parse(alloc, "Watch New Dawn");
    try std.testing.expectEqual(ActionKind.monitor_account, p3.kind);
}

test "parse whats happening, status, history person, unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try parse(alloc, "What is happening in Bong?");
    try std.testing.expectEqual(ActionKind.whats_happening, p.kind);
    try std.testing.expectEqualStrings("Bong", p.county.?);
    const p2 = try parse(alloc, "What is the status?");
    try std.testing.expectEqual(ActionKind.check_status, p2.kind);
    const p3 = try parse(alloc, "Who is Joseph Boakai?");
    try std.testing.expectEqual(ActionKind.history_person, p3.kind);
    try std.testing.expectEqualStrings("Joseph Boakai", p3.person.?);
    const p4 = try parse(alloc, "hello there");
    try std.testing.expectEqual(ActionKind.unknown, p4.kind);
    const p5 = try parse(alloc, "");
    try std.testing.expectEqual(ActionKind.unknown, p5.kind);
    const p6 = try parse(alloc, "history of fuel prices");
    try std.testing.expectEqual(ActionKind.whats_happening, p6.kind);
    try std.testing.expectEqualStrings("energy", p6.topic.?);
}

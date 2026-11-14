//! Trust & Intelligence Engine, Phase 3: claim extraction.
//!
//! A claim is one checkable statement pulled from a document: the
//! title (always — headlines state the claim) and the lead sentence
//! of the text when it says something the title does not. Extraction
//! is extractive only: claim text is copied from the document, never
//! generated, paraphrased, or invented. A claim carries its source,
//! publication time and URL so the evidence record can cite it.
//!
//! What extraction is NOT: it does not judge truth. Judgement lives
//! in corroboration.zig, and it never issues verdicts — see that
//! module's doc comment for the status rules and the "False" gap.

const std = @import("std");
const types = @import("../../common/types.zig");
const knowledge = @import("../../storage/knowledge.zig");

/// Maximum claim text length. Longer titles/leads are truncated at
/// the cap (the full text stays on the document, cited by URL).
pub const max_claim_len: usize = 280;

/// One extracted claim.
pub const Claim = struct {
    text: []const u8,
    /// "title" (the headline) or "lead" (first sentence of the text).
    kind: []const u8,
    source_id: []const u8,
    source_name: []const u8,
    published_at: i64,
    url: []const u8,
};

/// First sentence of `text`: up to and including the first `.`, `!`
/// or `?` that is followed by a space or the end of the text. No
/// sentence terminator → the whole text. The result is trimmed and
/// capped at `max_claim_len`.
pub fn firstSentence(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    var end: usize = trimmed.len;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '.' or c == '!' or c == '?') {
            if (i + 1 >= trimmed.len or trimmed[i + 1] == ' ' or trimmed[i + 1] == '\n' or trimmed[i + 1] == '\t') {
                end = i + 1;
                break;
            }
        }
    }
    const s = trimmed[0..end];
    if (s.len <= max_claim_len) return try alloc.dupe(u8, s);
    return try alloc.dupe(u8, s[0..max_claim_len]);
}

/// Extract the claims of one document: the title, plus the lead
/// sentence when it is non-empty, at least 10 chars, and not just the
/// title again (case-insensitive). At most two claims per document.
pub fn extractClaims(alloc: std.mem.Allocator, doc: types.Document) ![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    const title = std.mem.trim(u8, doc.title, " \t\n\r");
    if (title.len > 0) {
        const t = if (title.len <= max_claim_len) try alloc.dupe(u8, title) else try alloc.dupe(u8, title[0..max_claim_len]);
        try out.append(alloc, .{
            .text = t,
            .kind = "title",
            .source_id = doc.source_id,
            .source_name = doc.source_name,
            .published_at = knowledge.docTs(doc),
            .url = doc.url,
        });
    }
    if (doc.text.len > 0) {
        const lead = try firstSentence(alloc, doc.text);
        const lower_lead = try std.ascii.allocLowerString(alloc, lead);
        defer alloc.free(lower_lead);
        const lower_title = try std.ascii.allocLowerString(alloc, title);
        defer alloc.free(lower_title);
        if (lead.len >= 10 and !std.mem.eql(u8, lower_lead, lower_title)) {
            try out.append(alloc, .{
                .text = lead,
                .kind = "lead",
                .source_id = doc.source_id,
                .source_name = doc.source_name,
                .published_at = knowledge.docTs(doc),
                .url = doc.url,
            });
        } else {
            alloc.free(lead);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Extract the claims of one event document (same rule, over the
/// EventDoc view the intelligence layer uses). The event doc's text
/// is capped at 4000 chars by the store, which is fine for a lead.
pub fn extractClaimsFromEventDoc(alloc: std.mem.Allocator, doc: knowledge.EventDoc) ![]Claim {
    const full = types.Document{
        .id = doc.id,
        .source_id = doc.source_id,
        .source_name = doc.source_name,
        .source_url = "",
        .title = doc.title,
        .url = "",
        .text = doc.text,
        .published_at = doc.published_at,
        .fetched_at = doc.published_at,
        .reliability = 0,
        .topics = &.{},
        .content_hash = doc.id,
    };
    return extractClaims(alloc, full);
}

test "firstSentence stops at the first terminator, caps long text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("Fuel stations report long queues.", try firstSentence(alloc, "Fuel stations report long queues. Prices rose again today."));
    try std.testing.expectEqualStrings("What happened?", try firstSentence(alloc, "What happened? Nobody knows yet."));
    try std.testing.expectEqualStrings("No terminator here", try firstSentence(alloc, "No terminator here"));
    try std.testing.expectEqualStrings("Trimmed.", try firstSentence(alloc, "  Trimmed.  "));
    // Decimal points do not end a sentence (digit follows the dot).
    try std.testing.expectEqualStrings("Prices rose 4.2 percent today.", try firstSentence(alloc, "Prices rose 4.2 percent today. Markets reacted."));
    var long_buf: std.ArrayList(u8) = .empty;
    for (0..100) |_| try long_buf.appendSlice(alloc, "word ");
    const long = try firstSentence(alloc, long_buf.items);
    try std.testing.expectEqual(@as(usize, max_claim_len), long.len);
}

test "extractClaims: title always, lead only when it adds something" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const doc = types.Document{
        .id = "d1",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://example.com/1",
        .text = "Fuel stations in Monrovia report long queues. Prices rose again today.",
        .published_at = 1795000000,
        .fetched_at = 1795000100,
        .reliability = 0.70,
        .topics = &.{},
        .content_hash = "d1",
    };
    const claims = try extractClaims(alloc, doc);
    try std.testing.expectEqual(@as(usize, 2), claims.len);
    try std.testing.expectEqualStrings("title", claims[0].kind);
    try std.testing.expectEqualStrings("Fuel shortage hits Monrovia", claims[0].text);
    try std.testing.expectEqualStrings("lead", claims[1].kind);
    try std.testing.expectEqualStrings("Fuel stations in Monrovia report long queues.", claims[1].text);
    try std.testing.expectEqualStrings("new-dawn", claims[1].source_id);
    try std.testing.expectEqual(@as(i64, 1795000000), claims[1].published_at);
    // Text that only repeats the title yields one claim.
    var doc2 = doc;
    doc2.text = "Fuel shortage hits Monrovia";
    const one = try extractClaims(alloc, doc2);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    // Empty text yields one claim (the title).
    var doc3 = doc;
    doc3.text = "";
    const one2 = try extractClaims(alloc, doc3);
    try std.testing.expectEqual(@as(usize, 1), one2.len);
    // Empty title + text yields none.
    var doc4 = doc;
    doc4.title = "";
    doc4.text = "";
    try std.testing.expectEqual(@as(usize, 0), (try extractClaims(alloc, doc4)).len);
}

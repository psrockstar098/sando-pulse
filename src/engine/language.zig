//! Language identification (Roadmap 3.3): a small stopword-count
//! classifier over the text. The corpus is Liberian news, which is
//! written in English (including Liberian English / Koloqua written in
//! English orthography) with occasional French wire copy, so the
//! classifier distinguishes English ("en") from French ("fr") and
//! defaults to "en" when neither side wins. Koloqua has no distinct
//! stopword list that separates it from English orthography, so it is
//! honestly reported as "en" — never guessed as a separate code.
//!
//! This is a heuristic, not a model: the returned code is a best-effort
//! label for filtering, and the raw text is always preserved.

const std = @import("std");

const english_stopwords = [_][]const u8{
    "the", "and", "of", "to", "in", "for", "is", "on", "with", "by",
    "a", "an", "are", "was", "were", "has", "have", "had", "it", "its",
    "this", "that", "from", "at", "as", "be", "or", "not", "but", "they",
    "their", "he", "she", "we", "you", "will", "would", "can", "said",
};

const french_stopwords = [_][]const u8{
    "le", "la", "les", "de", "des", "et", "du", "un", "une", "dans",
    "pour", "sur", "au", "aux", "il", "elle", "est", "ce", "qui", "que",
    "pas", "plus", "avec", "par", "nous", "vous", "ont", "être", "son",
    "sa", "ses", "leur", "leurs", "mais", "ou", "comme", "tout", "tous",
};

fn countHits(text: []const u8, words: []const []const u8) usize {
    var hits: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}<>/-_");
    while (it.next()) |tok| {
        if (tok.len > 32) continue;
        var buf: [32]u8 = undefined;
        const w = std.ascii.lowerString(buf[0..tok.len], tok);
        for (words) |sw| {
            if (std.mem.eql(u8, w, sw)) {
                hits += 1;
                break;
            }
        }
    }
    return hits;
}

/// Identify the language of `text`: "en" or "fr". Defaults to "en"
/// (the corpus language) when the evidence is tied or absent.
pub fn identify(text: []const u8) []const u8 {
    const en = countHits(text, &english_stopwords);
    const fr = countHits(text, &french_stopwords);
    if (fr > en and fr >= 3) return "fr";
    return "en";
}

test "identify: English news text is en" {
    try std.testing.expectEqualStrings("en", identify("The president said the government will build new roads in the county and the people are happy with the decision."));
}

test "identify: French wire copy is fr" {
    try std.testing.expectEqualStrings("fr", identify("Le président a déclaré que le gouvernement va construire de nouvelles routes dans le pays et que les gens sont contents de la décision prise."));
}

test "identify: short or empty text defaults to en" {
    try std.testing.expectEqualStrings("en", identify("Monrovia"));
    try std.testing.expectEqualStrings("en", identify(""));
}

test "identify: Koloqua in English orthography is honestly en" {
    // No distinct stopword list separates Koloqua from English here;
    // the classifier must not invent a code it cannot support.
    try std.testing.expectEqualStrings("en", identify("The man go market yesterday and he buy plenty food for the family."));
}

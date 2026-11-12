//! Document validation (Roadmap 3.3): every document — RSS-normalized
//! or manually ingested — must pass these checks before it is stored.
//! A document that fails is dropped and counted as an ingest error,
//! never stored half-valid. The checks are structural only (required
//! fields, URL shape, size bounds); they never judge truth — that is
//! the quality layer's job (Roadmap 4.6).

const std = @import("std");
const types = @import("../common/types.zig");

pub const ValidationError = error{
    EmptyTitle,
    TitleTooLong,
    EmptyUrl,
    BadUrl,
    EmptyText,
    TextTooLong,
    EmptySource,
};

pub const max_title_len = 500;
pub const max_text_len = 200_000;

/// Validate a normalized document. Returns the first failure.
pub fn validate(doc: types.Document) ValidationError!void {
    const title = std.mem.trim(u8, doc.title, " \t\n\r");
    if (title.len == 0) return error.EmptyTitle;
    if (title.len > max_title_len) return error.TitleTooLong;
    const url = std.mem.trim(u8, doc.url, " \t\n\r");
    if (url.len == 0) return error.EmptyUrl;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.BadUrl;
    }
    const text = std.mem.trim(u8, doc.text, " \t\n\r");
    if (text.len == 0) return error.EmptyText;
    if (text.len > max_text_len) return error.TextTooLong;
    if (doc.source_id.len == 0) return error.EmptySource;
}

test "validate: accepts a well-formed document" {
    const doc = types.Document{
        .id = "x",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://thenewdawnliberia.com/fuel-shortage",
        .text = "Fuel stations report long queues.",
        .published_at = null,
        .fetched_at = 1700000000,
        .reliability = 0.70,
        .topics = &.{},
        .content_hash = "x",
    };
    try validate(doc);
}

test "validate: rejects empty title, bad URL, empty text" {
    var base = types.Document{
        .id = "x",
        .source_id = "new-dawn",
        .source_name = "New Dawn",
        .source_url = "https://thenewdawnliberia.com/",
        .title = "Fuel shortage hits Monrovia",
        .url = "https://thenewdawnliberia.com/fuel-shortage",
        .text = "Fuel stations report long queues.",
        .published_at = null,
        .fetched_at = 1700000000,
        .reliability = 0.70,
        .topics = &.{},
        .content_hash = "x",
    };
    base.title = "   ";
    try std.testing.expectError(error.EmptyTitle, validate(base));
    base.title = "Fuel shortage hits Monrovia";
    base.url = "ftp://example.com/x";
    try std.testing.expectError(error.BadUrl, validate(base));
    base.url = "https://thenewdawnliberia.com/fuel-shortage";
    base.text = "";
    try std.testing.expectError(error.EmptyText, validate(base));
    base.text = "Fuel stations report long queues.";
    base.source_id = "";
    try std.testing.expectError(error.EmptySource, validate(base));
}

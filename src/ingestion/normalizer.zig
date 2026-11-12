//! Normalization: turn a raw RSS item into a Pulse Document.
//! Text is cleaned, never invented; topics come from entity extraction over
//! the real title + description.

const std = @import("std");
const types = @import("../common/types.zig");
const rss = @import("rss.zig");
const sources = @import("sources.zig");
const entities = @import("../engine/entities.zig");

pub fn normalize(
    alloc: std.mem.Allocator,
    source: sources.Source,
    item: rss.RawItem,
    fetched_at: i64,
) !types.Document {
    const title = try rss.cleanText(alloc, item.title);
    const text = try rss.cleanText(alloc, item.description);
    const combined = try std.mem.concat(alloc, u8, &.{ title, " ", text });
    const ent = try entities.extract(alloc, combined);
    const id = try types.contentHash(alloc, source.id, item.link, title);
    return .{
        .id = id,
        .source_id = source.id,
        .source_name = source.name,
        .source_url = source.home_url,
        .title = title,
        .url = item.link,
        .text = text,
        .published_at = item.pub_date,
        .fetched_at = fetched_at,
        .reliability = source.reliability,
        .topics = ent.topics,
        .content_hash = id,
    };
}

test "normalize builds a document with real content and topics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src = sources.find("new-dawn").?;
    const item = rss.RawItem{
        .title = "Fuel shortage hits Monrovia",
        .link = "https://thenewdawnliberia.com/fuel-shortage",
        .description = "<p>Fuel stations report long queues.</p>",
        .pub_date = 1794496800,
    };
    const doc = try normalize(alloc, src, item, 1794497000);
    try std.testing.expectEqualStrings("Fuel shortage hits Monrovia", doc.title);
    try std.testing.expectEqualStrings("Fuel stations report long queues.", doc.text);
    try std.testing.expectEqualStrings("new-dawn", doc.source_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), doc.reliability, 0.001);
    try std.testing.expectEqual(@as(?i64, 1794496800), doc.published_at);
    var saw_energy = false;
    for (doc.topics) |t| {
        if (std.mem.eql(u8, t, "energy")) saw_energy = true;
    }
    try std.testing.expect(saw_energy);
    try std.testing.expectEqual(@as(usize, 64), doc.id.len);
}

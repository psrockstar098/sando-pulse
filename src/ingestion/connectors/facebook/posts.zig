//! Post collection (Roadmap 3.2, design doc sections 2 and 9).
//!
//! collectPage fetches a registered page's posts through the Graph
//! API, following pagination (at most 5 pages per collect, 25 posts
//! each — a bound on how much one run pulls), normalizing each post
//! into a Pulse Document. Deduplication is by post_id: the
//! connector keeps a seen-set of post ids (process lifetime — the
//! document store's content hash is the durable dedup; a post
//! re-fetched after a restart is dropped by the store, never
//! duplicated). Posts with no message text are skipped: there is
//! nothing to index and nothing to cite.
//!
//! Documents are allocated from the caller's allocator (the
//! pipeline's per-run arena, same as RSS items); the stores dupe
//! what they keep.

const std = @import("std");
const types = @import("../../../common/types.zig");
const fb_types = @import("types.zig");
const auth = @import("auth.zig");
const client = @import("client.zig");
const normalizer = @import("normalizer.zig");

pub const max_pages_per_collect: u32 = 5;
pub const posts_per_page: u32 = 25;

/// Collect one registered page. `seen` maps post_id -> void and is
/// owned by the connector; new ids are duped into it. A fetch
/// failure ends the collect for this page (posts already collected
/// in this run are still returned); the caller records the failure
/// in the page state.
pub fn collectPage(
    alloc: std.mem.Allocator,
    /// Allocator that owns the connector's seen-set keys (long-lived);
    /// `alloc` owns the returned Documents (per-run arena).
    seen_alloc: std.mem.Allocator,
    io: std.Io,
    cfg: auth.AuthConfig,
    page: fb_types.PageEntry,
    seen: *std.StringHashMap(void),
    now: i64,
    environ: ?*const std.process.Environ.Map,
) ![]types.Document {
    var out: std.ArrayList(types.Document) = .empty;
    var after: ?[]const u8 = null;
    defer if (after) |a| alloc.free(a);
    var fetched_pages: u32 = 0;
    while (fetched_pages < max_pages_per_collect) : (fetched_pages += 1) {
        const url = try client.buildPostsUrl(alloc, cfg, page.page_id, posts_per_page, after);
        defer alloc.free(url);
        const body = client.fetchGraph(alloc, io, url, cfg, environ) catch |e| {
            if (out.items.len == 0) return e;
            break;
        };
        defer alloc.free(body);
        const page_data = try client.parsePostsPage(alloc, body);
        defer {
            for (page_data.posts) |p| {
                alloc.free(p.id);
                alloc.free(p.message);
                alloc.free(p.created_time);
                alloc.free(p.permalink_url);
            }
            alloc.free(page_data.posts);
            if (page_data.paging.next) |n| alloc.free(n);
            if (page_data.paging.after) |a| alloc.free(a);
            if (page_data.paging.before) |b| alloc.free(b);
        }
        for (page_data.posts) |raw| {
            if (raw.message.len == 0) continue;
            if (seen.contains(raw.id)) continue;
            const fb_post = normalizer.toFacebookPost(raw, page.page_id, now);
            const doc = try normalizer.toDocument(alloc, fb_post, page.name, page.priorityEnum());
            try seen.put(try seen_alloc.dupe(u8, raw.id), {});
            try out.append(alloc, doc);
        }
        // Next page: dupe the cursor BEFORE the defer above frees
        // page_data's copy at the end of this iteration.
        if (page_data.paging.after) |cursor| {
            if (after) |a| alloc.free(a);
            after = try alloc.dupe(u8, cursor);
        } else {
            break;
        }
    }
    return out.toOwnedSlice(alloc);
}

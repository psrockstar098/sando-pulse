//! Web search CLI: `pulse websearch "<query>"`.
//!
//! Asks the configured SearXNG instance for real web search and prints
//! the results (title, url, engine) — the same shape the GET
//! /v1/websearch endpoint returns. Results are printed exactly as
//! SearXNG reported them: no ranking, no verdict.
//!
//! Exit codes: 0 = results found; 2 = no results (a valid empty
//! answer — SearXNG answered, nothing matched); 1 = SearXNG
//! unavailable / bad response / bad query.
//!
//! Flags: --count N (1..20, default 10) --searxng-url <url>. The URL
//! defaults to PULSE_SEARXNG_URL from the environment; without it the
//! command refuses to run.

const std = @import("std");
const config = @import("../config/config.zig");
const searxng = @import("../search/searxng.zig");
const logging = @import("../common/logging.zig");

pub fn run(alloc: std.mem.Allocator, io: std.Io, cfg: config.Config, args: []const []const u8) u8 {
    const query = args[0];
    var count: usize = searxng.default_count;
    var base_url: ?[]const u8 = cfg.searxng_url;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--count") and i + 1 < args.len) {
            const n = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                logging.err("websearch: --count must be 1-20", &.{});
                return 2;
            };
            if (n < 1 or n > searxng.max_count) {
                logging.err("websearch: --count must be 1-20", &.{});
                return 2;
            }
            count = n;
            i += 1;
        } else if (std.mem.eql(u8, a, "--searxng-url") and i + 1 < args.len) {
            base_url = args[i + 1];
            i += 1;
        } else {
            logging.err("websearch: unknown flag (websearch \"<query>\" [--count N] [--searxng-url <url>])", &.{});
            return 2;
        }
    }

    const url = base_url orelse {
        logging.err("websearch: PULSE_SEARXNG_URL is not set — start SearXNG (docker compose --profile websearch up -d) and set it", &.{});
        return 1;
    };

    var client = searxng.Client{ .alloc = alloc, .io = io, .base_url = url };
    const res = client.search(alloc, query, count) catch |e| {
        switch (e) {
            error.InvalidQuery => logging.err("websearch: query must be 1-1000 chars", &.{}),
            error.Unavailable => logging.err("websearch: SearXNG did not answer — is it running?", &.{}),
            error.BadResponse => logging.err("websearch: SearXNG answered with an unusable response (is `json` in search.formats?)", &.{}),
            error.OutOfMemory => logging.err("websearch: out of memory", &.{}),
        }
        return 1;
    };
    defer searxng.freeResponse(alloc, res);

    if (res.results.len == 0) {
        std.debug.print("websearch: no results for \"{s}\" (took {d} ms)\n", .{ res.query, res.took_ms });
        return 2;
    }
    std.debug.print("websearch: {d} result(s) for \"{s}\" (took {d} ms)\n", .{ res.results.len, res.query, res.took_ms });
    for (res.results) |r| {
        std.debug.print("  - {s} [{s}] {s}\n", .{ r.title, r.engine, r.url });
    }
    if (res.unresponsive_engines.len > 0) {
        std.debug.print("unresponsive engines:", .{});
        for (res.unresponsive_engines) |e| std.debug.print(" {s}", .{e});
        std.debug.print("\n", .{});
    }
    return 0;
}

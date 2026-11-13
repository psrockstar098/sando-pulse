//! Data connectors (Roadmap 3.2): the connector framework plus the
//! connectors Pulse can actually run, and honest stubs for the ones it
//! cannot — yet.
//!
//! HARD RULE: only authorized/approved/permitted access. A connector
//! that needs a credential or an approval reports `unavailable` with
//! the reason until the operator configures it. Pulse never scrapes a
//! site against its terms, never invents a credential, and never logs
//! a key. `check()` is the gate: `fetch()` is only ever called after
//! `check()` said `available`.
//!
//! Live connectors: RSS (the 10 registry sources), Website (explicit
//! allowlist only — PULSE_WEBSITE_ALLOWLIST, comma-separated hosts),
//! Government (configured public endpoint — PULSE_GOVERNMENT_URL),
//! OpenStreetMap (Nominatim, public, no key; 1 req/s usage policy),
//! Facebook (Graph API adapter — the full connector lives in
//! connectors/facebook/; the adapter gates on the token and fetches
//! Graph API URLs. Without a token it reports unavailable).
//! Stubs (interface + unavailable reason, no client code): Google
//! (approved Custom Search API), YouTube (Data API key), Reddit
//! (approved API client), X (approved API client).

const std = @import("std");
const fetchers = @import("fetchers.zig");
const rss = @import("rss.zig");
const fb_auth = @import("connectors/facebook/auth.zig");
const fb_client = @import("connectors/facebook/client.zig");

pub const Kind = enum {
    rss,
    website,
    government,
    osm,
    facebook,
    google,
    youtube,
    reddit,
    /// X (Twitter): stub only (Roadmap 7.7). Authorized-API access
    /// only; no credentials exist. Posts are only ever fetched
    /// through the approved API, never scraped.
    x,
};

pub const Availability = union(enum) {
    available,
    unavailable: []const u8,
};

pub const Connector = struct {
    kind: Kind,
    name: []const u8,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        check: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, environ: ?*const std.process.Environ.Map) Availability,
        fetch: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8,
    };

    pub fn check(self: Connector, alloc: std.mem.Allocator, environ: ?*const std.process.Environ.Map) Availability {
        return self.vtable.check(self.ptr, alloc, environ);
    }

    pub fn fetch(self: Connector, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        return self.vtable.fetch(self.ptr, alloc, io, url, environ);
    }
};

/// RSS connector: the 10 registry news sources. Always available;
/// transport is the proven CONNECT+TLS fetcher.
pub const RssConnector = struct {
    pub fn connector(self: *RssConnector) Connector {
        return .{
            .kind = .rss,
            .name = "RSS",
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn checkFn(_: *anyopaque, _: std.mem.Allocator, _: ?*const std.process.Environ.Map) Availability {
        return .available;
    }

    fn fetchFn(_: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        return fetchers.fetchFeed(alloc, io, url, environ);
    }
};

/// Website connector: permitted article extraction. A host is fetched
/// ONLY when it is on the operator's allowlist
/// (PULSE_WEBSITE_ALLOWLIST, comma-separated hostnames). With no
/// allowlist configured the connector is unavailable — that is the
/// permission model: nothing is fetched on speculation.
pub const WebsiteConnector = struct {
    pub fn connector(self: *WebsiteConnector) Connector {
        return .{
            .kind = .website,
            .name = "Website",
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn allowlistHas(environ: ?*const std.process.Environ.Map, host: []const u8) bool {
        const env = environ orelse return false;
        const list = env.get("PULSE_WEBSITE_ALLOWLIST") orelse return false;
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |h| {
            if (std.mem.eql(u8, std.mem.trim(u8, h, " "), host)) return true;
        }
        return false;
    }

    fn checkFn(_: *anyopaque, _: std.mem.Allocator, environ: ?*const std.process.Environ.Map) Availability {
        const env = environ orelse return .{ .unavailable = "no permitted hosts configured (PULSE_WEBSITE_ALLOWLIST)" };
        const list = env.get("PULSE_WEBSITE_ALLOWLIST") orelse return .{ .unavailable = "no permitted hosts configured (PULSE_WEBSITE_ALLOWLIST)" };
        if (std.mem.trim(u8, list, " ").len == 0) return .{ .unavailable = "no permitted hosts configured (PULSE_WEBSITE_ALLOWLIST)" };
        return .available;
    }

    fn fetchFn(_: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        const uri = std.Uri.parse(url) catch return error.BadUrl;
        const host = uri.host orelse return error.BadUrl;
        const host_str = switch (host) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
        if (!allowlistHas(environ, host_str)) return error.NotPermitted;
        const body = try fetchers.fetchFeed(alloc, io, url, environ);
        defer alloc.free(body);
        // Article extraction is tag-stripping + entity decoding (the
        // same cleaner RSS uses); no boilerplate removal is attempted.
        return rss.cleanText(alloc, body);
    }
};

/// Government connector: public records / statistics from a configured
/// endpoint (PULSE_GOVERNMENT_URL). Unavailable until the operator
/// configures a real public endpoint — no URL is guessed here.
pub const GovernmentConnector = struct {
    pub fn connector(self: *GovernmentConnector) Connector {
        return .{
            .kind = .government,
            .name = "Government",
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn checkFn(_: *anyopaque, _: std.mem.Allocator, environ: ?*const std.process.Environ.Map) Availability {
        const env = environ orelse return .{ .unavailable = "no government endpoint configured (PULSE_GOVERNMENT_URL)" };
        const url = env.get("PULSE_GOVERNMENT_URL") orelse return .{ .unavailable = "no government endpoint configured (PULSE_GOVERNMENT_URL)" };
        if (std.mem.trim(u8, url, " ").len == 0) return .{ .unavailable = "no government endpoint configured (PULSE_GOVERNMENT_URL)" };
        return .available;
    }

    fn fetchFn(_: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        return fetchers.fetchFeed(alloc, io, url, environ);
    }
};

/// A place returned by the OpenStreetMap connector.
pub const Place = struct {
    name: []const u8,
    lat: f64,
    lon: f64,
    kind: []const u8,
};

/// OpenStreetMap connector: Nominatim search, public, no key. Usage
/// policy is 1 request/second — callers must space calls (the seed job
/// sleeps between searches). The fetcher already sends the SandoPulse
/// user agent Nominatim asks for.
pub const OsmConnector = struct {
    pub fn connector(self: *OsmConnector) Connector {
        return .{
            .kind = .osm,
            .name = "OpenStreetMap",
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn checkFn(_: *anyopaque, _: std.mem.Allocator, _: ?*const std.process.Environ.Map) Availability {
        return .available;
    }

    fn fetchFn(_: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        return fetchers.fetchFeed(alloc, io, url, environ);
    }

    fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        const hex = "0123456789ABCDEF";
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try out.append(alloc, c);
            } else {
                try out.append(alloc, '%');
                try out.append(alloc, hex[c >> 4]);
                try out.append(alloc, hex[c & 0x0F]);
            }
        }
        return out.toOwnedSlice(alloc);
    }

    const NominatimHit = struct {
        display_name: []const u8 = "",
        lat: []const u8 = "0",
        lon: []const u8 = "0",
        class: []const u8 = "",
        type: []const u8 = "",
        addresstype: []const u8 = "",
    };

    /// Search Nominatim for `query` (e.g. "hospital in Monrovia,
    /// Liberia"), restricted to Liberia. Returns owned places.
    pub fn searchPlaces(
        alloc: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        environ: ?*const std.process.Environ.Map,
    ) ![]Place {
        const encoded = try urlEncode(alloc, query);
        defer alloc.free(encoded);
        const url = try std.fmt.allocPrint(alloc, "https://nominatim.openstreetmap.org/search?q={s}&format=json&limit=5&countrycodes=lr", .{encoded});
        defer alloc.free(url);
        const body = try fetchers.fetchFeed(alloc, io, url, environ);
        defer alloc.free(body);
        // Leaky parse into a local arena: the hit strings are only needed
        // while building the returned Place list (name/kind are duped).
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const hits = try std.json.parseFromSliceLeaky([]NominatimHit, arena.allocator(), body, .{ .ignore_unknown_fields = true });
        var out: std.ArrayList(Place) = .empty;
        for (hits) |h| {
            const lat = std.fmt.parseFloat(f64, h.lat) catch continue;
            const lon = std.fmt.parseFloat(f64, h.lon) catch continue;
            // Name is the first component of the display name.
            const comma = std.mem.indexOfScalar(u8, h.display_name, ',') orelse h.display_name.len;
            const name = std.mem.trim(u8, h.display_name[0..comma], " ");
            if (name.len == 0) continue;
            const kind = if (h.addresstype.len > 0) h.addresstype else if (h.type.len > 0) h.type else h.class;
            try out.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .lat = lat,
                .lon = lon,
                .kind = try alloc.dupe(u8, kind),
            });
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Stub connector: the interface exists, the client does not. check()
/// always reports unavailable with the reason + the credential the
/// operator would need; fetch() always fails. No scraping is ever
/// attempted through a stub.
pub const StubConnector = struct {
    kind: Kind,
    name: []const u8,
    reason: []const u8,

    pub fn connector(self: *StubConnector) Connector {
        return .{
            .kind = self.kind,
            .name = self.name,
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn checkFn(ptr: *anyopaque, _: std.mem.Allocator, _: ?*const std.process.Environ.Map) Availability {
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        return .{ .unavailable = self.reason };
    }

    fn fetchFn(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: ?*const std.process.Environ.Map) anyerror![]u8 {
        return error.Unavailable;
    }
};

// Stateless singletons (the pipeline and seed jobs are single-threaded).
var rss_state = RssConnector{};
var website_state = WebsiteConnector{};
var government_state = GovernmentConnector{};
var osm_state = OsmConnector{};
/// Facebook adapter: the framework-level connector for the Graph
/// API. The full connector (registry, collect, webhooks, scheduler)
/// lives in connectors/facebook/; this adapter is the transport
/// face: check() gates on the access token, fetch() GETs a Graph
/// API URL with the token appended. Without a token it reports
/// unavailable — the same gate as the full connector's validate(),
/// minus the registry check (the adapter has no io handle to read
/// the registry file).
pub const FacebookAdapter = struct {
    pub fn connector(self: *FacebookAdapter) Connector {
        return .{
            .kind = .facebook,
            .name = "Facebook",
            .ptr = self,
            .vtable = &.{
                .check = checkFn,
                .fetch = fetchFn,
            },
        };
    }

    fn checkFn(_: *anyopaque, _: std.mem.Allocator, environ: ?*const std.process.Environ.Map) Availability {
        const cfg = fb_auth.AuthConfig.load(environ);
        if (!cfg.hasToken()) {
            return .{ .unavailable = "no Facebook access token configured (PULSE_FACEBOOK_ACCESS_TOKEN)" };
        }
        return .available;
    }

    fn fetchFn(_: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        const cfg = fb_auth.AuthConfig.load(environ);
        return fb_client.fetchGraph(alloc, io, url, cfg, environ);
    }
};

var facebook_state = FacebookAdapter{};
var google_state = StubConnector{
    .kind = .google,
    .name = "Google",
    .reason = "not implemented: needs an approved Custom Search API key (GOOGLE_API_KEY + GOOGLE_CX); search results are never scraped",
};
var youtube_state = StubConnector{
    .kind = .youtube,
    .name = "YouTube",
    .reason = "not implemented: needs a YouTube Data API key (YOUTUBE_API_KEY); transcripts only with authorization",
};
var reddit_state = StubConnector{
    .kind = .reddit,
    .name = "Reddit",
    .reason = "not implemented: needs an approved Reddit API client (REDDIT_CLIENT_ID + REDDIT_CLIENT_SECRET); discussions are only ever fetched through the approved API",
};
var x_state = StubConnector{
    .kind = .x,
    .name = "X",
    .reason = "not implemented: needs an approved X API client (X_API_KEY + X_API_SECRET, or a bearer token); posts are only ever fetched through the approved API, never scraped",
};

pub fn rssConnector() Connector {
    return rss_state.connector();
}

pub fn websiteConnector() Connector {
    return website_state.connector();
}

pub fn governmentConnector() Connector {
    return government_state.connector();
}

pub fn osmConnector() Connector {
    return osm_state.connector();
}

pub fn facebookConnector() Connector {
    return facebook_state.connector();
}

pub fn googleConnector() Connector {
    return google_state.connector();
}

pub fn youtubeConnector() Connector {
    return youtube_state.connector();
}

pub fn redditConnector() Connector {
    return reddit_state.connector();
}

pub fn xConnector() Connector {
    return x_state.connector();
}

/// All nine connectors in spec order, for status reporting.
pub fn allConnectors() [9]Connector {
    return .{
        rssConnector(),
        websiteConnector(),
        governmentConnector(),
        osmConnector(),
        facebookConnector(),
        googleConnector(),
        youtubeConnector(),
        redditConnector(),
        xConnector(),
    };
}

test "rss connector is available; stubs are unavailable with reasons" {
    const alloc = std.testing.allocator;
    const c = rssConnector();
    try std.testing.expect(c.check(alloc, null) == .available);
    for ([_]Connector{ facebookConnector(), googleConnector(), youtubeConnector(), redditConnector(), xConnector() }) |s| {
        const av = s.check(alloc, null);
        try std.testing.expect(av == .unavailable);
        try std.testing.expect(av.unavailable.len > 20);
        try std.testing.expectError(error.Unavailable, s.fetch(alloc, undefined, "https://example.com/", null));
    }
}

test "website connector needs an allowlist; government needs an endpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expect(websiteConnector().check(alloc, null) == .unavailable);
    try std.testing.expect(governmentConnector().check(alloc, null) == .unavailable);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PULSE_WEBSITE_ALLOWLIST", "example.com, www.example.com");
    try std.testing.expect(websiteConnector().check(alloc, &env) == .available);
    try env.put("PULSE_GOVERNMENT_URL", "https://example.com/data.json");
    try std.testing.expect(governmentConnector().check(alloc, &env) == .available);
    // A host off the allowlist is refused without any network call.
    try std.testing.expectError(error.NotPermitted, websiteConnector().fetch(alloc, undefined, "https://not-allowed.example/x", &env));
}

test "osm connector: live Nominatim search (gated on PULSE_TEST_OSM=1)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Live leg reads /proc/self/environ directly (same pattern as the
    // Postgres live tests); skip unless the operator opts in.
    const flag = (try @import("../storage/postgres.zig").getTestEnvVar(alloc, io, "PULSE_TEST_OSM")) orelse {
        std.debug.print("skip: PULSE_TEST_OSM=1 not set\n", .{});
        return;
    };
    defer alloc.free(flag);
    if (!std.mem.eql(u8, flag, "1")) {
        std.debug.print("skip: PULSE_TEST_OSM=1 not set\n", .{});
        return;
    }
    // The fetcher needs the proxy variables from the real process
    // environment (direct connects fail from this VM); rebuild the map
    // from /proc/self/environ.
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    {
        const proc_dir = std.Io.Dir.openDirAbsolute(io, "/proc/self", .{}) catch {
            return;
        };
        defer proc_dir.close(io);
        var file = proc_dir.openFile(io, "environ", .{}) catch {
            return;
        };
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var reader = file.reader(io, &rbuf);
        const bytes = reader.interface.readAllocShort(alloc, 1 << 20) catch return;
        defer alloc.free(bytes);
        var it = std.mem.splitScalar(u8, bytes, 0);
        while (it.next()) |entry| {
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                env_map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
            }
        }
    }
    const places = try OsmConnector.searchPlaces(alloc, io, "Monrovia, Liberia", &env_map);
    defer {
        for (places) |p| {
            alloc.free(p.name);
            alloc.free(p.kind);
        }
        alloc.free(places);
    }
    try std.testing.expect(places.len >= 1);
    try std.testing.expectEqualStrings("Monrovia", places[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 6.3204), places[0].lat, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, -10.8060), places[0].lon, 0.01);
}

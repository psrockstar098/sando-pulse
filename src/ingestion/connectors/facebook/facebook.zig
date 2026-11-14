//! Facebook connector (Roadmap 3.2, design doc
//! ~/workspace/sando-pulse-facebook-connector.md).
//!
//! Facebook is ONE source among many, behind the shared connector
//! interface: the design doc's `SourceConnector` (collect +
//! validate) is implemented here, and `connector()` adapts it to
//! the tree's existing `Connector` (check + fetch) — check wraps
//! validate's token gate, fetch wraps the Graph API GET. The full
//! validate (token + registry) lives on this struct; the framework
//! adapter's check() can only see the token, because it has no
//! io handle to read the registry file — the status route reports
//! the full reason.
//!
//! Layout follows the design doc (src/ingestion/connectors/
//! facebook/): client, auth, pages, posts, webhooks, pagination,
//! normalizer, scheduler, types — plus notifications.zig (the
//! persistent webhook handoff between the server and worker
//! processes) and this file as the module root.
//!
//! NO credentials exist yet: with no token the connector reports
//! unavailable with the exact unblocking step, collect() returns
//! no documents, and no request is ever made to Meta. Nothing is
//! scraped; Graph API + authorized access only.

const std = @import("std");
const types = @import("../../../common/types.zig");
const logging = @import("../../../common/logging.zig");
const connectors = @import("../../connectors.zig");
const fb_types = @import("types.zig");
const auth = @import("auth.zig");
const pages = @import("pages.zig");
const posts = @import("posts.zig");
const webhooks = @import("webhooks.zig");
const scheduler = @import("scheduler.zig");
const notifications = @import("notifications.zig");

pub const FacebookConnector = struct {
    alloc: std.mem.Allocator,
    auth_cfg: auth.AuthConfig,
    registry: []fb_types.PageEntry = &.{},
    /// page_id (owned dupe) -> poll state.
    states: std.StringHashMap(scheduler.PageState),
    /// post_id (owned dupe) -> void; process-lifetime dedup.
    seen: std.StringHashMap(void),
    /// Persistent webhook notification handoff (server -> worker).
    /// Null in unit tests that only exercise collect/validate.
    notification_store: ?notifications.NotificationStore = null,
    pages_polled_total: usize = 0,
    pages_failed_total: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        environ: ?*const std.process.Environ.Map,
        notification_store: ?notifications.NotificationStore,
    ) !FacebookConnector {
        var self = FacebookConnector{
            .alloc = alloc,
            .auth_cfg = auth.AuthConfig.load(environ),
            .notification_store = notification_store,
            .states = std.StringHashMap(scheduler.PageState).init(alloc),
            .seen = std.StringHashMap(void).init(alloc),
        };
        self.registry = try pages.loadRegistry(alloc, io, self.auth_cfg.registry_path);
        return self;
    }

    pub fn deinit(self: *FacebookConnector) void {
        for (self.registry) |p| {
            self.alloc.free(p.page_id);
            self.alloc.free(p.name);
            self.alloc.free(p.category);
            self.alloc.free(p.notes);
        }
        self.alloc.free(self.registry);
        var sit = self.states.keyIterator();
        while (sit.next()) |k| self.alloc.free(k.*);
        self.states.deinit();
        var seen_it = self.seen.keyIterator();
        while (seen_it.next()) |k| self.alloc.free(k.*);
        self.seen.deinit();
    }

    /// Re-read the registry file (worker calls this each run, so a
    /// registry edit takes effect without a restart). Old entries
    /// are freed; poll states are kept (keyed by owned page ids).
    pub fn reloadRegistry(self: *FacebookConnector, io: std.Io) !void {
        const fresh = try pages.loadRegistry(self.alloc, io, self.auth_cfg.registry_path);
        for (self.registry) |p| {
            self.alloc.free(p.page_id);
            self.alloc.free(p.name);
            self.alloc.free(p.category);
            self.alloc.free(p.notes);
        }
        self.alloc.free(self.registry);
        self.registry = fresh;
    }

    /// Design doc's validate(): null when usable, else the exact
    /// reason it is not.
    pub fn validate(self: *FacebookConnector) ?[]const u8 {
        return auth.validateReason(self.auth_cfg, pages.registeredCount(self.registry));
    }

    pub fn registeredPages(self: *FacebookConnector) usize {
        return pages.registeredCount(self.registry);
    }

    pub fn pendingPages(self: *FacebookConnector) usize {
        return self.registry.len - self.registeredPages();
    }

    /// Record a validated webhook notification: persist it for the
    /// worker and mark the page as having a missed notification
    /// (its next collect reconciles it).
    pub fn recordWebhook(self: *FacebookConnector, alloc: std.mem.Allocator, n: fb_types.WebhookNotification) !void {
        if (self.notification_store) |store| {
            try store.record(alloc, n);
        }
        const entry = self.states.getOrPut(n.page_id) catch return;
        if (!entry.found_existing) {
            // State keys use the CONNECTOR's allocator (self.alloc):
            // the passed alloc may be a per-request arena.
            entry.key_ptr.* = try self.alloc.dupe(u8, n.page_id);
            entry.value_ptr.* = .{ .page_id = entry.key_ptr.* };
        }
        entry.value_ptr.markMissed();
    }

    /// Drain pending notifications from the store, marking each
    /// page as needing reconciliation. Called at the start of
    /// collect(); a failure to read the store is logged, never
    /// fatal — the poll schedule still runs.
    fn drainNotifications(self: *FacebookConnector, alloc: std.mem.Allocator, now: i64) void {
        const store = self.notification_store orelse return;
        const pend = store.pending(alloc) catch |e| {
            logging.warn("facebook notification drain failed", &.{.{ .key = "error", .value = @errorName(e) }});
            return;
        };
        defer {
            for (pend) |n| {
                alloc.free(n.page_id);
                alloc.free(n.kind);
                alloc.free(n.object_id);
            }
            alloc.free(pend);
        }
        for (pend) |n| {
            const entry = self.states.getOrPut(n.page_id) catch continue;
            if (!entry.found_existing) {
                entry.key_ptr.* = self.alloc.dupe(u8, n.page_id) catch continue;
                entry.value_ptr.* = .{ .page_id = entry.key_ptr.* };
            }
            entry.value_ptr.markMissed();
        }
        _ = now;
    }

    pub const CollectOutcome = struct {
        docs: []types.Document,
        pages_polled: usize,
        pages_failed: usize,
    };

    /// Design doc's collect(): poll every due registered page
    /// (due by schedule, or by a pending webhook notification),
    /// normalize new posts into Documents. With no token or no
    /// registered pages this returns an empty outcome — it never
    /// contacts Meta unconfigured.
    pub fn collect(
        self: *FacebookConnector,
        alloc: std.mem.Allocator,
        io: std.Io,
        environ: ?*const std.process.Environ.Map,
        now: i64,
    ) !CollectOutcome {
        if (self.validate() != null) {
            return .{ .docs = &.{}, .pages_polled = 0, .pages_failed = 0 };
        }
        self.drainNotifications(alloc, now);
        var out: std.ArrayList(types.Document) = .empty;
        var polled: usize = 0;
        var failed: usize = 0;
        for (self.registry) |page| {
            if (!page.registered()) continue;
            const entry = try self.states.getOrPut(page.page_id);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.alloc.dupe(u8, page.page_id);
                entry.value_ptr.* = .{ .page_id = entry.key_ptr.* };
            }
            const st = entry.value_ptr;
            if (!st.isDue(now, self.auth_cfg.poll_interval_s) and !st.needsReconciliation(now, self.auth_cfg.poll_interval_s)) {
                continue;
            }
            st.markPolled(now);
            polled += 1;
            const docs = posts.collectPage(alloc, self.alloc, io, self.auth_cfg, page, &self.seen, now, environ) catch |e| {
                st.markFailure();
                failed += 1;
                logging.warn("facebook page collect failed", &.{
                    .{ .key = "page", .value = page.name },
                    .{ .key = "error", .value = @errorName(e) },
                });
                continue;
            };
            st.markSuccess(now);
            try out.appendSlice(alloc, docs);
            if (self.notification_store) |store| {
                store.markProcessed(alloc, page.page_id, now) catch {};
            }
        }
        self.pages_polled_total += polled;
        self.pages_failed_total += failed;
        return .{ .docs = try out.toOwnedSlice(alloc), .pages_polled = polled, .pages_failed = failed };
    }

    /// Adapt to the tree's shared Connector interface (check +
    /// fetch). check() gates on the token only — the adapter has no
    /// io handle to read the registry; the full validate() (token +
    /// registry) is what the pipeline and the status route use.
    pub fn connector(self: *FacebookConnector) connectors.Connector {
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

    fn checkFn(ptr: *anyopaque, _: std.mem.Allocator, _: ?*const std.process.Environ.Map) connectors.Availability {
        const self: *FacebookConnector = @ptrCast(@alignCast(ptr));
        if (!self.auth_cfg.hasToken()) {
            return .{ .unavailable = "no Facebook access token configured (PULSE_FACEBOOK_ACCESS_TOKEN)" };
        }
        return .available;
    }

    fn fetchFn(ptr: *anyopaque, alloc: std.mem.Allocator, io: std.Io, url: []const u8, environ: ?*const std.process.Environ.Map) anyerror![]u8 {
        const self: *FacebookConnector = @ptrCast(@alignCast(ptr));
        return @import("client.zig").fetchGraph(alloc, io, url, self.auth_cfg, environ);
    }

    /// Pending webhook notifications in the store (Phase 2 monitor:
    /// pages with a missed notification are due for reconciliation).
    pub fn pendingNotificationCount(self: *FacebookConnector, alloc: std.mem.Allocator) usize {
        const store = self.notification_store orelse return 0;
        const pend = store.pending(alloc) catch return 0;
        defer {
            for (pend) |n| {
                alloc.free(n.page_id);
                alloc.free(n.kind);
                alloc.free(n.object_id);
            }
            alloc.free(pend);
        }
        return pend.len;
    }

    /// Status JSON for GET /v1/connectors/facebook. Never includes
    /// a credential value.
    pub fn statusJson(self: *FacebookConnector, alloc: std.mem.Allocator) ![]u8 {
        const reason = self.validate();
        const pending: usize = self.pendingNotificationCount(alloc);
        return std.fmt.allocPrint(alloc,
            \\{{"connector":"facebook","available":{},"reason":{s},"registered_pages":{d},"pending_pages":{d},"pages_polled_total":{d},"pages_failed_total":{d},"notifications_pending":{d},"api_version":"{s}"}}
        , .{
            reason == null,
            if (reason) |r| try std.fmt.allocPrint(alloc, "\"{s}\"", .{r}) else "null",
            self.registeredPages(),
            self.pendingPages(),
            self.pages_polled_total,
            self.pages_failed_total,
            pending,
            self.auth_cfg.api_version,
        });
    }

    pub fn verifyWebhookSignature(self: *FacebookConnector, body: []const u8, header: ?[]const u8) bool {
        return webhooks.verifySignature(self.auth_cfg.app_secret, body, header);
    }

    pub fn handleWebhookVerification(self: *FacebookConnector, query: ?[]const u8) ?[]const u8 {
        return webhooks.handleVerification(query, self.auth_cfg.verify_token);
    }
};

test "connector validates unconfigured; collect returns empty without contacting Meta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    var fb = try FacebookConnector.init(alloc, io, &env, null);
    defer fb.deinit();
    try std.testing.expect(fb.validate() != null);
    try std.testing.expectEqual(@as(usize, 0), fb.registeredPages());
    const outcome = try fb.collect(alloc, io, &env, 1794477600);
    try std.testing.expectEqual(@as(usize, 0), outcome.docs.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.pages_polled);
    const c = fb.connector();
    try std.testing.expect(c.check(alloc, &env) == .unavailable);
    try std.testing.expectError(error.Unavailable, c.fetch(alloc, io, "https://graph.facebook.com/v21.0/1/posts", &env));
    // Status JSON never leaks a token (there is none) and reports why.
    const status = try fb.statusJson(alloc);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "PULSE_FACEBOOK_ACCESS_TOKEN") != null);
}

test "connector records a webhook notification and marks the page due" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PULSE_FACEBOOK_ACCESS_TOKEN", "tok");
    var mem = notifications.MemoryNotifications.init(alloc);
    const store = mem.store();
    var fb = try FacebookConnector.init(alloc, io, &env, store);
    defer fb.deinit();
    try store.record(alloc, .{ .page_id = "456", .kind = "feed", .object_id = "456_789", .received_at = 1794477600 });
    // A recorded notification makes the page due for reconciliation
    // even though the page is not in the registry (drain marks the
    // state; collect still only polls REGISTERED pages).
    fb.drainNotifications(alloc, 1794477700);
    const st = fb.states.get("456").?;
    try std.testing.expect(st.needsReconciliation(1794477700, 900));
    try std.testing.expectEqual(@as(u32, 1), st.missed_notifications);
}

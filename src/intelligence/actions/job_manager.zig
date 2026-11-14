//! Trust & Intelligence Engine, Phase 6: job + watch store for the
//! Live Intelligence Action Engine.
//!
//! Jobs are synchronous: the single-threaded server runs the action
//! at creation and the job is already `done` (or `failed`) when the
//! POST returns. Polling re-fetches the finished result — there is
//! no background worker, no WebSocket, no SSE (Pulse is REST only).
//! The store is in-memory and bounded: 100 jobs, 50 watches; the
//! oldest entry is evicted when the bound is reached, and everything
//! is forgotten on restart. A job id is `job-<n>`.
//!
//! Watches are recorded, not pushed: there is no push channel, so a
//! watch is a standing instruction the client re-checks (listed on
//! GET /v1/actions/watches and on /v1/alerts). The response says
//! that plainly.

const std = @import("std");
const query_parser = @import("query_parser.zig");

pub const max_jobs: usize = 100;
pub const max_watches: usize = 50;

pub const JobStatus = enum {
    queued,
    running,
    done,
    failed,

    pub fn toString(self: JobStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .done => "done",
            .failed => "failed",
        };
    }
};

pub const Job = struct {
    id: []const u8,
    request: []const u8,
    kind: query_parser.ActionKind,
    status: JobStatus,
    /// The finished result as a parsed JSON value (null until done).
    result: ?std.json.Value,
    /// Plain-words failure reason (null unless failed).
    err: ?[]const u8,
    created_at: i64,
    finished_at: ?i64,
};

pub const Watch = struct {
    id: []const u8,
    keywords: []const u8,
    county: ?[]const u8,
    created_at: i64,
};

pub const JobStore = struct {
    alloc: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    watches: std.ArrayList(Watch),
    next_job: u64,
    next_watch: u64,

    pub fn init(alloc: std.mem.Allocator) JobStore {
        return .{
            .alloc = alloc,
            .jobs = .empty,
            .watches = .empty,
            .next_job = 1,
            .next_watch = 1,
        };
    }

    /// Create a job in `queued` state. Evicts the oldest job when
    /// the store is at the bound.
    pub fn createJob(self: *JobStore, request: []const u8, kind: query_parser.ActionKind, now: i64) !*Job {
        if (self.jobs.items.len >= max_jobs) {
            _ = self.jobs.orderedRemove(0);
        }
        const id = try std.fmt.allocPrint(self.alloc, "job-{d}", .{self.next_job});
        self.next_job += 1;
        try self.jobs.append(self.alloc, .{
            .id = id,
            .request = try self.alloc.dupe(u8, request),
            .kind = kind,
            .status = .queued,
            .result = null,
            .err = null,
            .created_at = now,
            .finished_at = null,
        });
        return &self.jobs.items[self.jobs.items.len - 1];
    }

    pub fn getJob(self: *JobStore, id: []const u8) ?*Job {
        for (self.jobs.items) |*j| {
            if (std.mem.eql(u8, j.id, id)) return j;
        }
        return null;
    }

    /// Mark a job done with its result JSON (parsed into a Value so
    /// the poll response embeds it as an object, not a string).
    pub fn completeJob(self: *JobStore, job: *Job, result_json: []const u8, now: i64) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, result_json, .{}) catch {
            job.status = .failed;
            job.err = "Failed to parse the action result";
            job.finished_at = now;
            return;
        };
        job.result = parsed.value;
        job.status = .done;
        job.finished_at = now;
    }

    pub fn failJob(self: *JobStore, job: *Job, reason: []const u8, now: i64) void {
        _ = self;
        job.status = .failed;
        job.err = reason;
        job.finished_at = now;
    }

    /// Record a watch. Evicts the oldest watch at the bound.
    pub fn addWatch(self: *JobStore, keywords: []const u8, county: ?[]const u8, now: i64) !*Watch {
        if (self.watches.items.len >= max_watches) {
            _ = self.watches.orderedRemove(0);
        }
        const id = try std.fmt.allocPrint(self.alloc, "watch-{d}", .{self.next_watch});
        self.next_watch += 1;
        try self.watches.append(self.alloc, .{
            .id = id,
            .keywords = try self.alloc.dupe(u8, keywords),
            .county = if (county) |c| try self.alloc.dupe(u8, c) else null,
            .created_at = now,
        });
        return &self.watches.items[self.watches.items.len - 1];
    }

    pub fn listWatches(self: *JobStore) []const Watch {
        return self.watches.items;
    }
};

test "job store: create, complete, evict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = JobStore.init(alloc);
    const j = try store.createJob("what is the latest?", .check_source_latest, 1000);
    try std.testing.expectEqualStrings("job-1", j.id);
    try std.testing.expectEqual(JobStatus.queued, j.status);
    store.completeJob(j, "{\"latest\": 3}", 1001);
    try std.testing.expectEqual(JobStatus.done, j.status);
    try std.testing.expectEqual(@as(i64, 1001), j.finished_at.?);
    try std.testing.expect(store.getJob("job-1") != null);
    try std.testing.expect(store.getJob("job-99") == null);
    const j2 = try store.createJob("bad job", .unknown, 1002);
    store.failJob(j2, "could not understand the request", 1003);
    try std.testing.expectEqual(JobStatus.failed, j2.status);
    try std.testing.expectEqualStrings("could not understand the request", j2.err.?);
    // Fill to the bound and check the oldest is evicted.
    for (0..max_jobs) |_| {
        _ = try store.createJob("filler", .check_status, 1004);
    }
    try std.testing.expectEqual(@as(usize, max_jobs), store.jobs.items.len);
    try std.testing.expect(store.getJob("job-1") == null);
}

test "watch store: add and list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = JobStore.init(alloc);
    const w = try store.addWatch("fuel shortages", "Bong", 1000);
    try std.testing.expectEqualStrings("watch-1", w.id);
    try std.testing.expectEqual(@as(usize, 1), store.listWatches().len);
    try std.testing.expectEqualStrings("Bong", store.listWatches()[0].county.?);
}

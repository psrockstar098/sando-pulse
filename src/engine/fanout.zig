//! Parallel query fan-out (Roadmap 6.6).
//!
//! Runs independent backend tasks concurrently and merges the results.
//! Each task gets its own arena (page-allocator backed) so no allocator
//! is ever shared across threads. The caller waits until all tasks are
//! done or the deadline passes, renders the response from the completed
//! tasks, and only then joins the stragglers (post-response join) — a
//! slow backend never delays the response, and partial results are
//! labelled by the caller via `allDone()`.
//!
//! Thread safety contract: a task body must be thread-safe. The
//! Postgres knowledge store is (own connection + mutex); the memory
//! store is NOT — the caller enables parallel mode only when the
//! store is Postgres, and falls back to `runSequential` otherwise.

const std = @import("std");

pub const Task = struct {
    name: []const u8,
    /// Task body. `alloc` is the task's own arena allocator; anything
    /// it allocates lives until `joinAll` frees the arena, so the
    /// caller must render (or copy) results before joining.
    run: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void,
    ctx: *anyopaque,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    arena: ?*std.heap.ArenaAllocator = null,
};

/// Monotonic nanosecond clock (raw syscall — std.time.nanoTimestamp
/// does not exist in 0.17.1; same helper as cli/loadtest.zig).
fn nanoNow() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

/// Sleep for `ns` nanoseconds (raw syscall — std.Thread.sleep and
/// std.posix.nanosleep do not exist in 0.17.1).
fn sleepNs(ns: u64) void {
    const ts = std.os.linux.timespec{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub const Fanout = struct {
    tasks: []Task,
    threads: []?std.Thread,
    alloc: std.mem.Allocator,

    /// Start the tasks. When `parallel` is false every task runs inline
    /// on the caller's thread and `wait`/`joinAll` are no-ops. A thread
    /// that fails to spawn runs inline in its own arena instead.
    pub fn start(alloc: std.mem.Allocator, tasks: []Task, parallel: bool) !Fanout {
        var threads = try alloc.alloc(?std.Thread, tasks.len);
        for (threads) |*t| t.* = null;
        if (!parallel) {
            for (tasks) |*t| {
                t.run(t.ctx, alloc) catch |e| {
                    t.err = e;
                };
                t.done.store(true, .release);
            }
            return .{ .tasks = tasks, .threads = threads, .alloc = alloc };
        }
        for (tasks, 0..) |*t, i| {
            const arena = try alloc.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            t.arena = arena;
            threads[i] = std.Thread.spawn(.{}, worker, .{t}) catch null;
            if (threads[i] == null) {
                // Spawn failed: run inline in the task's own arena.
                t.run(t.ctx, arena.allocator()) catch |e| {
                    t.err = e;
                };
                t.done.store(true, .release);
            }
        }
        return .{ .tasks = tasks, .threads = threads, .alloc = alloc };
    }

    fn worker(task: *Task) void {
        const arena = task.arena.?;
        task.run(task.ctx, arena.allocator()) catch |e| {
            task.err = e;
        };
        task.done.store(true, .release);
    }

    /// Wait until every task is done or `timeout_ms` passes. Returns
    /// early when all tasks finish; tasks still running after the
    /// deadline are joined later by `joinAll`.
    pub fn wait(self: *Fanout, timeout_ms: u64) void {
        const deadline = nanoNow() + @as(i64, @intCast(timeout_ms)) * 1_000_000;
        while (nanoNow() < deadline) {
            if (self.allDone()) return;
            sleepNs(500_000);
        }
    }

    pub fn allDone(self: *const Fanout) bool {
        for (self.tasks) |*t| {
            if (!t.done.load(.acquire)) return false;
        }
        return true;
    }

    /// True when the named task finished (before or after the deadline).
    pub fn completed(self: *const Fanout, name: []const u8) bool {
        for (self.tasks) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t.done.load(.acquire);
        }
        return false;
    }

    /// Join every spawned thread and free every task arena. Call AFTER
    /// the response is rendered and sent — never before.
    pub fn joinAll(self: *Fanout) void {
        for (self.threads) |maybe_thread| {
            if (maybe_thread) |th| th.join();
        }
        for (self.tasks) |*t| {
            if (t.arena) |arena| {
                arena.deinit();
                self.alloc.destroy(arena);
                t.arena = null;
            }
        }
        self.alloc.free(self.threads);
    }
};

/// Run every task inline on the caller's thread (sequential fallback
/// when parallel start fails or the store is not thread-safe).
pub fn runSequential(alloc: std.mem.Allocator, tasks: []Task) void {
    for (tasks) |*t| {
        t.run(t.ctx, alloc) catch |e| {
            t.err = e;
        };
        t.done.store(true, .release);
    }
}

const TestCtx = struct {
    out: ?[]const u8 = null,
    fail: bool = false,
};

fn testTask(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
    const t: *TestCtx = @ptrCast(@alignCast(ctx));
    if (t.fail) return error.TestFail;
    t.out = try alloc.dupe(u8, "done");
}

fn sleepTask(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
    _ = ctx;
    _ = alloc;
    sleepNs(50_000_000);
}

test "fanout sequential runs every task inline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var c1 = TestCtx{};
    var c2 = TestCtx{ .fail = true };
    var tasks = [_]Task{
        .{ .name = "a", .run = testTask, .ctx = &c1 },
        .{ .name = "b", .run = testTask, .ctx = &c2 },
    };
    runSequential(alloc, &tasks);
    try std.testing.expect(tasks[0].done.load(.acquire));
    try std.testing.expect(tasks[1].done.load(.acquire));
    try std.testing.expectEqualStrings("done", c1.out.?);
    try std.testing.expect(tasks[1].err != null);
}

test "fanout parallel runs tasks concurrently and joins" {
    var c1 = TestCtx{};
    var c2 = TestCtx{};
    var tasks = [_]Task{
        .{ .name = "a", .run = testTask, .ctx = &c1 },
        .{ .name = "b", .run = testTask, .ctx = &c2 },
    };
    var fo = try Fanout.start(std.testing.allocator, &tasks, true);
    fo.wait(5000);
    try std.testing.expect(fo.allDone());
    try std.testing.expectEqualStrings("done", c1.out.?);
    try std.testing.expectEqualStrings("done", c2.out.?);
    fo.joinAll();
}

test "fanout deadline expires while a straggler runs, join finishes it" {
    var c1 = TestCtx{};
    var tasks = [_]Task{
        .{ .name = "slow", .run = sleepTask, .ctx = &c1 },
    };
    var fo = try Fanout.start(std.testing.allocator, &tasks, true);
    fo.wait(5);
    // The 50ms task cannot have finished in 5ms.
    try std.testing.expect(!fo.allDone());
    try std.testing.expect(!fo.completed("slow"));
    // joinAll blocks until the straggler finishes (post-response join).
    fo.joinAll();
    try std.testing.expect(fo.completed("slow"));
}

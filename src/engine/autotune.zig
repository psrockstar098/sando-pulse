//! Bounded automatic performance tuning (Roadmap 6.10).
//!
//! The tuner adjusts ONLY safe knobs, within documented bounds, one
//! step at a time, with a cooldown between adjustments. Every
//! adjustment is logged by the caller and reversible (reset restores
//! the configured defaults). It never touches correctness behaviour,
//! auth, or retention.
//!
//! Knobs and their signals:
//! - L1 TTL (`PULSE_L1_TTL_S`): signal is the L1 hit rate. A low hit
//!   rate means entries expire before they are re-asked, so the TTL
//!   grows; a very high hit rate means the cache is holding answers
//!   longer than needed, so the TTL shrinks (fresher data).
//! - Fan-out timeout (`PULSE_FANOUT_TIMEOUT_MS`): signal is the
//!   enrichment fan-out incomplete rate. Stragglers mean the deadline
//!   is too tight, so it grows; zero stragglers over many fan-outs
//!   means it can shrink (less waiting on slow backends).
//! - Max concurrent sources (`PULSE_MAX_CONCURRENT_SOURCES`,
//!   worker-side): signal is the ingestion run report. Errors mean
//!   the sources are struggling, so concurrency drops; slow but
//!   error-free runs mean the fetches are network-bound, so
//!   concurrency grows.
//! - Precompute interval (`PULSE_PRECOMPUTE_TTL_S`) is NOT auto-tuned:
//!   there is no in-process signal for briefing freshness cost, so
//!   it stays manual-only (recorded as a gap in STATUS.md).
//!
//! The decision logic is pure (no I/O) so the rules are unit-tested
//! here; the server and the worker own an `Autotuner` each and apply
//! the returned adjustment to their live knobs.

const std = @import("std");
const testing = std.testing;

pub const l1_ttl_min_s: u64 = 60;
pub const l1_ttl_max_s: u64 = 900;
pub const l1_ttl_step_s: u64 = 60;

pub const fanout_timeout_min_ms: u64 = 50;
pub const fanout_timeout_max_ms: u64 = 500;
pub const fanout_timeout_step_ms: u64 = 50;

pub const concurrent_min: usize = 1;
pub const concurrent_max: usize = 8;

/// Queries between server-side adjustments (at most one per window).
pub const server_cooldown_queries: u64 = 100;
/// Worker runs between concurrency adjustments.
pub const worker_cooldown_runs: u64 = 10;

pub const Knob = enum {
    l1_ttl_s,
    fanout_timeout_ms,
    max_concurrent_sources,
};

pub const Adjustment = struct {
    knob: Knob,
    old_value: u64,
    new_value: u64,
    reason: []const u8,
};

/// Signals the server feeds the tuner after each query batch.
pub const ServerSignals = struct {
    l1_hits: u64 = 0,
    l1_misses: u64 = 0,
    fanout_total: u64 = 0,
    fanout_incomplete: u64 = 0,
};

/// Signals the worker feeds the tuner after each ingest run.
pub const WorkerSignals = struct {
    /// Sources that errored in the run (0 = clean run).
    run_errors: usize = 0,
    /// Mean per-source fetch duration in ms (0 when nothing fetched).
    run_mean_duration_ms: i64 = 0,
};

pub const Autotuner = struct {
    enabled: bool = false,
    /// Current runtime values (the tuner moves these, never the config).
    l1_ttl_s: u64,
    fanout_timeout_ms: u64,
    max_concurrent_sources: usize,
    /// Configured defaults — reset() restores these.
    default_l1_ttl_s: u64,
    default_fanout_timeout_ms: u64,
    default_max_concurrent_sources: usize,
    adjustments_total: u64 = 0,
    last_adjustment: ?Adjustment = null,
    /// Query count at the last server-side adjustment.
    last_server_adjust_queries: u64 = 0,
    /// Run count at the last worker-side adjustment.
    last_worker_adjust_run: u64 = 0,
    runs_seen: u64 = 0,

    pub fn init(enabled: bool, l1_ttl_s: u64, fanout_timeout_ms: u64, max_concurrent_sources: usize) Autotuner {
        return .{
            .enabled = enabled,
            .l1_ttl_s = @max(l1_ttl_min_s, @min(l1_ttl_s, l1_ttl_max_s)),
            .fanout_timeout_ms = @max(fanout_timeout_min_ms, @min(fanout_timeout_ms, fanout_timeout_max_ms)),
            .max_concurrent_sources = @max(concurrent_min, @min(max_concurrent_sources, concurrent_max)),
            .default_l1_ttl_s = @max(l1_ttl_min_s, @min(l1_ttl_s, l1_ttl_max_s)),
            .default_fanout_timeout_ms = @max(fanout_timeout_min_ms, @min(fanout_timeout_ms, fanout_timeout_max_ms)),
            .default_max_concurrent_sources = @max(concurrent_min, @min(max_concurrent_sources, concurrent_max)),
        };
    }

    /// One server-side adjustment at most per `server_cooldown_queries`
    /// queries. L1 TTL is checked first, then the fan-out timeout.
    /// Returns null when disabled, in cooldown, under-sampled, or when
    /// every knob is already at the bound the signal wants.
    pub fn maybeTuneServer(self: *Autotuner, signals: ServerSignals, queries_total: u64) ?Adjustment {
        if (!self.enabled) return null;
        if (queries_total -| self.last_server_adjust_queries < server_cooldown_queries) return null;
        const l1_total = signals.l1_hits + signals.l1_misses;
        if (l1_total >= 20) {
            const hit_rate = @as(f64, @floatFromInt(signals.l1_hits)) / @as(f64, @floatFromInt(l1_total));
            if (hit_rate < 0.5 and self.l1_ttl_s < l1_ttl_max_s) {
                return self.apply(.{
                    .knob = .l1_ttl_s,
                    .old_value = self.l1_ttl_s,
                    .new_value = @min(l1_ttl_max_s, self.l1_ttl_s + l1_ttl_step_s),
                    .reason = "l1 hit rate below 0.5: entries expire before re-ask",
                }, queries_total);
            }
            if (hit_rate > 0.9 and self.l1_ttl_s > l1_ttl_min_s) {
                return self.apply(.{
                    .knob = .l1_ttl_s,
                    .old_value = self.l1_ttl_s,
                    .new_value = self.l1_ttl_s -| l1_ttl_step_s,
                    .reason = "l1 hit rate above 0.9: holding answers longer than needed",
                }, queries_total);
            }
        }
        if (signals.fanout_total >= 10) {
            const incomplete_rate = @as(f64, @floatFromInt(signals.fanout_incomplete)) / @as(f64, @floatFromInt(signals.fanout_total));
            if (incomplete_rate > 0.2 and self.fanout_timeout_ms < fanout_timeout_max_ms) {
                return self.apply(.{
                    .knob = .fanout_timeout_ms,
                    .old_value = self.fanout_timeout_ms,
                    .new_value = @min(fanout_timeout_max_ms, self.fanout_timeout_ms + fanout_timeout_step_ms),
                    .reason = "fan-out incomplete rate above 0.2: deadline too tight",
                }, queries_total);
            }
            if (signals.fanout_incomplete == 0 and signals.fanout_total >= 50 and self.fanout_timeout_ms > fanout_timeout_min_ms) {
                return self.apply(.{
                    .knob = .fanout_timeout_ms,
                    .old_value = self.fanout_timeout_ms,
                    .new_value = self.fanout_timeout_ms -| fanout_timeout_step_ms,
                    .reason = "no fan-out stragglers in 50 fan-outs: deadline can shrink",
                }, queries_total);
            }
        }
        return null;
    }

    /// One worker-side adjustment at most per `worker_cooldown_runs`
    /// runs. Errors shed concurrency; slow-but-clean runs add it.
    pub fn maybeTuneWorker(self: *Autotuner, signals: WorkerSignals) ?Adjustment {
        if (!self.enabled) return null;
        self.runs_seen += 1;
        if (self.runs_seen -| self.last_worker_adjust_run < worker_cooldown_runs) return null;
        if (signals.run_errors > 0 and self.max_concurrent_sources > concurrent_min) {
            return self.applyWorker(.{
                .knob = .max_concurrent_sources,
                .old_value = @intCast(self.max_concurrent_sources),
                .new_value = @intCast(self.max_concurrent_sources - 1),
                .reason = "ingest run had source errors: shedding concurrency",
            });
        }
        if (signals.run_errors == 0 and signals.run_mean_duration_ms > 2000 and self.max_concurrent_sources < concurrent_max) {
            return self.applyWorker(.{
                .knob = .max_concurrent_sources,
                .old_value = @intCast(self.max_concurrent_sources),
                .new_value = @intCast(self.max_concurrent_sources + 1),
                .reason = "slow but error-free fetches: fetches are network-bound",
            });
        }
        return null;
    }

    /// Restore the configured defaults. The caller logs the reset;
    /// the returned list is the set of values that actually changed.
    pub fn reset(self: *Autotuner, changed: *std.ArrayList(Adjustment), alloc: std.mem.Allocator) !void {
        if (self.l1_ttl_s != self.default_l1_ttl_s) try changed.append(alloc, .{
            .knob = .l1_ttl_s,
            .old_value = self.l1_ttl_s,
            .new_value = self.default_l1_ttl_s,
            .reason = "manual reset to configured default",
        });
        if (self.fanout_timeout_ms != self.default_fanout_timeout_ms) try changed.append(alloc, .{
            .knob = .fanout_timeout_ms,
            .old_value = self.fanout_timeout_ms,
            .new_value = self.default_fanout_timeout_ms,
            .reason = "manual reset to configured default",
        });
        if (self.max_concurrent_sources != self.default_max_concurrent_sources) try changed.append(alloc, .{
            .knob = .max_concurrent_sources,
            .old_value = @intCast(self.max_concurrent_sources),
            .new_value = @intCast(self.default_max_concurrent_sources),
            .reason = "manual reset to configured default",
        });
        self.l1_ttl_s = self.default_l1_ttl_s;
        self.fanout_timeout_ms = self.default_fanout_timeout_ms;
        self.max_concurrent_sources = self.default_max_concurrent_sources;
        self.last_adjustment = null;
    }

    fn apply(self: *Autotuner, adj: Adjustment, queries_total: u64) Adjustment {
        switch (adj.knob) {
            .l1_ttl_s => self.l1_ttl_s = adj.new_value,
            .fanout_timeout_ms => self.fanout_timeout_ms = adj.new_value,
            .max_concurrent_sources => self.max_concurrent_sources = @intCast(adj.new_value),
        }
        self.adjustments_total += 1;
        self.last_adjustment = adj;
        self.last_server_adjust_queries = queries_total;
        return adj;
    }

    fn applyWorker(self: *Autotuner, adj: Adjustment) Adjustment {
        self.max_concurrent_sources = @intCast(adj.new_value);
        self.adjustments_total += 1;
        self.last_adjustment = adj;
        self.last_worker_adjust_run = self.runs_seen;
        return adj;
    }
};

test "autotune: disabled never adjusts" {
    var t = Autotuner.init(false, 300, 100, 4);
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 1, .l1_misses = 99 }, 1000) == null);
    try testing.expect(t.maybeTuneWorker(.{ .run_errors = 3 }) == null);
    try testing.expectEqual(@as(u64, 0), t.adjustments_total);
}

test "autotune: low l1 hit rate raises ttl, clamped at max" {
    var t = Autotuner.init(true, 300, 100, 4);
    const adj = t.maybeTuneServer(.{ .l1_hits = 5, .l1_misses = 25 }, 100).?;
    try testing.expectEqual(Knob.l1_ttl_s, adj.knob);
    try testing.expectEqual(@as(u64, 300), adj.old_value);
    try testing.expectEqual(@as(u64, 360), adj.new_value);
    try testing.expectEqual(@as(u64, 360), t.l1_ttl_s);
    // Cooldown: the next 99 queries adjust nothing.
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 5, .l1_misses = 25 }, 150) == null);
    // At the max the signal wants no more.
    t.l1_ttl_s = l1_ttl_max_s;
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 5, .l1_misses = 25 }, 1000) == null);
}

test "autotune: high l1 hit rate lowers ttl, clamped at min" {
    var t = Autotuner.init(true, 120, 100, 4);
    const adj = t.maybeTuneServer(.{ .l1_hits = 95, .l1_misses = 5 }, 100).?;
    try testing.expectEqual(@as(u64, 60), adj.new_value);
    try testing.expectEqual(@as(u64, 60), t.l1_ttl_s);
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 95, .l1_misses = 5 }, 1000) == null);
}

test "autotune: under-sampled signals adjust nothing" {
    var t = Autotuner.init(true, 300, 100, 4);
    // 19 L1 samples is below the 20-sample floor.
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 1, .l1_misses = 18 }, 100) == null);
    // 9 fan-outs is below the 10-sample floor.
    try testing.expect(t.maybeTuneServer(.{ .l1_hits = 15, .l1_misses = 5, .fanout_total = 9, .fanout_incomplete = 9 }, 100) == null);
}

test "autotune: stragglers raise the fan-out timeout, clean runs lower it" {
    var t = Autotuner.init(true, 300, 100, 4);
    const up = t.maybeTuneServer(.{ .l1_hits = 15, .l1_misses = 5, .fanout_total = 20, .fanout_incomplete = 6 }, 100).?;
    try testing.expectEqual(Knob.fanout_timeout_ms, up.knob);
    try testing.expectEqual(@as(u64, 150), up.new_value);
    var t2 = Autotuner.init(true, 300, 200, 4);
    const down = t2.maybeTuneServer(.{ .l1_hits = 15, .l1_misses = 5, .fanout_total = 50, .fanout_incomplete = 0 }, 100).?;
    try testing.expectEqual(@as(u64, 150), down.new_value);
}

test "autotune: worker sheds concurrency on errors, adds it on slow clean runs" {
    var t = Autotuner.init(true, 300, 100, 4);
    // Cooldown: 10 runs before the first worker adjustment.
    for (0..9) |_| try testing.expect(t.maybeTuneWorker(.{ .run_errors = 2 }) == null);
    const down = t.maybeTuneWorker(.{ .run_errors = 2 }).?;
    try testing.expectEqual(Knob.max_concurrent_sources, down.knob);
    try testing.expectEqual(@as(u64, 3), down.new_value);
    var t2 = Autotuner.init(true, 300, 100, 4);
    for (0..9) |_| try testing.expect(t2.maybeTuneWorker(.{ .run_errors = 0, .run_mean_duration_ms = 3000 }) == null);
    const up = t2.maybeTuneWorker(.{ .run_errors = 0, .run_mean_duration_ms = 3000 }).?;
    try testing.expectEqual(@as(u64, 5), up.new_value);
    // At the cap, no more — even past the cooldown.
    t2.max_concurrent_sources = concurrent_max;
    t2.last_worker_adjust_run = 0;
    try testing.expect(t2.maybeTuneWorker(.{ .run_errors = 0, .run_mean_duration_ms = 3000 }) == null);
}

test "autotune: reset restores configured defaults" {
    var t = Autotuner.init(true, 300, 100, 4);
    _ = t.maybeTuneServer(.{ .l1_hits = 5, .l1_misses = 25 }, 100).?;
    try testing.expectEqual(@as(u64, 360), t.l1_ttl_s);
    var changed: std.ArrayList(Adjustment) = .empty;
    defer changed.deinit(testing.allocator);
    try t.reset(&changed, testing.allocator);
    try testing.expectEqual(@as(u64, 300), t.l1_ttl_s);
    try testing.expectEqual(@as(usize, 1), changed.items.len);
    try testing.expectEqual(Knob.l1_ttl_s, changed.items[0].knob);
    // Resetting again changes nothing.
    changed.clearRetainingCapacity();
    try t.reset(&changed, testing.allocator);
    try testing.expectEqual(@as(usize, 0), changed.items.len);
}

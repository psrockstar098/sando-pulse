//! Circuit breakers (Roadmap 6.11): stop hammering a dead dependency
//! and fall back to the degraded path that already exists, instead of
//! paying a timeout on every request.
//!
//! The breaker is a pure state machine — no I/O, no clock of its own;
//! callers pass `now_ms` (from `timex.nowMillis`) so the logic is
//! unit-testable with fake times. States:
//!   closed    — calls pass; consecutive failures are counted.
//!   open      — calls are refused (`allow` returns false) until the
//!               cooldown elapses; each refusal is counted as skipped.
//!   half-open — one trial call is allowed after the cooldown; a
//!               success closes the breaker, a failure re-opens it.
//! Trips (closed -> open transitions) are counted. The breaker never
//! changes what the fallback is — it only decides whether the
//! dependency is worth calling at all.
//!
//! Wired (server + worker, both through the same provider value):
//!   embedding provider — the external HTTP embedder has no
//!     per-request timeout in Zig 0.17.1's std.http.Client, so a dead
//!     provider would hang every query and every ingest. The wrapper
//!     below short-circuits to an error while open; both call sites
//!     already fall back to lexical on embed failure.
//!   Redis L2 cache — the query path already falls through to
//!     compute-fresh when the cache lookup fails; the breaker skips
//!     the lookup entirely while open, so a dead Redis costs one
//!     branch instead of a refused connection per request.
//!
//! Single-threaded use only (the server and the worker are each
//! single-threaded processes); no locking.

const std = @import("std");
const timex = @import("../common/time.zig");
const providers = @import("../ai/providers.zig");

pub const State = enum { closed, half_open, open };

/// Prometheus gauge code: 0 = closed, 1 = half-open, 2 = open.
pub fn stateCode(s: State) u8 {
    return switch (s) {
        .closed => 0,
        .half_open => 1,
        .open => 2,
    };
}

pub const CircuitBreaker = struct {
    failure_threshold: u32,
    cooldown_ms: u64,
    state: State = .closed,
    consecutive_failures: u32 = 0,
    opened_at_ms: i64 = 0,
    trips: u64 = 0,
    skipped_total: u64 = 0,

    pub fn init(failure_threshold: u32, cooldown_ms: u64) CircuitBreaker {
        return .{
            .failure_threshold = @max(1, failure_threshold),
            .cooldown_ms = cooldown_ms,
        };
    }

    /// Whether a call may proceed now. Refusals are counted.
    pub fn allow(self: *CircuitBreaker, now_ms: i64) bool {
        switch (self.state) {
            .closed => return true,
            .half_open => return true,
            .open => {
                if (now_ms - self.opened_at_ms >= @as(i64, @intCast(self.cooldown_ms))) {
                    self.state = .half_open;
                    return true;
                }
                self.skipped_total += 1;
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *CircuitBreaker, now_ms: i64) void {
        _ = now_ms;
        self.consecutive_failures = 0;
        if (self.state == .half_open) self.state = .closed;
    }

    pub fn recordFailure(self: *CircuitBreaker, now_ms: i64) void {
        self.consecutive_failures += 1;
        if (self.state == .half_open) {
            self.state = .open;
            self.opened_at_ms = now_ms;
            self.trips += 1;
            return;
        }
        if (self.state == .closed and self.consecutive_failures >= self.failure_threshold) {
            self.state = .open;
            self.opened_at_ms = now_ms;
            self.trips += 1;
        }
    }
};

/// Embedding-provider wrapper: checks the breaker before calling the
/// inner provider. The local hashed provider never fails and never
/// does I/O — only wrap the external provider (main.zig does that).
pub const BreakerEmbedding = struct {
    inner: providers.EmbeddingProvider,
    breaker: *CircuitBreaker,
    io: std.Io,

    pub fn provider(self: *BreakerEmbedding) providers.EmbeddingProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = providers.EmbeddingProvider.VTable{
        .embed = embed,
        .dims = dims,
        .model = model,
        .deinit = deinit,
    };

    fn embed(ptr: *anyopaque, alloc: std.mem.Allocator, text: []const u8) anyerror![]f32 {
        const self: *BreakerEmbedding = @ptrCast(@alignCast(ptr));
        const now_ms = timex.nowMillis(self.io);
        if (!self.breaker.allow(now_ms)) return error.BreakerOpen;
        const vec = self.inner.embed(alloc, text) catch |e| {
            self.breaker.recordFailure(now_ms);
            return e;
        };
        self.breaker.recordSuccess(now_ms);
        return vec;
    }

    fn dims(ptr: *anyopaque) usize {
        const self: *BreakerEmbedding = @ptrCast(@alignCast(ptr));
        return self.inner.dims();
    }

    fn model(ptr: *anyopaque) []const u8 {
        const self: *BreakerEmbedding = @ptrCast(@alignCast(ptr));
        return self.inner.model();
    }

    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *BreakerEmbedding = @ptrCast(@alignCast(ptr));
        self.inner.deinit(alloc);
    }
};

test "breaker: closed allows, success resets the failure count" {
    var b = CircuitBreaker.init(3, 60_000);
    try std.testing.expect(b.allow(0));
    b.recordFailure(0);
    b.recordFailure(1000);
    b.recordSuccess(2000);
    try std.testing.expectEqual(State.closed, b.state);
    b.recordFailure(3000);
    try std.testing.expectEqual(State.closed, b.state);
    try std.testing.expectEqual(@as(u64, 0), b.trips);
}

test "breaker: threshold trips to open, refusals are counted as skipped" {
    var b = CircuitBreaker.init(3, 60_000);
    b.recordFailure(0);
    b.recordFailure(1000);
    try std.testing.expectEqual(State.closed, b.state);
    b.recordFailure(2000);
    try std.testing.expectEqual(State.open, b.state);
    try std.testing.expectEqual(@as(u64, 1), b.trips);
    try std.testing.expect(!b.allow(3000));
    try std.testing.expect(!b.allow(4000));
    try std.testing.expectEqual(@as(u64, 2), b.skipped_total);
}

test "breaker: cooldown expiry allows a trial, success closes" {
    var b = CircuitBreaker.init(2, 10_000);
    b.recordFailure(0);
    b.recordFailure(1000);
    try std.testing.expectEqual(State.open, b.state);
    try std.testing.expect(!b.allow(5000));
    try std.testing.expect(b.allow(11_000));
    try std.testing.expectEqual(State.half_open, b.state);
    b.recordSuccess(11_100);
    try std.testing.expectEqual(State.closed, b.state);
    try std.testing.expectEqual(@as(u32, 0), b.consecutive_failures);
}

test "breaker: half-open trial failure re-opens and trips again" {
    var b = CircuitBreaker.init(2, 10_000);
    b.recordFailure(0);
    b.recordFailure(1000);
    _ = b.allow(11_000);
    try std.testing.expectEqual(State.half_open, b.state);
    b.recordFailure(11_100);
    try std.testing.expectEqual(State.open, b.state);
    try std.testing.expectEqual(@as(u64, 2), b.trips);
    try std.testing.expect(!b.allow(12_000));
    try std.testing.expect(b.allow(21_100));
}

test "breaker: threshold of 1 trips on the first failure" {
    var b = CircuitBreaker.init(1, 5000);
    b.recordFailure(0);
    try std.testing.expectEqual(State.open, b.state);
    try std.testing.expectEqual(@as(u8, 2), stateCode(b.state));
    try std.testing.expectEqual(@as(u8, 0), stateCode(State.closed));
    try std.testing.expectEqual(@as(u8, 1), stateCode(State.half_open));
}

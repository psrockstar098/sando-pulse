//! Time helpers for Zig 0.17.1.
//! This toolchain's `std.time` has no wall-clock functions — all time comes
//! from `std.Io.Clock.real` (Unix epoch, leap seconds ignored).

const std = @import("std");

pub fn nowMillis(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub fn nowNanos(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .real).toNanoseconds();
}

/// Measured latency in milliseconds (fractional) between two
/// nanosecond timestamps from `nowNanos`. Used for the `latency_ms`
/// field on every query response (Roadmap 6.1).
pub fn latencyMsF64(start_ns: i96, end_ns: i96) f64 {
    const delta_ns: i96 = end_ns - start_ns;
    return @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
}

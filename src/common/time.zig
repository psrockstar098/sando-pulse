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

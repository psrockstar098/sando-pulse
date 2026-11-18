//! API-key authentication middleware (Roadmap 1.2).
//! - If no API key is configured, the API runs in open dev mode and every
//!   request is allowed (a warning is logged at boot; see main.zig).
//! - If a key is configured, /v1/query requires
//!   `Authorization: Bearer <key>`. Comparison is constant-time.
//! - /v1/health and the Facebook webhook are public by design.
//! Keys are managed via env var PULSE_API_KEY; `pulse keygen` prints a fresh
//! random key for the operator to put in the environment. Raw keys are never
//! written to any file and never logged.

const std = @import("std");

pub const AuthResult = enum { open, ok, missing, invalid };

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Check one request's Authorization header against the configured key.
/// `api_key` is null when the server runs in open dev mode.
pub fn authenticate(api_key: ?[]const u8, auth_header: ?[]const u8) AuthResult {
    return authenticateRotated(api_key, null, auth_header);
}

/// Key rotation (Roadmap 5.1): accept the current key AND the previous
/// one. Rotation procedure: generate a fresh key (`pulse keygen`), put it
/// in PULSE_API_KEY, move the old key to PULSE_API_KEY_PREVIOUS, restart,
/// let clients migrate, then remove PULSE_API_KEY_PREVIOUS and restart
/// again. Open mode only when BOTH are null.
pub fn authenticateRotated(api_key: ?[]const u8, previous_key: ?[]const u8, auth_header: ?[]const u8) AuthResult {
    if (api_key == null and previous_key == null) return .open;
    const header = auth_header orelse return .missing;
    if (header.len < 8) return .invalid;
    if (!std.ascii.eqlIgnoreCase(header[0..6], "bearer")) return .invalid;
    if (header[6] != ' ') return .invalid;
    const presented = std.mem.trim(u8, header[7..], " ");
    if (presented.len == 0) return .invalid;
    if (api_key) |k| {
        if (constantTimeEqual(presented, k)) return .ok;
    }
    if (previous_key) |k| {
        if (constantTimeEqual(presented, k)) return .ok;
    }
    return .invalid;
}

/// The presented Bearer token, or null when the header is absent or
/// malformed. Used as the rate-limiter bucket key so each API key gets
/// its own budget during rotation (the token itself is never logged).
pub fn presentedToken(auth_header: ?[]const u8) ?[]const u8 {
    const header = auth_header orelse return null;
    if (header.len < 8) return null;
    if (!std.ascii.eqlIgnoreCase(header[0..6], "bearer")) return null;
    if (header[6] != ' ') return null;
    const presented = std.mem.trim(u8, header[7..], " ");
    if (presented.len == 0) return null;
    return presented;
}

/// Generate a fresh 32-byte (64 hex char) API key. The caller prints it once
/// for the operator; Pulse never stores it.
/// Randomness comes from the Linux getrandom syscall (this toolchain's
/// std.crypto has no random source; Pulse targets Linux containers).
pub fn generateKey(alloc: std.mem.Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    var filled: usize = 0;
    while (filled < bytes.len) {
        const n = std.os.linux.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
        if (std.posix.errno(n) != .SUCCESS or n == 0) return error.RandomFailed;
        filled += n;
    }
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return alloc.dupe(u8, &hex);
}

test "authenticate open mode allows everything" {
    try std.testing.expectEqual(AuthResult.open, authenticate(null, null));
    try std.testing.expectEqual(AuthResult.open, authenticate(null, "Bearer anything"));
}

test "authenticate checks bearer keys" {
    const key = "test-key-123";
    try std.testing.expectEqual(AuthResult.ok, authenticate(key, "Bearer test-key-123"));
    try std.testing.expectEqual(AuthResult.ok, authenticate(key, "bearer test-key-123"));
    try std.testing.expectEqual(AuthResult.missing, authenticate(key, null));
    try std.testing.expectEqual(AuthResult.invalid, authenticate(key, "Bearer wrong-key"));
    try std.testing.expectEqual(AuthResult.invalid, authenticate(key, "Basic test-key-123"));
    try std.testing.expectEqual(AuthResult.invalid, authenticate(key, "Bearer"));
    try std.testing.expectEqual(AuthResult.invalid, authenticate(key, "Bearer "));
    try std.testing.expectEqual(AuthResult.invalid, authenticate(key, "test-key-123"));
}

test "authenticateRotated accepts current and previous keys" {
    try std.testing.expectEqual(AuthResult.open, authenticateRotated(null, null, null));
    try std.testing.expectEqual(AuthResult.open, authenticateRotated(null, null, "Bearer anything"));
    try std.testing.expectEqual(AuthResult.ok, authenticateRotated("new-key", "old-key", "Bearer new-key"));
    try std.testing.expectEqual(AuthResult.ok, authenticateRotated("new-key", "old-key", "Bearer old-key"));
    try std.testing.expectEqual(AuthResult.ok, authenticateRotated(null, "old-key", "Bearer old-key"));
    try std.testing.expectEqual(AuthResult.missing, authenticateRotated("new-key", "old-key", null));
    try std.testing.expectEqual(AuthResult.invalid, authenticateRotated("new-key", "old-key", "Bearer wrong"));
    try std.testing.expectEqual(AuthResult.invalid, authenticateRotated("new-key", null, "Bearer old-key"));
}

test "generateKey produces 64 hex chars" {
    const k1 = try generateKey(std.testing.allocator);
    defer std.testing.allocator.free(k1);
    const k2 = try generateKey(std.testing.allocator);
    defer std.testing.allocator.free(k2);
    try std.testing.expectEqual(@as(usize, 64), k1.len);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
    for (k1) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

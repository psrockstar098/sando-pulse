//! SSRF protection for outbound ingestion fetches (Roadmap 5.1).
//!
//! Pulse fetches RSS feeds and connector endpoints whose URLs come from
//! the source registry and from redirect Location headers — never from
//! end-user input — but a compromised or misconfigured feed host can
//! redirect anywhere, so every fetch target is checked before connect:
//! literal IPs are range-checked directly; hostnames are resolved and
//! EVERY returned address is checked. Anything in a loopback, private,
//! link-local, CGNAT, documentation, benchmarking, multicast or reserved
//! range is refused with `error.BlockedHost` and the fetch never opens
//! a socket to it.
//!
//! One exception: when the fetch goes through a proxy, the socket
//! connects to the proxy, never to the target host — the target is only
//! named in the CONNECT line, and the proxy resolves the real address.
//! Some egress resolvers answer public names with 198.18/15 placeholder
//! addresses, which would make the guard refuse every public feed on a
//! proxied host (seen live 2026-11-13: all 9 sources refused). So in the
//! proxied case ONLY the 198.18/15 benchmarking range is allowed through
//! the check; every other non-public range is still refused, so a feed
//! redirect to 169.254.169.254, 127.0.0.1 or a private address is still
//! blocked before any socket opens.
//!
//! The check runs immediately before the connect in `fetchOnce`, so the
//! DNS answer used for the decision is the one taken from the same
//! lookup (the std's `connect` re-resolves internally, so a hostile DNS
//! that flips between the check and the connect is a residual gap —
//! documented in STATUS.md, not hidden).
//!
//! The check applies to ingestion fetches (fetchFeed) only. Provider
//! adapters (postJson) are NOT checked: their URLs are operator
//! configuration, and a local Ollama-style endpoint (127.0.0.1:11434)
//! is a legitimate deployment.

const std = @import("std");

pub const SsrfError = error{
    BlockedHost,
    DnsFailed,
} || std.Io.net.HostName.LookupError;

/// IPv4 ranges that are never a legitimate public feed origin.
/// (IANA special-purpose registries: loopback, private-use, link-local,
/// CGNAT, documentation, benchmarking, multicast, reserved.)
/// `allow_benchmarking` is true ONLY when the fetch goes through a proxy:
/// the socket then connects to the proxy, never to the checked address,
/// and some egress resolvers answer public names with 198.18/15
/// placeholder addresses — that answer says nothing about the real target,
/// which the proxy resolves itself. Every other range is refused either
/// way, so a redirect to 169.254.169.254, 127.0.0.1 or a private address
/// is still blocked when proxied.
pub fn isBlockedIp4(b: [4]u8, allow_benchmarking: bool) bool {
    if (b[0] == 0) return true; // 0.0.0.0/8 "this network"
    if (b[0] == 10) return true; // 10.0.0.0/8 private
    if (b[0] == 100 and b[1] >= 64 and b[1] <= 127) return true; // 100.64.0.0/10 CGNAT
    if (b[0] == 127) return true; // 127.0.0.0/8 loopback
    if (b[0] == 169 and b[1] == 254) return true; // 169.254.0.0/16 link-local (cloud metadata)
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return true; // 172.16.0.0/12 private
    if (b[0] == 192 and b[1] == 0 and b[2] == 0) return true; // 192.0.0.0/24 IETF protocol assignments
    if (b[0] == 192 and b[1] == 0 and b[2] == 2) return true; // 192.0.2.0/24 TEST-NET-1
    if (b[0] == 192 and b[1] == 168) return true; // 192.168.0.0/16 private
    if (b[0] == 198 and b[1] == 18) return !allow_benchmarking; // 198.18.0.0/15 benchmarking
    if (b[0] == 198 and b[1] == 51 and b[2] == 100) return true; // 198.51.100.0/24 TEST-NET-2
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return true; // 203.0.113.0/24 TEST-NET-3
    if (b[0] >= 224 and b[0] <= 239) return true; // 224.0.0.0/4 multicast
    if (b[0] >= 240) return true; // 240.0.0.0/4 reserved + 255.255.255.255
    return false;
}

/// IPv6 ranges that are never a legitimate public feed origin.
pub fn isBlockedIp6(b: [16]u8, allow_benchmarking: bool) bool {
    // :: (unspecified) and ::1 (loopback).
    var all_zero = true;
    for (b) |x| {
        if (x != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return true;
    if (b[15] == 1) {
        var rest_zero = true;
        for (b[0..15]) |x| {
            if (x != 0) {
                rest_zero = false;
                break;
            }
        }
        if (rest_zero) return true; // ::1
    }
    // ::ffff:a.b.c.d — IPv4-mapped: judge the embedded IPv4 address.
    if (std.mem.eql(u8, b[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        return isBlockedIp4(b[12..].*, allow_benchmarking);
    }
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
    if (b[0] == 0xff) return true; // ff00::/8 multicast
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return true; // 2001:db8::/32 documentation
    return false;
}

fn isBlockedAddress(addr: std.Io.net.IpAddress, allow_benchmarking: bool) bool {
    return switch (addr) {
        .ip4 => |ip4| isBlockedIp4(ip4.bytes, allow_benchmarking),
        .ip6 => |ip6| isBlockedIp6(ip6.bytes, allow_benchmarking),
    };
}

/// Check one fetch target host before any socket is opened.
/// - A literal IP is range-checked directly (no DNS involved).
/// - A hostname is resolved and EVERY returned address must be public;
///   one blocked address refuses the whole host (a mixed answer is a
///   rebinding attempt until proven otherwise).
/// - No address at all (or a lookup failure) is an error, never a pass.
/// - `allow_benchmarking` is true only when the fetch goes through a
///   proxy (see isBlockedIp4): the checked address is then never the
///   socket's destination.
pub fn checkHost(alloc: std.mem.Allocator, io: std.Io, host: []const u8, allow_benchmarking: bool) !void {
    _ = alloc;
    if (std.Io.net.IpAddress.parse(host, 0)) |addr| {
        if (isBlockedAddress(addr, allow_benchmarking)) return error.BlockedHost;
        return;
    } else |_| {}
    const name = std.Io.net.HostName.init(host) catch return error.DnsFailed;
    var results_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results_buf);
    name.lookup(io, &queue, .{ .port = 80 }) catch return error.DnsFailed;
    var out: [16]std.Io.net.HostName.LookupResult = undefined;
    const n = queue.get(io, &out, 1) catch return error.DnsFailed;
    if (n == 0) return error.DnsFailed;
    var saw_address = false;
    for (out[0..n]) |r| {
        if (r != .address) continue;
        saw_address = true;
        if (isBlockedAddress(r.address, allow_benchmarking)) return error.BlockedHost;
    }
    if (!saw_address) return error.DnsFailed;
}

test "ssrf: loopback and private IPv4 blocked" {
    try std.testing.expect(isBlockedIp4(.{ 127, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 127, 53, 1, 2 }, false));
    try std.testing.expect(isBlockedIp4(.{ 10, 0, 0, 5 }, false));
    try std.testing.expect(isBlockedIp4(.{ 172, 16, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 172, 31, 255, 254 }, false));
    try std.testing.expect(isBlockedIp4(.{ 192, 168, 1, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 0, 0, 0, 0 }, false));
    try std.testing.expect(isBlockedIp4(.{ 169, 254, 169, 254 }, false));
    try std.testing.expect(isBlockedIp4(.{ 100, 64, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 100, 127, 255, 255 }, false));
}

test "ssrf: documentation, benchmarking, multicast, reserved IPv4 blocked" {
    try std.testing.expect(isBlockedIp4(.{ 192, 0, 2, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 198, 51, 100, 7 }, false));
    try std.testing.expect(isBlockedIp4(.{ 203, 0, 113, 9 }, false));
    try std.testing.expect(isBlockedIp4(.{ 198, 18, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 224, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 240, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp4(.{ 255, 255, 255, 255 }, false));
    try std.testing.expect(isBlockedIp4(.{ 192, 0, 0, 1 }, false));
}

test "ssrf: public IPv4 allowed, boundary cases exact" {
    try std.testing.expect(!isBlockedIp4(.{ 8, 8, 8, 8 }, false));
    try std.testing.expect(!isBlockedIp4(.{ 1, 1, 1, 1 }, false));
    try std.testing.expect(!isBlockedIp4(.{ 104, 29, 1, 2 }, false));
    try std.testing.expect(!isBlockedIp4(.{ 172, 32, 0, 1 }, false)); // just past 172.16/12
    try std.testing.expect(!isBlockedIp4(.{ 172, 15, 255, 255 }, false)); // just before 172.16/12
    try std.testing.expect(!isBlockedIp4(.{ 100, 63, 255, 255 }, false)); // just before CGNAT
    try std.testing.expect(!isBlockedIp4(.{ 100, 128, 0, 1 }, false)); // just past CGNAT
    try std.testing.expect(!isBlockedIp4(.{ 11, 0, 0, 1 }, false)); // just past 10/8
    try std.testing.expect(!isBlockedIp4(.{ 9, 255, 255, 255 }, false)); // just before 10/8
}

test "ssrf: IPv6 blocked ranges" {
    try std.testing.expect(isBlockedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0xfd, 0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    // IPv4-mapped loopback and private: judged by the embedded v4.
    try std.testing.expect(isBlockedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 }, false));
    try std.testing.expect(isBlockedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 }, false));
    // IPv4-mapped public: allowed.
    try std.testing.expect(!isBlockedIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 8, 8, 8, 8 }, false));
}

test "ssrf: public IPv6 allowed" {
    try std.testing.expect(!isBlockedIp6(.{ 0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
    try std.testing.expect(!isBlockedIp6(.{ 0x2a, 0x00, 0x14, 0x50, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, false));
}

test "ssrf: checkHost blocks literal private IPs, allows public ones" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "127.0.0.1", false));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "10.1.2.3", false));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "192.168.0.1", false));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "169.254.169.254", false));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "::1", false));
    try checkHost(std.testing.allocator, io, "8.8.8.8", false);
    try checkHost(std.testing.allocator, io, "1.1.1.1", false);
}

test "ssrf: proxied check allows 198.18/15 placeholders, still blocks internal ranges" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Proxied: the socket goes to the proxy, never to the checked address,
    // so a 198.18/15 placeholder answer from the egress resolver is fine.
    try checkHost(std.testing.allocator, io, "198.18.151.74", true);
    // ...but loopback, private, link-local and CGNAT are still refused.
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "127.0.0.1", true));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "169.254.169.254", true));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "10.0.0.1", true));
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "100.64.0.1", true));
    // Direct (not proxied): 198.18/15 is still blocked.
    try std.testing.expectError(error.BlockedHost, checkHost(std.testing.allocator, io, "198.18.151.74", false));
}

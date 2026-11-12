//! Source management (Roadmap 3.1): per-source runtime configuration,
//! scheduling, authentication state, reliability profiles, and
//! collection limits — resolved from the process environment on top of
//! the static registry (sources.zig).
//!
//! No secret is ever stored here: an auth declaration names the
//! ENVIRONMENT VARIABLE holding the credential (e.g.
//! PULSE_SOURCE_LISGIS_AUTH_ENV=LISGIS_API_KEY); the value itself is
//! only ever read at fetch time by the connector that needs it, and
//! never logged.
//!
//! Overrides (per source id, dashes become underscores, uppercased):
//!   PULSE_SOURCE_<ID>_ENABLED=0|1     — override the registry default
//!   PULSE_SOURCE_<ID>_LIMIT=N         — max items collected per run
//!                                        (default 100, clamped 1..1000)
//!   PULSE_SOURCE_<ID>_INTERVAL_S=N    — fetch interval in seconds
//!                                        (default: global ingest interval,
//!                                        minimum 60)
//!   PULSE_SOURCE_<ID>_AUTH_ENV=NAME   — NAME is the env var holding
//!                                        this source's credential

const std = @import("std");
const sources = @import("sources.zig");

pub const default_limit: usize = 100;
pub const min_interval_s: u64 = 60;

pub const AuthStatus = enum {
    /// No credential needed (public RSS / public data).
    none_required,
    /// A credential env var is declared and present.
    configured,
    /// A credential env var is declared but absent — the source must
    /// be skipped, never fetched unauthenticated.
    missing,
};

pub const SourceRuntime = struct {
    source: sources.Source,
    enabled: bool,
    limit: usize,
    interval_s: u64,
    /// Name of the env var holding the credential, when declared.
    auth_env_var: ?[]const u8,
    auth: AuthStatus,
};

/// Reliability profile (Roadmap 3.1): the design-doc grades map to
/// tiers — government sources (0.88) are "high", news (0.70) is
/// "standard", anything below 0.60 is "low". Calibration against
/// observed accuracy is Roadmap 4.6's job, not this tier's.
pub fn reliabilityTier(reliability: f32) []const u8 {
    if (reliability >= 0.85) return "high";
    if (reliability >= 0.60) return "standard";
    return "low";
}

/// Due for a fetch when never run, or when the interval has elapsed
/// since the last recorded run.
pub fn isDue(interval_s: u64, now: i64, last_run_at: ?i64) bool {
    const last = last_run_at orelse return true;
    return now - last >= @as(i64, @intCast(interval_s));
}

fn envName(alloc: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "PULSE_SOURCE_");
    for (id) |c| {
        if (c == '-') {
            try out.append(alloc, '_');
        } else {
            try out.append(alloc, std.ascii.toUpper(c));
        }
    }
    try out.append(alloc, '_');
    try out.appendSlice(alloc, suffix);
    return out.toOwnedSlice(alloc);
}

fn envGet(environ: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const env = environ orelse return null;
    return env.get(name);
}

/// Resolve one source's runtime config. `environ` may be null (tests /
/// callers without an env map) — then registry defaults apply.
pub fn resolve(
    alloc: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    source: sources.Source,
    default_interval_s: u64,
) !SourceRuntime {
    var rt = SourceRuntime{
        .source = source,
        .enabled = source.enabled,
        .limit = default_limit,
        .interval_s = @max(default_interval_s, min_interval_s),
        .auth_env_var = null,
        .auth = .none_required,
    };
    const enabled_name = try envName(alloc, source.id, "ENABLED");
    defer alloc.free(enabled_name);
    if (envGet(environ, enabled_name)) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) {
            rt.enabled = false;
        } else if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) {
            rt.enabled = true;
        }
    }
    const limit_name = try envName(alloc, source.id, "LIMIT");
    defer alloc.free(limit_name);
    if (envGet(environ, limit_name)) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| {
            rt.limit = @min(@max(n, 1), 1000);
        } else |_| {}
    }
    const interval_name = try envName(alloc, source.id, "INTERVAL_S");
    defer alloc.free(interval_name);
    if (envGet(environ, interval_name)) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |n| {
            rt.interval_s = @max(n, min_interval_s);
        } else |_| {}
    }
    const auth_name = try envName(alloc, source.id, "AUTH_ENV");
    defer alloc.free(auth_name);
    if (envGet(environ, auth_name)) |v| {
        if (v.len > 0) {
            rt.auth_env_var = v;
            rt.auth = if (envGet(environ, v) != null) .configured else .missing;
        }
    }
    return rt;
}

test "reliabilityTier: boundaries" {
    try std.testing.expectEqualStrings("high", reliabilityTier(0.88));
    try std.testing.expectEqualStrings("high", reliabilityTier(0.85));
    try std.testing.expectEqualStrings("standard", reliabilityTier(0.70));
    try std.testing.expectEqualStrings("standard", reliabilityTier(0.60));
    try std.testing.expectEqualStrings("low", reliabilityTier(0.59));
}

test "isDue: never run is due, interval gates the rest" {
    try std.testing.expect(isDue(300, 1000, null));
    try std.testing.expect(isDue(300, 1000, 700));
    try std.testing.expect(!isDue(300, 999, 700));
    try std.testing.expect(isDue(60, 1000, 940));
}

test "resolve: defaults from the registry with no env" {
    const alloc = std.testing.allocator;
    const src = sources.find("new-dawn").?;
    const rt = try resolve(alloc, null, src, 300);
    try std.testing.expect(rt.enabled);
    try std.testing.expectEqual(@as(usize, 100), rt.limit);
    try std.testing.expectEqual(@as(u64, 300), rt.interval_s);
    try std.testing.expectEqual(AuthStatus.none_required, rt.auth);
    try std.testing.expectEqualStrings("standard", reliabilityTier(rt.source.reliability));
}

test "resolve: env overrides enabled, limit, interval, auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PULSE_SOURCE_NEW_DAWN_LIMIT", "5");
    try env.put("PULSE_SOURCE_NEW_DAWN_INTERVAL_S", "3600");
    try env.put("PULSE_SOURCE_NEW_DAWN_AUTH_ENV", "NEW_DAWN_API_KEY");
    const src = sources.find("new-dawn").?;
    const rt = try resolve(alloc, &env, src, 300);
    try std.testing.expectEqual(@as(usize, 5), rt.limit);
    try std.testing.expectEqual(@as(u64, 3600), rt.interval_s);
    try std.testing.expectEqual(AuthStatus.missing, rt.auth);
    try std.testing.expectEqualStrings("NEW_DAWN_API_KEY", rt.auth_env_var.?);
    // Declared credential present -> configured.
    try env.put("NEW_DAWN_API_KEY", "secret-value-never-logged");
    const rt2 = try resolve(alloc, &env, src, 300);
    try std.testing.expectEqual(AuthStatus.configured, rt2.auth);
    // A disabled registry source stays disabled unless overridden.
    const fpa = sources.find("frontpage-africa").?;
    const rt3 = try resolve(alloc, &env, fpa, 300);
    try std.testing.expect(!rt3.enabled);
    try env.put("PULSE_SOURCE_FRONTPAGE_AFRICA_ENABLED", "1");
    const rt4 = try resolve(alloc, &env, fpa, 300);
    try std.testing.expect(rt4.enabled);
}

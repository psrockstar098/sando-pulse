//! Facebook auth (Roadmap 3.2, design doc section 5).
//!
//! There is NO Meta Developer app, NO access token, and NO authorized
//! Page access yet — those steps belong to Dominic (Meta Developer
//! account, app creation, permissions pages_read_engagement /
//! pages_read_user_content / pages_show_list / PPCA eligibility, App
//! Review, media partnerships). This module only READS credentials
//! from the runtime environment; it never creates, requests, or
//! invents one, and it never logs a credential value.
//!
//! Env vars (runtime only, never in any file):
//!   PULSE_FACEBOOK_ACCESS_TOKEN — Page/user access token
//!   PULSE_FACEBOOK_APP_ID       — Meta app id (webhook config)
//!   PULSE_FACEBOOK_APP_SECRET   — Meta app secret (webhook signatures)
//!   PULSE_FACEBOOK_VERIFY_TOKEN — webhook verification token
//!   PULSE_FACEBOOK_API_VERSION  — Graph API version, default "v27.0"
//!   PULSE_FACEBOOK_REGISTRY_PATH — page registry JSON file
//!   PULSE_FACEBOOK_POLL_INTERVAL_S — polling fallback interval,
//!     default 900, minimum 60.

const std = @import("std");

pub const default_api_version = "v27.0";
pub const default_poll_interval_s: u64 = 900;
pub const min_poll_interval_s: u64 = 60;

pub const AuthConfig = struct {
    access_token: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    app_secret: ?[]const u8 = null,
    verify_token: ?[]const u8 = null,
    api_version: []const u8 = default_api_version,
    registry_path: ?[]const u8 = null,
    poll_interval_s: u64 = default_poll_interval_s,

    pub fn load(environ: ?*const std.process.Environ.Map) AuthConfig {
        var cfg = AuthConfig{};
        const env = environ orelse return cfg;
        if (env.get("PULSE_FACEBOOK_ACCESS_TOKEN")) |v| {
            if (v.len > 0) cfg.access_token = v;
        }
        if (env.get("PULSE_FACEBOOK_APP_ID")) |v| {
            if (v.len > 0) cfg.app_id = v;
        }
        if (env.get("PULSE_FACEBOOK_APP_SECRET")) |v| {
            if (v.len > 0) cfg.app_secret = v;
        }
        if (env.get("PULSE_FACEBOOK_VERIFY_TOKEN")) |v| {
            if (v.len > 0) cfg.verify_token = v;
        }
        if (env.get("PULSE_FACEBOOK_API_VERSION")) |v| {
            if (v.len > 0) cfg.api_version = v;
        }
        if (env.get("PULSE_FACEBOOK_REGISTRY_PATH")) |v| {
            if (v.len > 0) cfg.registry_path = v;
        }
        if (env.get("PULSE_FACEBOOK_POLL_INTERVAL_S")) |v| {
            const n = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " "), 10) catch null;
            if (n) |s| cfg.poll_interval_s = @max(min_poll_interval_s, s);
        }
        return cfg;
    }

    pub fn hasToken(self: AuthConfig) bool {
        return self.access_token != null;
    }

    /// Webhook signature validation needs the app secret.
    pub fn canVerifyWebhooks(self: AuthConfig) bool {
        return self.app_secret != null;
    }

    /// Webhook subscription handshake needs the verify token.
    pub fn canVerifySubscription(self: AuthConfig) bool {
        return self.verify_token != null;
    }
};

/// Validate the connector's configuration. Returns null when the
/// connector is usable, otherwise the exact reason it is not — the
/// reason names the step that would unblock it. This is the design
/// doc's `validate()`; the tree's Connector.check() wraps it.
pub fn validateReason(auth: AuthConfig, registered_pages: usize) ?[]const u8 {
    if (!auth.hasToken()) {
        return "no Facebook access token configured (PULSE_FACEBOOK_ACCESS_TOKEN): create a Meta Developer app and authorize a Page — see STATUS.md";
    }
    if (registered_pages == 0) {
        return "no Facebook Pages registered (PULSE_FACEBOOK_REGISTRY_PATH): add authorized Page IDs to the registry file";
    }
    return null;
}

test "auth loads from env; validate names the blocker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    const empty = AuthConfig.load(&env);
    try std.testing.expect(!empty.hasToken());
    try std.testing.expect(!empty.canVerifyWebhooks());
    try std.testing.expect(validateReason(empty, 0) != null);
    try std.testing.expect(std.mem.indexOf(u8, validateReason(empty, 0).?, "PULSE_FACEBOOK_ACCESS_TOKEN") != null);
    try env.put("PULSE_FACEBOOK_ACCESS_TOKEN", "tok");
    const with_token = AuthConfig.load(&env);
    try std.testing.expect(with_token.hasToken());
    try std.testing.expect(validateReason(with_token, 0) != null);
    try std.testing.expect(std.mem.indexOf(u8, validateReason(with_token, 0).?, "REGISTRY") != null);
    try std.testing.expect(validateReason(with_token, 2) == null);
    try env.put("PULSE_FACEBOOK_APP_SECRET", "sec");
    try std.testing.expect(AuthConfig.load(&env).canVerifyWebhooks());
    try env.put("PULSE_FACEBOOK_POLL_INTERVAL_S", "10");
    try std.testing.expectEqual(@as(u64, 60), AuthConfig.load(&env).poll_interval_s);
    try env.put("PULSE_FACEBOOK_POLL_INTERVAL_S", "1800");
    try std.testing.expectEqual(@as(u64, 1800), AuthConfig.load(&env).poll_interval_s);
}

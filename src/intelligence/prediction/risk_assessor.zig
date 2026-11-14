//! Trust & Intelligence Engine, Phase 8: risk assessment.
//!
//! A per-county (optionally per-topic) risk assessment from four
//! signals: daily + monthly anomalies, rising trends, contradiction
//! density among the county's events, and breaking-alert frequency.
//! The level is low / elevated / high with a plain-words reason
//! for every signal that contributed. This is an ASSESSMENT of
//! conditions, never a prediction of a specific event — the response
//! says so.

const std = @import("std");

pub const RiskLevel = enum {
    low,
    elevated,
    high,

    pub fn toString(self: RiskLevel) []const u8 {
        return switch (self) {
            .low => "low",
            .elevated => "elevated",
            .high => "high",
        };
    }
};

/// The four signals, all counted by the caller from the store.
pub const RiskInputs = struct {
    /// Daily anomalies in the county over the last 30 days.
    daily_anomalies: usize,
    /// Monthly anomalies in the county (or topic).
    monthly_anomalies: usize,
    /// Topics rising in the county.
    rising_topics: usize,
    /// Topics analysed in the county.
    topics_total: usize,
    /// Contradiction flags among the county's events: the count of
    /// events carrying at least one flag (a flag is a dissimilar
    /// title pair, so the event count — not the pair count — is the
    /// honest density numerator).
    contradiction_flags: usize,
    /// Events in the county.
    events_total: usize,
    /// Breaking alerts store-wide in the window.
    breaking_alerts: usize,
};

pub const RiskAssessment = struct {
    county: []const u8,
    topic: ?[]const u8,
    level: RiskLevel,
    /// 0..1 weighted score (anomalies 0.35, rising trends 0.25,
    /// contradiction density 0.20, breaking alerts 0.20).
    score: f64,
    reasons: []const []const u8,
};

pub fn assessRisk(alloc: std.mem.Allocator, county: []const u8, topic: ?[]const u8, inputs: RiskInputs) !RiskAssessment {
    const anomaly_n = @min(inputs.daily_anomalies + inputs.monthly_anomalies, 5);
    const anomaly_part = @as(f64, @floatFromInt(anomaly_n)) / 5.0 * 0.35;
    const trend_part: f64 = if (inputs.topics_total == 0) 0 else @as(f64, @floatFromInt(inputs.rising_topics)) / @as(f64, @floatFromInt(inputs.topics_total)) * 0.25;
    const contra_part: f64 = if (inputs.events_total == 0) 0 else @min(@as(f64, @floatFromInt(inputs.contradiction_flags)) / @as(f64, @floatFromInt(inputs.events_total)), 1.0) * 0.20;
    const alerts_part = @as(f64, @floatFromInt(@min(inputs.breaking_alerts, 5))) / 5.0 * 0.20;
    const score = anomaly_part + trend_part + contra_part + alerts_part;

    const level: RiskLevel = if (score >= 0.6) .high else if (score >= 0.35) .elevated else .low;

    var reasons: std.ArrayList([]const u8) = .empty;
    if (anomaly_n > 0) {
        try reasons.append(alloc, try std.fmt.allocPrint(alloc, "{d} anomalie(s) in the last 30 days / monthly history — volume moved sharply.", .{anomaly_n}));
    }
    if (inputs.rising_topics > 0) {
        try reasons.append(alloc, try std.fmt.allocPrint(alloc, "{d} of {d} topic(s) are rising in this county.", .{ inputs.rising_topics, inputs.topics_total }));
    }
    if (inputs.contradiction_flags > 0 and inputs.events_total > 0) {
        try reasons.append(alloc, try std.fmt.allocPrint(alloc, "{d} of {d} event(s) carry at least one contradiction flag — reports disagree.", .{ inputs.contradiction_flags, inputs.events_total }));
    }
    if (inputs.breaking_alerts > 0) {
        try reasons.append(alloc, try std.fmt.allocPrint(alloc, "{d} breaking alert(s) store-wide in the window.", .{inputs.breaking_alerts}));
    }
    if (reasons.items.len == 0) {
        try reasons.append(alloc, "No anomaly, rising-trend, contradiction or breaking-alert signal in the window.");
    }
    return .{
        .county = county,
        .topic = topic,
        .level = level,
        .score = score,
        .reasons = reasons.items,
    };
}

test "risk levels from the four signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const quiet = try assessRisk(alloc, "Nimba", null, .{
        .daily_anomalies = 0,
        .monthly_anomalies = 0,
        .rising_topics = 0,
        .topics_total = 7,
        .contradiction_flags = 0,
        .events_total = 3,
        .breaking_alerts = 0,
    });
    try std.testing.expectEqual(RiskLevel.low, quiet.level);
    try std.testing.expect(quiet.score < 0.35);
    const storm = try assessRisk(alloc, "Montserrado", null, .{
        .daily_anomalies = 3,
        .monthly_anomalies = 2,
        .rising_topics = 5,
        .topics_total = 7,
        .contradiction_flags = 4,
        .events_total = 10,
        .breaking_alerts = 3,
    });
    // anomalies 5/5*0.35=0.35, trends 5/7*0.25=0.179, contra
    // 0.4*0.20=0.08, alerts 3/5*0.20=0.12 → 0.729 → high.
    try std.testing.expectEqual(RiskLevel.high, storm.level);
    try std.testing.expect(storm.score >= 0.6);
    const middling = try assessRisk(alloc, "Bong", null, .{
        .daily_anomalies = 2,
        .monthly_anomalies = 0,
        .rising_topics = 1,
        .topics_total = 7,
        .contradiction_flags = 0,
        .events_total = 2,
        .breaking_alerts = 0,
    });
    // anomalies 2/5*0.35=0.14, trends 1/7*0.25=0.036 → 0.176 → low.
    try std.testing.expectEqual(RiskLevel.low, middling.level);
    const elevated = try assessRisk(alloc, "Bong", null, .{
        .daily_anomalies = 4,
        .monthly_anomalies = 1,
        .rising_topics = 0,
        .topics_total = 7,
        .contradiction_flags = 0,
        .events_total = 2,
        .breaking_alerts = 0,
    });
    // anomalies 5/5*0.35=0.35 → elevated (0.35 boundary).
    try std.testing.expectEqual(RiskLevel.elevated, elevated.level);
}

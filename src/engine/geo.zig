//! Liberian place coordinates + geo helpers (Roadmap 2.2).
//!
//! PROVENANCE: every coordinate below was read live from
//! Nominatim / OpenStreetMap (https://nominatim.openstreetmap.org) on
//! 2026-11-12 and rounded to 4 decimals (~11 m). Licence: Data ©
//! OpenStreetMap contributors, ODbL 1.0.
//!
//! Notes on the values:
//! - Some entries are district-relation centroids, not town points:
//!   Bopolu, Barclayville, Voinjama, Greenville, Zorzor, Foya, Kolahun,
//!   Suakoko. They are good anchors for radius filtering at county scale,
//!   not for street-level precision.
//! - "Cestos City" is the name Pulse uses; OSM names that node
//!   "River Cess" (same place, 5.4522, -9.5817).
//! - "Fish Town" is OSM's "Fish Town City".
//! - Monrovia neighborhoods (Sinkor, Duala, West Point, ...) have no
//!   separate entries: they sit inside Greater Monrovia and resolve to
//!   Monrovia's point. Roadmap 3.6 (OSM connector) refines this table.

const std = @import("std");

pub const Place = struct {
    name: []const u8,
    lat: f64,
    lon: f64,
    /// "city" | "town" | "capital" (county capital)
    kind: []const u8,
};

/// Verified coordinates for Liberian places Pulse knows by name.
pub const places: []const Place = &.{
    .{ .name = "Monrovia", .lat = 6.3204, .lon = -10.8060, .kind = "capital" },
    .{ .name = "Paynesville", .lat = 6.2724, .lon = -10.6951, .kind = "city" },
    .{ .name = "Gbarnga", .lat = 6.9963, .lon = -9.4709, .kind = "capital" },
    .{ .name = "Buchanan", .lat = 5.8813, .lon = -10.0494, .kind = "capital" },
    .{ .name = "Harper", .lat = 4.3789, .lon = -7.7061, .kind = "capital" },
    .{ .name = "Zwedru", .lat = 6.0687, .lon = -8.1343, .kind = "capital" },
    .{ .name = "Kakata", .lat = 6.5323, .lon = -10.3488, .kind = "capital" },
    .{ .name = "Tubmanburg", .lat = 6.8687, .lon = -10.8248, .kind = "capital" },
    .{ .name = "Bopolu", .lat = 7.2125, .lon = -10.4305, .kind = "capital" },
    .{ .name = "Robertsport", .lat = 6.7526, .lon = -11.3670, .kind = "capital" },
    .{ .name = "Barclayville", .lat = 4.7131, .lon = -8.2012, .kind = "capital" },
    .{ .name = "Voinjama", .lat = 8.2451, .lon = -9.8090, .kind = "capital" },
    .{ .name = "Sanniquellie", .lat = 7.3613, .lon = -8.7139, .kind = "capital" },
    .{ .name = "Cestos City", .lat = 5.4522, .lon = -9.5817, .kind = "capital" },
    .{ .name = "Fish Town", .lat = 5.1979, .lon = -7.8760, .kind = "capital" },
    .{ .name = "Greenville", .lat = 5.0456, .lon = -9.0419, .kind = "capital" },
    .{ .name = "Ganta", .lat = 7.2335, .lon = -8.9861, .kind = "town" },
    .{ .name = "Yekepa", .lat = 7.5753, .lon = -8.5419, .kind = "town" },
    .{ .name = "Saclepea", .lat = 6.9638, .lon = -8.8409, .kind = "town" },
    .{ .name = "Tappita", .lat = 6.4918, .lon = -8.8607, .kind = "town" },
    .{ .name = "Zorzor", .lat = 7.9201, .lon = -9.6876, .kind = "town" },
    .{ .name = "Foya", .lat = 8.3586, .lon = -10.1960, .kind = "town" },
    .{ .name = "Kolahun", .lat = 8.1339, .lon = -10.2705, .kind = "town" },
    .{ .name = "Suakoko", .lat = 7.0685, .lon = -9.6223, .kind = "town" },
    .{ .name = "Marshall", .lat = 6.1486, .lon = -10.3836, .kind = "town" },
};

/// County -> its capital's coordinates (the anchor for county-level geo).
pub const county_capitals: []const struct { county: []const u8, capital: []const u8 } = &.{
    .{ .county = "Bomi", .capital = "Tubmanburg" },
    .{ .county = "Bong", .capital = "Gbarnga" },
    .{ .county = "Gbarpolu", .capital = "Bopolu" },
    .{ .county = "Grand Bassa", .capital = "Buchanan" },
    .{ .county = "Grand Cape Mount", .capital = "Robertsport" },
    .{ .county = "Grand Gedeh", .capital = "Zwedru" },
    .{ .county = "Grand Kru", .capital = "Barclayville" },
    .{ .county = "Lofa", .capital = "Voinjama" },
    .{ .county = "Margibi", .capital = "Kakata" },
    .{ .county = "Maryland", .capital = "Harper" },
    .{ .county = "Montserrado", .capital = "Monrovia" },
    .{ .county = "Nimba", .capital = "Sanniquellie" },
    .{ .county = "River Cess", .capital = "Cestos City" },
    .{ .county = "River Gee", .capital = "Fish Town" },
    .{ .county = "Sinoe", .capital = "Greenville" },
};

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Case-insensitive place lookup by name. Returns null for unknown names
/// (Monrovia neighborhoods, villages, and anything not yet verified).
pub fn lookup(name: []const u8) ?Place {
    for (places) |p| {
        if (eqlFold(p.name, name)) return p;
    }
    return null;
}

/// Coordinates for a county, via its capital. Null for unknown counties.
pub fn countyPoint(county: []const u8) ?Place {
    for (county_capitals) |cc| {
        if (eqlFold(cc.county, county)) return lookup(cc.capital);
    }
    return null;
}

const earth_radius_km: f64 = 6371.0;

fn toRad(deg: f64) f64 {
    return deg * std.math.pi / 180.0;
}

/// Great-circle distance in kilometres (haversine). Used by the memory
/// store and by tests; Postgres uses PostGIS ST_DWithin on the same points.
pub fn haversineKm(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const dlat = toRad(lat2 - lat1);
    const dlon = toRad(lon2 - lon1);
    const a = @sin(dlat / 2) * @sin(dlat / 2) +
        @cos(toRad(lat1)) * @cos(toRad(lat2)) * @sin(dlon / 2) * @sin(dlon / 2);
    const c = 2 * std.math.atan2(@sqrt(a), @sqrt(1 - a));
    return earth_radius_km * c;
}

/// Parse a radius phrase out of a query: "within 50 km of Gbarnga",
/// "near Monrovia", "around Buchanan". Returns the place + radius in km.
/// "near"/"around" with no number defaults to 50 km.
pub fn parseRadiusPhrase(query_lower: []const u8) ?struct { place: Place, radius_km: f64 } {
    // "within <n> km of <place>"
    if (std.mem.indexOf(u8, query_lower, "within ")) |idx| {
        const rest = query_lower[idx + "within ".len ..];
        var num_end: usize = 0;
        while (num_end < rest.len and (std.ascii.isDigit(rest[num_end]) or rest[num_end] == '.')) : (num_end += 1) {}
        if (num_end == 0) return null;
        const radius = std.fmt.parseFloat(f64, rest[0..num_end]) catch return null;
        if (radius <= 0 or radius > 500) return null;
        const after = std.mem.trim(u8, rest[num_end..], " ");
        // Skip "km"/"kilometers"/"kilometres" then "of ".
        var tail = after;
        for ([_][]const u8{ "kilometres ", "kilometers ", "km " }) |unit| {
            if (std.mem.startsWith(u8, tail, unit)) {
                tail = tail[unit.len..];
                break;
            }
        }
        if (std.mem.startsWith(u8, tail, "of ")) tail = tail["of ".len..];
        // The place name runs to the end or to the next preposition-ish word.
        const name = std.mem.trim(u8, tail, " .,");
        if (name.len == 0) return null;
        // Try the whole tail, then progressively shorter prefixes (so
        // "within 50 km of gbarnga today" still finds Gbarnga).
        if (lookup(name)) |p| return .{ .place = p, .radius_km = radius };
        var it = std.mem.tokenizeAny(u8, name, " ");
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        while (it.next()) |tok| {
            if (len > 0) {
                if (len + 1 + tok.len > buf.len) break;
                buf[len] = ' ';
                len += 1;
            }
            if (len + tok.len > buf.len) break;
            @memcpy(buf[len .. len + tok.len], tok);
            len += tok.len;
            if (lookup(buf[0..len])) |p| return .{ .place = p, .radius_km = radius };
        }
        return null;
    }
    // "near <place>" / "around <place>" — 50 km default.
    for ([_][]const u8{ "near ", "around " }) |prefix| {
        if (std.mem.indexOf(u8, query_lower, prefix)) |idx| {
            const tail = std.mem.trim(u8, query_lower[idx + prefix.len ..], " .,");
            if (tail.len == 0) return null;
            if (lookup(tail)) |p| return .{ .place = p, .radius_km = 50 };
            var it = std.mem.tokenizeAny(u8, tail, " ");
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            while (it.next()) |tok| {
                if (len > 0) {
                    if (len + 1 + tok.len > buf.len) break;
                    buf[len] = ' ';
                    len += 1;
                }
                if (len + tok.len > buf.len) break;
                @memcpy(buf[len .. len + tok.len], tok);
                len += tok.len;
                if (lookup(buf[0..len])) |p| return .{ .place = p, .radius_km = 50 };
            }
            return null;
        }
    }
    return null;
}

test "geo: haversine Monrovia to Paynesville is ~13 km" {
    const d = haversineKm(6.3204, -10.8060, 6.2724, -10.6951);
    try std.testing.expect(d > 12 and d < 15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), haversineKm(6.3204, -10.8060, 6.3204, -10.8060), 0.001);
    // Monrovia to Harper is far (~400 km).
    const far = haversineKm(6.3204, -10.8060, 4.3789, -7.7061);
    try std.testing.expect(far > 380 and far < 430);
}

test "geo: lookup is case-insensitive, counties resolve via capitals" {
    try std.testing.expect(lookup("monrovia") != null);
    try std.testing.expect(lookup("GBARNGA") != null);
    try std.testing.expectEqual(@as(f64, 6.9963), lookup("Gbarnga").?.lat);
    try std.testing.expect(lookup("Sinkor") == null); // neighborhood: not a separate point
    try std.testing.expect(lookup("Nowhere Town") == null);
    const nimba = countyPoint("Nimba").?;
    try std.testing.expectEqualStrings("Sanniquellie", nimba.name);
    try std.testing.expect(countyPoint("No Such County") == null);
}

test "geo: radius phrases" {
    const a = parseRadiusPhrase("news within 50 km of gbarnga").?;
    try std.testing.expectEqualStrings("Gbarnga", a.place.name);
    try std.testing.expectApproxEqAbs(@as(f64, 50), a.radius_km, 0.001);
    const b = parseRadiusPhrase("what happened near monrovia today").?;
    try std.testing.expectEqualStrings("Monrovia", b.place.name);
    try std.testing.expectApproxEqAbs(@as(f64, 50), b.radius_km, 0.001);
    const c = parseRadiusPhrase("within 25 kilometers of buchanan").?;
    try std.testing.expectApproxEqAbs(@as(f64, 25), c.radius_km, 0.001);
    try std.testing.expect(parseRadiusPhrase("fuel prices in monrovia") == null);
    try std.testing.expect(parseRadiusPhrase("within 50 km of nowhere town") == null);
}

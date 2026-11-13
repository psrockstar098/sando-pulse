//! Liberian knowledge domain seed (Roadmap 3.6).
//!
//! REAL DATA ONLY, collected live 2026-11-12 from public sources:
//!   * Counties (15) + county coordinates: OpenStreetMap Nominatim
//!     (boundary/administrative, one lookup per county).
//!   * Districts (127) + 2008 populations: Wikipedia "Districts of
//!     Liberia" (LISGIS 2008 census table); 23 districts have no
//!     published 2008 population — their population is null, not
//!     guessed. District coordinates: OpenStreetMap Nominatim,
//!     accepted only when the result's first address segment
//!     contains every token of the district name; 22 districts
//!     have no coordinates for that reason (listed in STATUS.md).
//!   * Cities (10 largest, 2008 populations): Wikipedia "List of
//!     cities in Liberia"; coordinates Nominatim.
//!   * Neighborhoods/communities (14): Nominatim (Monrovia suburbs
//!     + Virginia and Brewerville townships, kind "community").
//!   * Hospitals, markets, universities, schools, roads: Nominatim
//!     hits only — anything Nominatim could not resolve is NOT
//!     seeded (see STATUS.md for the missing list).
//!   * Media + government organizations: verified by an HTTP 200
//!     on their official homepage (NEC: HTTP 403 bot-block, domain
//!     live). County/city are null: the check verified the
//!     organization exists, not its street address.
//!   * Statistics: Wikipedia "Demographics of Liberia" census table
//!     (1984/2008/2022) and the "Liberia" article (Montserrado
//!     2008, 2024 estimate). The 2022 figure here is 5,250,187 as
//!     printed in that table; LISGIS elsewhere cites 5,248,621 —
//!     the table figure is used, with its provenance, and the
//!     discrepancy is recorded in STATUS.md.
//!
//! Every row carries its source + verification date (2026-11-12).
//! Seeding is idempotent (upserts merge with the migration 001
//! county seed and with each other); `pulse seed` may run twice.

const std = @import("std");
const knowledge = @import("../storage/knowledge.zig");

pub const verification_date = "2026-11-12";

pub const SeedReport = struct {
    locations: usize = 0,
    facilities: usize = 0,
    statistics: usize = 0,
};

pub const locations: []const knowledge.LocationRow = &.{
        .{ .name = "Bomi", .kind = "county", .county = null, .lat = 6.7177856, .lon = -10.7881766, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Bong", .kind = "county", .county = null, .lat = 6.9622195, .lon = -9.7134459, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Gbarpolu", .kind = "county", .county = null, .lat = 7.2681564, .lon = -10.3814771, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Grand Bassa", .kind = "county", .county = null, .lat = 6.1640621, .lon = -9.895669, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Grand Cape Mount", .kind = "county", .county = null, .lat = 7.0496206, .lon = -11.129843, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Grand Gedeh", .kind = "county", .county = null, .lat = 5.8161533, .lon = -8.0995537, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Grand Kru", .kind = "county", .county = null, .lat = 4.84932, .lon = -8.3308845, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Lofa", .kind = "county", .county = null, .lat = 7.8824046, .lon = -9.9760297, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Margibi", .kind = "county", .county = null, .lat = 6.6053676, .lon = -10.1758429, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Maryland", .kind = "county", .county = null, .lat = 4.6355376, .lon = -7.7281669, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Montserrado", .kind = "county", .county = null, .lat = 6.4095537, .lon = -10.6059403, .population = 1144806, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Nimba", .kind = "county", .county = null, .lat = 6.8088813, .lon = -8.7461448, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "River Gee", .kind = "county", .county = null, .lat = 5.2653903, .lon = -7.8856203, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Rivercess", .kind = "county", .county = null, .lat = 5.9087331, .lon = -9.3938267, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Sinoe", .kind = "county", .county = null, .lat = 5.3232693, .lon = -8.8435955, .population = null, .source = "OpenStreetMap Nominatim (county boundary, admin_level 4)", .verified_at = "2026-11-12" },
        .{ .name = "Dowein", .kind = "district", .county = "Bomi", .lat = 6.566472, .lon = -10.9637869, .population = 28731, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Klay", .kind = "district", .county = "Bomi", .lat = 6.7055351, .lon = -10.8130111, .population = 25720, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Senjeh", .kind = "district", .county = "Bomi", .lat = 6.8404651, .lon = -10.8920517, .population = 52740, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Suehn Mecca", .kind = "district", .county = "Bomi", .lat = 6.7165294, .lon = -10.6542627, .population = 16219, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tehr", .kind = "district", .county = "Bomi", .lat = null, .lon = null, .population = 10655, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Boinsen", .kind = "district", .county = "Bong", .lat = 6.690532, .lon = -9.2268168, .population = 17254, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Fuamah", .kind = "district", .county = "Bong", .lat = 6.9612556, .lon = -10.2774186, .population = 35055, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Jorquelleh", .kind = "district", .county = "Bong", .lat = 6.8990357, .lon = -9.4312197, .population = 145235, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kokoyah", .kind = "district", .county = "Bong", .lat = 6.5173093, .lon = -9.5512209, .population = 4012, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kpaai", .kind = "district", .county = "Bong", .lat = 6.9327372, .lon = -9.250909, .population = 29806, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Panta-Kpa", .kind = "district", .county = "Bong", .lat = null, .lon = null, .population = 19853, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Salala", .kind = "district", .county = "Bong", .lat = 6.7769069, .lon = -9.964887, .population = 52928, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sanayea", .kind = "district", .county = "Bong", .lat = null, .lon = null, .population = 39467, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Suakoko", .kind = "district", .county = "Bong", .lat = 6.9894685, .lon = -9.5815593, .population = 44930, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tukpahblee", .kind = "district", .county = "Bong", .lat = 6.6171081, .lon = -9.4264341, .population = 13120, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Yeallequelleh", .kind = "district", .county = "Bong", .lat = 6.8158796, .lon = -9.6675621, .population = 43695, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Zota", .kind = "district", .county = "Bong", .lat = 7.2728209, .lon = -9.4502151, .population = 22206, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Belleh", .kind = "district", .county = "Gbarpolu", .lat = 7.5288655, .lon = -9.9576843, .population = 15214, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bopolu", .kind = "district", .county = "Gbarpolu", .lat = 7.2124741, .lon = -10.4304695, .population = 23758, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bokomu", .kind = "district", .county = "Gbarpolu", .lat = 7.2271791, .lon = -10.1921482, .population = 13684, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbarma", .kind = "district", .county = "Gbarpolu", .lat = 7.1997811, .lon = -10.6209482, .population = 13845, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kongba", .kind = "district", .county = "Gbarpolu", .lat = 7.7565739, .lon = -10.5022106, .population = 11508, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Commonwealth", .kind = "district", .county = "Grand Bassa", .lat = 5.8794456, .lon = -10.040905, .population = 35740, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "District #1", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 30223, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "District #2", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 32565, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "District #3", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 62421, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "District #4", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 41162, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Nekreen", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 62883, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "St. John River", .kind = "district", .county = "Grand Bassa", .lat = null, .lon = null, .population = 14723, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Commonwealth", .kind = "district", .county = "Grand Cape Mount", .lat = 6.6987053, .lon = -11.3081939, .population = 6547, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Garwula", .kind = "district", .county = "Grand Cape Mount", .lat = 6.7742591, .lon = -11.1017701, .population = 26936, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gola Konneh", .kind = "district", .county = "Grand Cape Mount", .lat = null, .lon = null, .population = 23518, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Porkpa", .kind = "district", .county = "Grand Cape Mount", .lat = 7.3107153, .lon = -11.0231105, .population = 42615, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tewor", .kind = "district", .county = "Grand Cape Mount", .lat = 6.9412573, .lon = -11.3502405, .population = 27460, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbarzon", .kind = "district", .county = "Grand Gedeh", .lat = 6.2267419, .lon = -8.4402587, .population = 74255, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Konobo", .kind = "district", .county = "Grand Gedeh", .lat = 5.8315731, .lon = -7.8597407, .population = 50161, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tchien", .kind = "district", .county = "Grand Gedeh", .lat = 6.0122573, .lon = -8.1033525, .population = 31976, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Barclayville", .kind = "district", .county = "Grand Kru", .lat = 4.7130757, .lon = -8.2011714, .population = 10904, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Bleebo", .kind = "district", .county = "Grand Kru", .lat = 4.7448941, .lon = -7.9538209, .population = 1809, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Bolloh", .kind = "district", .county = "Grand Kru", .lat = 4.9601292, .lon = -8.4126126, .population = 1891, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Buah", .kind = "district", .county = "Grand Kru", .lat = 4.8594024, .lon = -8.1731224, .population = 649, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Dorbor", .kind = "district", .county = "Grand Kru", .lat = 4.9911749, .lon = -8.27047, .population = 1935, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Dweh", .kind = "district", .county = "Grand Kru", .lat = 5.0725542, .lon = -8.0646997, .population = 935, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Felo-Jekwi", .kind = "district", .county = "Grand Kru", .lat = 4.7268088, .lon = -8.365412, .population = 2194, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Fenetoe", .kind = "district", .county = "Grand Kru", .lat = 4.9091773, .lon = -8.3661682, .population = 1742, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Forpoh", .kind = "district", .county = "Grand Kru", .lat = 5.1087783, .lon = -8.2363382, .population = 1088, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Garraway", .kind = "district", .county = "Grand Kru", .lat = 4.5510138, .lon = -7.9149967, .population = 9726, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Gee", .kind = "district", .county = "Grand Kru", .lat = 4.9360169, .lon = -8.1580761, .population = 2522, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Grand Cess Wedabo", .kind = "district", .county = "Grand Kru", .lat = 4.6420042, .lon = -8.1248099, .population = 10471, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Upper Jloh", .kind = "district", .county = "Grand Kru", .lat = 4.8280011, .lon = -8.4583137, .population = 1917, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Lower Jloh", .kind = "district", .county = "Grand Kru", .lat = 4.8742408, .lon = -8.5634454, .population = 1212, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Kpi", .kind = "district", .county = "Grand Kru", .lat = 4.9657282, .lon = -8.0859564, .population = 1603, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Nrokwia-Wesldow", .kind = "district", .county = "Grand Kru", .lat = 4.820544, .lon = -8.3272113, .population = 1878, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Penicess", .kind = "district", .county = "Grand Kru", .lat = null, .lon = null, .population = null, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Trenbo", .kind = "district", .county = "Grand Kru", .lat = 4.6639107, .lon = -7.9236422, .population = 3912, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Wlogba", .kind = "district", .county = "Grand Kru", .lat = 5.0858534, .lon = -8.1716393, .population = 688, .source = "Wikipedia Grand Kru County district table (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Foya", .kind = "district", .county = "Lofa", .lat = 8.3628727, .lon = -10.2123472, .population = 73312, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kolahun", .kind = "district", .county = "Lofa", .lat = 8.1339146, .lon = -10.2705461, .population = 59057, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Salayea", .kind = "district", .county = "Lofa", .lat = 7.4709749, .lon = -9.5579644, .population = 23578, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Vahun", .kind = "district", .county = "Lofa", .lat = 8.0386583, .lon = -10.4923932, .population = 17137, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Voinjama", .kind = "district", .county = "Lofa", .lat = 8.4196914, .lon = -9.750319, .population = 42790, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Quardu Gboni", .kind = "district", .county = "Lofa", .lat = 8.3763957, .lon = -9.6132923, .population = null, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Zorzor", .kind = "district", .county = "Lofa", .lat = 7.783536, .lon = -9.4251688, .population = 40704, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Firestone", .kind = "district", .county = "Margibi", .lat = 6.3815386, .lon = -10.3376877, .population = 61988, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gibi", .kind = "district", .county = "Margibi", .lat = 6.5610258, .lon = -10.0063647, .population = 14250, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kakata", .kind = "district", .county = "Margibi", .lat = 6.532326, .lon = -10.3488074, .population = 88704, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Mambah-Kaba", .kind = "district", .county = "Margibi", .lat = 6.2556079, .lon = -10.4959891, .population = 44981, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Barrobo", .kind = "district", .county = "Maryland", .lat = null, .lon = null, .population = null, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Pleebo/Sodeken", .kind = "district", .county = "Maryland", .lat = null, .lon = null, .population = null, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Careysburg", .kind = "district", .county = "Montserrado", .lat = 6.4023904, .lon = -10.5475407, .population = 29712, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Commonwealth", .kind = "district", .county = "Montserrado", .lat = 6.3922806, .lon = -10.6527597, .population = 11876, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Greater Monrovia", .kind = "district", .county = "Montserrado", .lat = null, .lon = null, .population = 970824, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "St. Paul River", .kind = "district", .county = "Montserrado", .lat = null, .lon = null, .population = 71831, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Todee", .kind = "district", .county = "Montserrado", .lat = 6.6316086, .lon = -10.5202639, .population = 33998, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Boe & Quilla", .kind = "district", .county = "Nimba", .lat = 6.7803706, .lon = -8.626804, .population = 18262, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Buu-Yao", .kind = "district", .county = "Nimba", .lat = 6.860866, .lon = -8.4121936, .population = 40007, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Doe", .kind = "district", .county = "Nimba", .lat = 6.6045767, .lon = -8.8454404, .population = 35918, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Garr Bain", .kind = "district", .county = "Nimba", .lat = 7.2190534, .lon = -8.9145297, .population = 61225, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbehlageh", .kind = "district", .county = "Nimba", .lat = null, .lon = null, .population = 32176, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbi & Doru", .kind = "district", .county = "Nimba", .lat = 6.1265785, .lon = -8.9731518, .population = 10131, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbor", .kind = "district", .county = "Nimba", .lat = 7.0963487, .lon = -8.7165279, .population = 99875, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kparblee", .kind = "district", .county = "Nimba", .lat = 6.6481121, .lon = -8.5199427, .population = 11424, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Leewehpea-Mahn", .kind = "district", .county = "Nimba", .lat = 7.0432451, .lon = -8.9051385, .population = 24747, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Meinpea-Mahn", .kind = "district", .county = "Nimba", .lat = 7.0094465, .lon = -9.0687153, .population = 24157, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sanniquellie-Mahn", .kind = "district", .county = "Nimba", .lat = 7.3826174, .lon = -8.7098957, .population = 25370, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Twan River", .kind = "district", .county = "Nimba", .lat = 7.0885911, .lon = -8.4351877, .population = 37479, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Wee-Gbehy-Mahn", .kind = "district", .county = "Nimba", .lat = null, .lon = null, .population = 32934, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Yarmein", .kind = "district", .county = "Nimba", .lat = 7.5189921, .lon = -8.6134972, .population = 22718, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Yarpea Mahn", .kind = "district", .county = "Nimba", .lat = 7.2365545, .lon = -8.6865441, .population = 21647, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Yarwein Mehnsonnoh", .kind = "district", .county = "Nimba", .lat = 6.5935307, .lon = -9.0866463, .population = 25584, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Zoe-Gbao", .kind = "district", .county = "Nimba", .lat = 6.9971277, .lon = -8.7034485, .population = 29372, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Chedepo", .kind = "district", .county = "River Gee", .lat = 5.4596539, .lon = -8.0546464, .population = 10518, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbeapo", .kind = "district", .county = "River Gee", .lat = 5.2486299, .lon = -7.9714607, .population = 10934, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Glaro", .kind = "district", .county = "River Gee", .lat = 5.394339, .lon = -7.5636966, .population = 4992, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Karforh", .kind = "district", .county = "River Gee", .lat = 5.2813053, .lon = -8.1666958, .population = 5956, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Nanee", .kind = "district", .county = "River Gee", .lat = 5.1546479, .lon = -8.1324114, .population = 6002, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Nyenawliken", .kind = "district", .county = "River Gee", .lat = 5.1285776, .lon = -7.9833973, .population = 5159, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Nyenebo", .kind = "district", .county = "River Gee", .lat = 4.8986473, .lon = -7.7210662, .population = 5703, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Potupo", .kind = "district", .county = "River Gee", .lat = 5.3355952, .lon = -7.8178974, .population = 7337, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sarbo", .kind = "district", .county = "River Gee", .lat = 5.1690749, .lon = -7.6345574, .population = 5320, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tuobo", .kind = "district", .county = "River Gee", .lat = 5.014152, .lon = -7.6944069, .population = 4868, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Webbo", .kind = "district", .county = "River Gee", .lat = null, .lon = null, .population = null, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bearwor", .kind = "district", .county = "Rivercess", .lat = null, .lon = null, .population = 3854, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Central RiverCess", .kind = "district", .county = "Rivercess", .lat = 5.8011565, .lon = -9.3061455, .population = 8303, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Doedain", .kind = "district", .county = "Rivercess", .lat = 6.2624284, .lon = -9.2362364, .population = 13041, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Fen River", .kind = "district", .county = "Rivercess", .lat = 5.6051859, .lon = -9.6532269, .population = 12630, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Jo River", .kind = "district", .county = "Rivercess", .lat = 6.0352834, .lon = -9.4616816, .population = 8921, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Norwein", .kind = "district", .county = "Rivercess", .lat = 5.8391998, .lon = -9.588869, .population = 13900, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sam Gbalor", .kind = "district", .county = "Rivercess", .lat = 5.3836333, .lon = -9.4110329, .population = 3714, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Zartlahn", .kind = "district", .county = "Rivercess", .lat = null, .lon = null, .population = 7146, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bodae", .kind = "district", .county = "Sinoe", .lat = 5.139931, .lon = -8.3402696, .population = 3030, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bokon", .kind = "district", .county = "Sinoe", .lat = 5.0363602, .lon = -8.4522819, .population = 4417, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Butaw", .kind = "district", .county = "Sinoe", .lat = 5.1328123, .lon = -9.0723712, .population = 3892, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Dugbe River", .kind = "district", .county = "Sinoe", .lat = 4.9805796, .lon = -8.6773428, .population = 9083, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Greenville", .kind = "district", .county = "Sinoe", .lat = 5.045585, .lon = -9.0418921, .population = 16434, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Jaedae", .kind = "district", .county = "Sinoe", .lat = 5.0859099, .lon = -8.5219326, .population = 3617, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Jaedepo", .kind = "district", .county = "Sinoe", .lat = null, .lon = null, .population = 8596, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Juarzon", .kind = "district", .county = "Sinoe", .lat = 5.3120667, .lon = -8.9200358, .population = 6151, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kpayan", .kind = "district", .county = "Sinoe", .lat = 5.1053353, .lon = -8.8496798, .population = 10043, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kulu Shaw Boe", .kind = "district", .county = "Sinoe", .lat = 5.5660939, .lon = -8.9726902, .population = 8555, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Plahn Nyarn", .kind = "district", .county = "Sinoe", .lat = 5.3229571, .lon = -9.0348658, .population = 6805, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Pynes Town", .kind = "district", .county = "Sinoe", .lat = null, .lon = null, .population = 4167, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sanquin District 1", .kind = "district", .county = "Sinoe", .lat = 5.6522065, .lon = -8.4238171, .population = 2118, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sanquin District 2", .kind = "district", .county = "Sinoe", .lat = 5.6522065, .lon = -8.4238171, .population = 3405, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sanquin District 3", .kind = "district", .county = "Sinoe", .lat = 5.6522065, .lon = -8.4238171, .population = 3174, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Seekon", .kind = "district", .county = "Sinoe", .lat = 5.6349268, .lon = -8.7024456, .population = 7184, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Wedjah", .kind = "district", .county = "Sinoe", .lat = 5.2933222, .lon = -8.792884, .population = 1076, .source = "Wikipedia Districts of Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Monrovia", .kind = "city", .county = "Montserrado", .lat = 6.3203562, .lon = -10.8060492, .population = 1021762, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbarnga", .kind = "city", .county = "Bong", .lat = 6.996269, .lon = -9.470905, .population = 56986, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Buchanan", .kind = "city", .county = "Grand Bassa", .lat = 5.88129, .lon = -10.0494002, .population = 50245, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Ganta", .kind = "city", .county = "Nimba", .lat = 7.2334773, .lon = -8.986099, .population = 42077, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Kakata", .kind = "city", .county = "Margibi", .lat = 6.532326, .lon = -10.3488074, .population = 34608, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Zwedru", .kind = "city", .county = "Grand Gedeh", .lat = 6.068724, .lon = -8.1342735, .population = 25349, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Harbel", .kind = "city", .county = "Margibi", .lat = 6.271283, .lon = -10.3492823, .population = 25309, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Harper", .kind = "city", .county = "Maryland", .lat = 4.3789381, .lon = -7.7060988, .population = 23517, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Pleebo", .kind = "city", .county = "Maryland", .lat = 4.5888482, .lon = -7.6734903, .population = 23464, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Foya", .kind = "city", .county = "Lofa", .lat = 8.3586488, .lon = -10.1960454, .population = 20569, .source = "Wikipedia List of cities in Liberia (2008 census); coordinates OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Sinkor", .kind = "neighborhood", .county = "Montserrado", .lat = 6.2913558, .lon = -10.7773153, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Congo Town", .kind = "neighborhood", .county = "Montserrado", .lat = 6.26866, .lon = -10.73326, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Mamba Point", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3117265, .lon = -10.8147204, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Lakpazee", .kind = "neighborhood", .county = "Montserrado", .lat = 6.2916511, .lon = -10.7607777, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Old Road", .kind = "neighborhood", .county = "Montserrado", .lat = 6.2816699, .lon = -10.756076, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gardnersville", .kind = "neighborhood", .county = "Montserrado", .lat = 6.33667, .lon = -10.73833, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "New Kru Town", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3715088, .lon = -10.7903318, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "West Point", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3272666, .lon = -10.8058947, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Clara Town", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3287723, .lon = -10.7971286, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Bushrod Island", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3439696, .lon = -10.7864484, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Caldwell", .kind = "neighborhood", .county = "Montserrado", .lat = 6.392222, .lon = -10.734167, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Barnersville", .kind = "neighborhood", .county = "Montserrado", .lat = 6.3666838, .lon = -10.73333, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Virginia", .kind = "community", .county = "Montserrado", .lat = 6.4164317, .lon = -10.768026, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Brewerville", .kind = "community", .county = "Montserrado", .lat = 6.4233315, .lon = -10.7838865, .population = null, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
};

pub const facilities: []const knowledge.FacilityRow = &.{
        .{ .name = "Redemption Hospital", .kind = "hospital", .county = "Montserrado", .city = "Monrovia", .lat = 6.3697396, .lon = -10.7920041, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "ELWA Hospital", .kind = "hospital", .county = "Montserrado", .city = "Paynesville", .lat = 6.2400457, .lon = -10.6955319, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Phebe Hospital", .kind = "hospital", .county = "Bong", .city = "Suakoko", .lat = 7.0279488, .lon = -9.5532291, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Jackson F. Doe Hospital", .kind = "hospital", .county = "Nimba", .city = "Tappita", .lat = 6.5082925, .lon = -8.860278, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Ganta United Methodist Hospital", .kind = "hospital", .county = "Nimba", .city = "Ganta", .lat = 7.2384452, .lon = -8.9762494, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "St. Joseph's Catholic Hospital", .kind = "hospital", .county = "Montserrado", .city = "Monrovia", .lat = 6.2730183, .lon = -10.7554187, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Curran Lutheran Hospital", .kind = "hospital", .county = "Lofa", .city = "Zorzor", .lat = 7.7752051, .lon = -9.4326659, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "St. Timothy Hospital", .kind = "hospital", .county = "Grand Cape Mount", .city = "Robertsport", .lat = 6.7502178, .lon = -11.3674753, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "John F. Kennedy Medical Center", .kind = "hospital", .county = "Montserrado", .city = "Monrovia", .lat = 6.2871673, .lon = -10.773681, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Lott Carey School Clinic", .kind = "clinic", .county = "Montserrado", .city = "Monrovia", .lat = 6.4175663, .lon = -10.7877694, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-13" },
        .{ .name = "Duala Market", .kind = "market", .county = "Montserrado", .city = "Monrovia", .lat = 6.3724419, .lon = -10.7876196, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Waterside Market", .kind = "market", .county = "Montserrado", .city = "Monrovia", .lat = 6.3712169, .lon = -10.7879767, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Red Light Market", .kind = "market", .county = "Montserrado", .city = "Paynesville", .lat = 6.2849705, .lon = -10.6906518, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "University of Liberia", .kind = "university", .county = "Montserrado", .city = "Monrovia", .lat = 6.3001015, .lon = -10.7943491, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Cuttington University", .kind = "university", .county = "Bong", .city = "Suakoko", .lat = 7.0421089, .lon = -9.5518658, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Tubman University", .kind = "university", .county = "Maryland", .city = "Harper", .lat = 4.401675, .lon = -7.6934854, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "African Methodist Episcopal University", .kind = "university", .county = "Montserrado", .city = "Monrovia", .lat = 6.3105784, .lon = -10.8012554, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Stella Maris Polytechnic", .kind = "university", .county = "Montserrado", .city = "Monrovia", .lat = 6.2971064, .lon = -10.7942566, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Booker Washington Institute", .kind = "institute", .county = "Margibi", .city = "Kakata", .lat = 6.5301953, .lon = -10.3634308, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Ricks Institute", .kind = "school", .county = "Montserrado", .city = "Virginia", .lat = 6.4723006, .lon = -10.8014742, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "William V.S. Tubman High School", .kind = "school", .county = "Montserrado", .city = "Monrovia", .lat = 6.2974876, .lon = -10.7808947, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "Gbarnga Lutheran Mission School", .kind = "school", .county = "Bong", .city = "Gbarnga", .lat = 7.0192079, .lon = -9.5065635, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
        .{ .name = "FrontPage Africa", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://frontpageafricaonline.com/", .verified_at = "2026-11-12" },
        .{ .name = "GNN Liberia", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://gnnliberia.com/", .verified_at = "2026-11-12" },
        .{ .name = "Liberian Investigator", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://liberianinvestigator.com/", .verified_at = "2026-11-12" },
        .{ .name = "New Dawn", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://thenewdawnliberia.com/", .verified_at = "2026-11-12" },
        .{ .name = "Bush Chicken", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://www.bushchicken.com/", .verified_at = "2026-11-12" },
        .{ .name = "Daily Observer", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://www.liberianobserver.com/", .verified_at = "2026-11-12" },
        .{ .name = "OK FM", .kind = "media", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://okfm.com.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Finance and Development Planning", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mfdp.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Health", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://moh.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Education", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://moe.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Foreign Affairs", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mofa.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Internal Affairs", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mia.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Agriculture", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://moa.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Commerce and Industry", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://moci.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Public Works", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mpw.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Transport", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mot.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Gender, Children and Social Protection", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://mogcsp.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Information, Cultural Affairs and Tourism", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://micat.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Liberia Revenue Authority", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://revenue.lra.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Liberia Institute of Statistics and Geo-Information Services", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://lisgis.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Central Bank of Liberia", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://cbl.org.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Liberia National Police", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://lnp.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "Ministry of Justice", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 200): https://moj.gov.lr/", .verified_at = "2026-11-12" },
        .{ .name = "National Elections Commission", .kind = "government", .county = null, .city = null, .lat = null, .lon = null, .source = "Official homepage (HTTP 403 bot-block, domain live): https://necliberia.org/", .verified_at = "2026-11-12" },
        .{ .name = "Monrovia - Kakata Highway", .kind = "road", .county = "Montserrado", .city = "Monrovia", .lat = 6.3247263, .lon = -10.6626793, .source = "OpenStreetMap Nominatim", .verified_at = "2026-11-12" },
};

pub const statistics: []const knowledge.StatisticRow = &.{
        .{ .key = "liberia_population_1984", .value = 2101628, .unit = "people", .period = "1984", .source = "Wikipedia Demographics of Liberia, citing Liberian censuses (1984-2022)", .verified_at = "2026-11-12" },
        .{ .key = "liberia_population_2008", .value = 3476608, .unit = "people", .period = "2008", .source = "Wikipedia Demographics of Liberia, citing Liberian censuses (1984-2022)", .verified_at = "2026-11-12" },
        .{ .key = "liberia_population_2022", .value = 5250187, .unit = "people", .period = "2022", .source = "Wikipedia Demographics of Liberia, citing Liberian censuses (1984-2022)", .verified_at = "2026-11-12" },
        .{ .key = "liberia_population_2024_estimate", .value = 5437249, .unit = "people", .period = "2024 estimate", .source = "Wikipedia Liberia (infobox, 2024 estimate)", .verified_at = "2026-11-12" },
        .{ .key = "montserrado_population_2008", .value = 1144806, .unit = "people", .period = "2008", .source = "Wikipedia Liberia (Montserrado, most populous county, 2008 census)", .verified_at = "2026-11-12" },
};

/// Seed the knowledge store. Idempotent: run it twice and the
/// counts are unchanged. Returns how many rows were upserted.
pub fn seed(alloc: std.mem.Allocator, ks: knowledge.KnowledgeStore) !SeedReport {
    var report = SeedReport{};
    for (locations) |row| {
        try ks.upsertLocation(alloc, row);
        report.locations += 1;
    }
    for (facilities) |row| {
        try ks.upsertFacility(alloc, row);
        report.facilities += 1;
    }
    for (statistics) |row| {
        try ks.upsertStatistic(alloc, row);
        report.statistics += 1;
    }
    return report;
}

test "seed: counts and provenance are complete and idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mk = knowledge.MemoryKnowledge.init(alloc);
    defer mk.deinit();
    const ks = mk.asKnowledge();
    const r1 = try seed(alloc, ks);
    try std.testing.expectEqual(@as(usize, 166), r1.locations);
    try std.testing.expectEqual(@as(usize, 47), r1.facilities);
    try std.testing.expectEqual(@as(usize, 5), r1.statistics);
    const r2 = try seed(alloc, ks);
    try std.testing.expectEqual(r1, r2);
    const c = ks.counts();
    try std.testing.expectEqual(@as(usize, 166), c.locations);
    try std.testing.expectEqual(@as(usize, 47), c.facilities);
    try std.testing.expectEqual(@as(usize, 5), c.statistics);
    // Every location row has a source and a verification date.
    // The seed spans two verification dates: the original
    // 2026-11-12 pass and the Roadmap 7.6 gapfill (2026-11-13).
    for (locations) |row| {
        try std.testing.expect(row.source.len > 0);
        const d = row.verified_at orelse return error.TestExpectedEqual;
        try std.testing.expect(std.mem.eql(u8, d, verification_date) or std.mem.eql(u8, d, "2026-11-13"));
    }
    for (facilities) |row| {
        try std.testing.expect(row.source.len > 0);
        const d = row.verified_at orelse return error.TestExpectedEqual;
        try std.testing.expect(std.mem.eql(u8, d, verification_date) or std.mem.eql(u8, d, "2026-11-13"));
    }
    // Spot checks: the capital, the largest city, a district.
    const cities = try ks.listLocations(alloc, "city", 20);
    var found_monrovia = false;
    for (cities) |l| {
        if (std.mem.eql(u8, l.name, "Monrovia")) {
            found_monrovia = true;
            try std.testing.expectEqual(@as(?i64, 1021762), l.population);
            try std.testing.expect(l.lat != null and l.lon != null);
        }
    }
    try std.testing.expect(found_monrovia);
    const dists = try ks.listLocations(alloc, "district", 200);
    try std.testing.expectEqual(@as(usize, 127), dists.len);
    // Roadmap 7.6 gapfill: Grand Kru 2008 populations from the
    // Wikipedia Grand Kru County district table, verified live
    // 2026-11-13. Penicess has no published 2008 population in
    // that source and stays null — never invented.
    for (dists) |d| {
        if (std.mem.eql(u8, d.name, "Barclayville")) {
            try std.testing.expectEqual(@as(?i64, 10904), d.population);
            try std.testing.expectEqualStrings("2026-11-13", d.verified_at.?);
        }
        if (std.mem.eql(u8, d.name, "Penicess")) {
            try std.testing.expect(d.population == null);
        }
    }
    const facs = try ks.listFacilities(alloc, null, 100);
    var found_clinic = false;
    for (facs) |f| {
        if (std.mem.eql(u8, f.name, "Lott Carey School Clinic")) {
            found_clinic = true;
            try std.testing.expectEqualStrings("clinic", f.kind);
            try std.testing.expect(f.lat != null and f.lon != null);
        }
    }
    try std.testing.expect(found_clinic);
    const st = try ks.listStatistics(alloc);
    var found_2022 = false;
    for (st) |s| {
        if (std.mem.eql(u8, s.key, "liberia_population_2022")) {
            found_2022 = true;
            try std.testing.expectEqual(@as(f64, 5250187), s.value);
        }
    }
    try std.testing.expect(found_2022);
}

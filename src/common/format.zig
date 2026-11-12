//! Small formatting helpers.
//!
//! Zig 0.17.1 toolchain quirk (verified empirically): any width/alignment
//! spec on a SIGNED integer prints an explicit `+` for non-negative values
//! (`{d:04}` on i64 2026 renders `+2026`; `{d}` renders `2026`). So
//! zero-padded numbers are built by hand here instead of with fmt widths.

const std = @import("std");

/// Write `v` as decimal, left-padded with `0` to at least `width` digits.
/// `v` must be non-negative (dates/times are). Never emits a sign.
pub fn writeZeroPadded(w: *std.Io.Writer, v: i64, width: usize) !void {
    std.debug.assert(v >= 0);
    var tmp: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{v});
    var i: usize = s.len;
    while (i < width) : (i += 1) try w.writeByte('0');
    try w.writeAll(s);
}

test "writeZeroPadded pads without a sign" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeZeroPadded(&w, 2026, 4);
    try w.writeByte('-');
    try writeZeroPadded(&w, 5, 2);
    try w.writeByte('-');
    try writeZeroPadded(&w, 0, 2);
    try std.testing.expectEqualStrings("2026-05-00", w.buffered());
}

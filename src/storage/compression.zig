//! Zstandard compression (Roadmap 3.5).
//!
//! Zig std has no zstd, so this module binds libzstd through `@extern`
//! declarations (Zig 0.17.1 removed `@cImport` — there is no C-import
//! builtin in this toolchain; the bindings below are the plain C API).
//! The library is the system libzstd.so.1.5.5 (the Hatch runtime lib —
//! never downgraded, never replaced); only the -dev headers + the .so
//! symlink were installed, via `apt-get download libzstd-dev` +
//! `dpkg-deb -x` (the package cannot be apt-installed: it demands
//! libzstd1 exactly 1.5.5+dfsg2-2build1.1, the image ships
//! 1.5.5+dfsg2-2build1.1+hatch1). The headers/symlink live outside the
//! home directory and are wiped by VM restarts — if `zig build` fails
//! to find libzstd, re-apply the workaround (see STATUS.md, Roadmap
//! 3.5). Note: only the LINK matters here (no headers are read by the
//! Zig build — the API is declared below); the .so symlink is what
//! the linker needs.
//!
//! Uses: compressed source archives (the pipeline stores raw feeds
//! as .zst objects), and any future compressed store. Level 3 is
//! zstd's default — a good balance for text feeds.

const std = @import("std");

// libzstd C API (zstd.h, 1.5.5). Declared by hand: @cImport does not
// exist in Zig 0.17.1.
extern fn ZSTD_compress(dst: ?*anyopaque, dstCapacity: usize, src: ?*const anyopaque, srcSize: usize, compressionLevel: c_int) usize;
extern fn ZSTD_decompress(dst: ?*anyopaque, dstCapacity: usize, src: ?*const anyopaque, srcSize: usize) usize;
extern fn ZSTD_compressBound(srcSize: usize) usize;
extern fn ZSTD_getFrameContentSize(src: ?*const anyopaque, srcSize: usize) c_ulonglong;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_versionString() [*:0]const u8;

const contentsize_unknown: c_ulonglong = 0xFFFFFFFFFFFFFFFF;
const contentsize_error: c_ulonglong = 0xFFFFFFFFFFFFFFFE;

/// First four bytes of a zstd frame, little-endian.
pub const frame_magic: u32 = 0xFD2FB528;
pub const default_level: i32 = 3;
pub const max_level: i32 = 22;

pub fn isZstd(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.readInt(u32, data[0..4], .little) == frame_magic;
}

/// Upper bound on the compressed size of `data.len` bytes.
pub fn compressBound(data_len: usize) usize {
    return ZSTD_compressBound(data_len);
}

/// Compress `data` at `level` (1..22; 0 means zstd's default 3).
/// The caller owns the returned slice (exactly the compressed size).
pub fn compress(alloc: std.mem.Allocator, data: []const u8, level: i32) ![]u8 {
    const bound = ZSTD_compressBound(data.len);
    const out = try alloc.alloc(u8, bound);
    defer alloc.free(out);
    const lvl: c_int = @intCast(@max(1, @min(max_level, if (level == 0) default_level else level)));
    const n = ZSTD_compress(out.ptr, bound, data.ptr, data.len, lvl);
    if (ZSTD_isError(n) != 0) return error.ZstdCompressFailed;
    const exact = try alloc.alloc(u8, n);
    @memcpy(exact, out[0..n]);
    return exact;
}

/// Decompress `data` when the original size is known.
pub fn decompress(alloc: std.mem.Allocator, data: []const u8, original_size: usize) ![]u8 {
    const out = try alloc.alloc(u8, original_size);
    errdefer alloc.free(out);
    const n = ZSTD_decompress(out.ptr, original_size, data.ptr, data.len);
    if (ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    if (n != original_size) return error.ZstdSizeMismatch;
    return out;
}

/// Decompress `data`, reading the original size from the frame
/// header when present. Frames without a content size (streamed
/// frames) fall back to a doubling probe, capped at 256 MiB — Pulse
/// only writes frames with a known size, so the probe is a safety
/// net, not the normal path.
pub fn decompressFrame(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = ZSTD_getFrameContentSize(data.ptr, data.len);
    if (size == contentsize_error) return error.ZstdBadFrame;
    if (size != contentsize_unknown) return decompress(alloc, data, @intCast(size));
    var cap: usize = 1 << 20;
    while (cap <= 256 << 20) : (cap *= 2) {
        const out = try alloc.alloc(u8, cap);
        const n = ZSTD_decompress(out.ptr, cap, data.ptr, data.len);
        if (ZSTD_isError(n) == 0) {
            const exact = try alloc.alloc(u8, n);
            @memcpy(exact, out[0..n]);
            alloc.free(out);
            return exact;
        }
        alloc.free(out);
    }
    return error.ZstdDecompressFailed;
}

/// Zstd version linked at build time (e.g. "1.5.5").
pub fn version() []const u8 {
    return std.mem.sliceTo(ZSTD_versionString(), 0);
}

test "compression round-trips text; magic + version check" {
    const alloc = std.testing.allocator;
    const sentence = "Fuel shortage hits Monrovia. ";
    var text_buf: [sentence.len * 20]u8 = undefined;
    for (0..20) |i| @memcpy(text_buf[i * sentence.len ..][0..sentence.len], sentence);
    const text = &text_buf;
    const compressed = try compress(alloc, text, 3);
    defer alloc.free(compressed);
    try std.testing.expect(isZstd(compressed));
    try std.testing.expect(compressed.len < text.len);
    const back = try decompressFrame(alloc, compressed);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(text, back);
    const sized = try decompress(alloc, compressed, text.len);
    defer alloc.free(sized);
    try std.testing.expectEqualStrings(text, sized);
    try std.testing.expect(!isZstd(text));
    try std.testing.expect(!isZstd(""));
    try std.testing.expectEqualStrings("1.5.5", version());
    // A truncated frame fails cleanly instead of returning garbage.
    try std.testing.expectError(error.ZstdDecompressFailed, decompressFrame(alloc, compressed[0..10]));
}

test "compression level clamps; empty input round-trips" {
    const alloc = std.testing.allocator;
    const c1 = try compress(alloc, "abc", 99);
    defer alloc.free(c1);
    const b1 = try decompressFrame(alloc, c1);
    defer alloc.free(b1);
    try std.testing.expectEqualStrings("abc", b1);
    const ce = try compress(alloc, "", 3);
    defer alloc.free(ce);
    const be = try decompressFrame(alloc, ce);
    defer alloc.free(be);
    try std.testing.expectEqual(@as(usize, 0), be.len);
}

//! Minimal S3 client for the MinIO raw archive (Roadmap 1.4).
//! Supports PUT and GET with AWS Signature Version 4 (HMAC-SHA256 chain).
//! The client is optional: when no endpoint is configured, the pipeline
//! skips archiving and logs a warning instead of failing ingestion.

const std = @import("std");
const logging = @import("../common/logging.zig");
const timex = @import("../common/time.zig");
const format = @import("../common/format.zig");

pub const S3Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    bucket: []const u8,
    region: []const u8 = "us-east-1",

    /// Returns null when no endpoint is configured (archiving disabled).
    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        endpoint: ?[]const u8,
        access_key: ?[]const u8,
        secret_key: ?[]const u8,
        bucket: []const u8,
    ) ?S3Client {
        const ep = endpoint orelse return null;
        const ak = access_key orelse return null;
        const sk = secret_key orelse return null;
        if (ep.len == 0 or ak.len == 0 or sk.len == 0) return null;
        return .{
            .alloc = alloc,
            .io = io,
            .endpoint = ep,
            .access_key = ak,
            .secret_key = sk,
            .bucket = bucket,
        };
    }

    fn hmac(key: []const u8, data: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
        return out;
    }

    fn sha256Hex(data: []const u8) [64]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn amzDate(alloc: std.mem.Allocator, now_unix: i64) !struct { date: []u8, datetime: []u8 } {
        // YYYYMMDD and YYYYMMDDTHHMMSSZ from unix seconds (UTC).
        const days = @divFloor(now_unix, 86400);
        const secs = @mod(now_unix, 86400);
        const z = days + 719468;
        const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = if (mp < 10) mp + 3 else mp - 9;
        const year = if (m <= 2) y + 1 else y;
        const hh = @divFloor(secs, 3600);
        const mm = @divFloor(@mod(secs, 3600), 60);
        const ss = @mod(secs, 60);
        var dbuf: [8]u8 = undefined;
        var dw: std.Io.Writer = .fixed(&dbuf);
        try format.writeZeroPadded(&dw, year, 4);
        try format.writeZeroPadded(&dw, m, 2);
        try format.writeZeroPadded(&dw, d, 2);
        const date = try alloc.dupe(u8, dw.buffered());
        var tbuf: [20]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tbuf);
        try tw.writeAll(date);
        try tw.writeByte('T');
        try format.writeZeroPadded(&tw, hh, 2);
        try format.writeZeroPadded(&tw, mm, 2);
        try format.writeZeroPadded(&tw, ss, 2);
        try tw.writeByte('Z');
        const datetime = try alloc.dupe(u8, tw.buffered());
        return .{ .date = date, .datetime = datetime };
    }

    fn hostOf(endpoint: []const u8) []const u8 {
        var h = endpoint;
        if (std.mem.startsWith(u8, h, "http://")) h = h["http://".len..];
        if (std.mem.startsWith(u8, h, "https://")) h = h["https://".len..];
        if (std.mem.indexOfScalar(u8, h, '/')) |i| h = h[0..i];
        return h;
    }

    /// Build the SigV4 Authorization header value for a request.
    /// Exposed for tests (canonical-request construction is the risky part).
    pub fn sign(
        self: *const S3Client,
        alloc: std.mem.Allocator,
        method: []const u8,
        uri_path: []const u8,
        payload_hash_hex: [64]u8,
        now_unix: i64,
    ) ![]u8 {
        const dates = try amzDate(alloc, now_unix);
        const host = hostOf(self.endpoint);
        const canonical = try std.fmt.allocPrint(alloc,
            "{s}\n{s}\n\n" ++
                "host:{s}\n" ++
                "x-amz-content-sha256:{s}\n" ++
                "x-amz-date:{s}\n" ++
                "\n" ++
                "host;x-amz-content-sha256;x-amz-date\n" ++
                "{s}",
            .{ method, uri_path, host, payload_hash_hex, dates.datetime, payload_hash_hex });
        const canonical_hash = sha256Hex(canonical);
        const scope = try std.fmt.allocPrint(alloc, "{s}/{s}/s3/aws4_request", .{ dates.date, self.region });
        const string_to_sign = try std.fmt.allocPrint(alloc, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
            dates.datetime,
            scope,
            canonical_hash,
        });
        const k_date = hmac(try std.fmt.allocPrint(alloc, "AWS4{s}", .{self.secret_key}), dates.date);
        const k_region = hmac(&k_date, self.region);
        const k_service = hmac(&k_region, "s3");
        const k_signing = hmac(&k_service, "aws4_request");
        const sig = hmac(&k_signing, string_to_sign);
        const sig_hex = std.fmt.bytesToHex(sig, .lower);
        return std.fmt.allocPrint(alloc,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
            .{ self.access_key, scope, sig_hex });
    }

    fn objectUrl(self: *const S3Client, alloc: std.mem.Allocator, key: []const u8) ![]u8 {
        const base = std.mem.trimEnd(u8, self.endpoint, "/");
        return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, self.bucket, key });
    }

    pub fn putObject(self: *S3Client, key: []const u8, body: []const u8, content_type: []const u8) !void {
        const now = timex.nowSeconds(self.io);
        const payload_hash = sha256Hex(body);
        const uri_path = try std.fmt.allocPrint(self.alloc, "/{s}/{s}", .{ self.bucket, key });
        const auth = try self.sign(self.alloc, "PUT", uri_path, payload_hash, now);
        const dates = try amzDate(self.alloc, now);
        const url = try self.objectUrl(self.alloc, key);
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .PUT,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "x-amz-date", .value = dates.datetime },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
                .{ .name = "content-type", .value = content_type },
            },
        }) catch |e| {
            logging.warn("minio put failed", &.{ .{ .key = "key", .value = key }, .{ .key = "error", .value = @errorName(e) } });
            return error.StorageUnavailable;
        };
        if (result.status != .ok and result.status != .created and result.status != .no_content) {
            logging.warn("minio put non-2xx", &.{ .{ .key = "key", .value = key }, .{ .key = "status", .value = @tagName(result.status) } });
            return error.StorageUnavailable;
        }
    }

    pub fn getObject(self: *S3Client, alloc: std.mem.Allocator, key: []const u8) ![]u8 {
        const now = timex.nowSeconds(self.io);
        const payload_hash = sha256Hex("");
        const uri_path = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.bucket, key });
        const auth = try self.sign(alloc, "GET", uri_path, payload_hash, now);
        const dates = try amzDate(alloc, now);
        const url = try self.objectUrl(alloc, key);
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        defer body.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "x-amz-date", .value = dates.datetime },
                .{ .name = "x-amz-content-sha256", .value = &payload_hash },
            },
            .response_writer = &body.writer,
        }) catch return error.StorageUnavailable;
        if (result.status != .ok) return error.StorageUnavailable;
        return body.toOwnedSlice();
    }
};

test "hmac-sha256 matches RFC 4231 test case 1" {
    var key: [20]u8 = undefined;
    @memset(&key, 0x0b);
    const got = S3Client.hmac(&key, "Hi There");
    const expected = [_]u8{ 0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b, 0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7, 0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7 };
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "sign is deterministic and payload-sensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const c = S3Client{
        .alloc = alloc,
        .io = undefined,
        .endpoint = "http://minio:9000",
        .access_key = "AKIDEXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        .bucket = "pulse-raw",
    };
    const h1 = S3Client.sha256Hex("hello");
    const a1 = try c.sign(alloc, "PUT", "/pulse-raw/raw/x.xml", h1, 1369353600);
    const a2 = try c.sign(alloc, "PUT", "/pulse-raw/raw/x.xml", h1, 1369353600);
    try std.testing.expectEqualStrings(a1, a2);
    try std.testing.expect(std.mem.startsWith(u8, a1, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="));
    const h2 = S3Client.sha256Hex("different");
    const a3 = try c.sign(alloc, "PUT", "/pulse-raw/raw/x.xml", h2, 1369353600);
    try std.testing.expect(!std.mem.eql(u8, a1, a3));
}

test "init returns null without endpoint or keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(S3Client.init(arena.allocator(), undefined, null, null, null, "pulse-raw") == null);
    try std.testing.expect(S3Client.init(arena.allocator(), undefined, "http://minio:9000", null, null, "pulse-raw") == null);
}

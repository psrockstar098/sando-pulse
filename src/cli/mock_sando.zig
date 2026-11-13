//! Mock Sando (Roadmap 5.2): `pulse mock-sando "<question>"`.
//!
//! A stand-in for Sando's side of the integration: it asks Pulse one
//! question through the reference client and prints the typed answer
//! (sufficient, confidence, answer text, citations) — the same shape
//! Sando renders. Use it for end-to-end tests of a live Pulse server
//! without the real Sando app.
//!
//! Exit codes: 0 = sufficient answer; 2 = valid insufficient answer
//! (Pulse has no evidence — the refusal is the correct behaviour);
//! 1 = Pulse unavailable / bad key / quota / bad response.
//!
//! Flags: --county <name> --language <code> --pulse-url <url>
//! --api-key <key> --consumer <name>. The API key defaults to
//! PULSE_API_KEY from the environment; omit it entirely in open dev
//! mode. The Pulse URL defaults to PULSE_URL or
//! http://127.0.0.1:9000.

const std = @import("std");
const config = @import("../config/config.zig");
const client = @import("../sando/client.zig");
const logging = @import("../common/logging.zig");

pub fn run(alloc: std.mem.Allocator, io: std.Io, cfg: config.Config, args: []const []const u8) u8 {
    const question = args[0];
    var county: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var pulse_url: []const u8 = cfg.pulse_url;
    var api_key: ?[]const u8 = cfg.api_key;
    var consumer: []const u8 = client.default_consumer;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--county") and i + 1 < args.len) {
            county = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--language") and i + 1 < args.len) {
            language = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--pulse-url") and i + 1 < args.len) {
            pulse_url = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--api-key") and i + 1 < args.len) {
            api_key = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--consumer") and i + 1 < args.len) {
            consumer = args[i + 1];
            i += 1;
        } else {
            logging.err("mock-sando: unknown flag (mock-sando \"<question>\" [--county <name>] [--language <code>] [--pulse-url <url>] [--api-key <key>] [--consumer <name>])", &.{});
            return 2;
        }
    }

    var c = client.Client{
        .alloc = alloc,
        .io = io,
        .base_url = pulse_url,
        .api_key = api_key,
        .consumer = consumer,
    };
    const ans = c.ask(alloc, question, .{ .county = county, .language = language }) catch |e| {
        switch (e) {
            error.Unauthorized => logging.err("mock-sando: Pulse rejected the API key (401)", &.{}),
            error.QuotaExceeded => logging.err("mock-sando: daily quota exceeded (429)", &.{}),
            error.InvalidQuestion => logging.err("mock-sando: question must be 1-1000 chars", &.{}),
            error.BadResponse => logging.err("mock-sando: Pulse answered with an unparseable body", &.{}),
            error.PulseUnavailable => logging.err("mock-sando: Pulse unavailable after retries — is the server running?", &.{}),
            error.OutOfMemory => logging.err("mock-sando: out of memory", &.{}),
        }
        return 1;
    };

    std.debug.print("sufficient: {}\nconfidence: {d:.2}\n", .{ ans.sufficient, ans.confidence });
    if (ans.answer) |a| {
        std.debug.print("answer: {s}\n", .{a});
    }
    if (ans.insufficient_reason) |r| {
        std.debug.print("insufficient_reason: {s}\n", .{r});
    }
    std.debug.print("citations: {d}\n", .{ans.citations.len});
    for (ans.citations) |cit| {
        std.debug.print("  - {s} [{s}] {s}\n", .{ cit.title, cit.source_name, cit.url });
    }
    return if (ans.sufficient) 0 else 2;
}

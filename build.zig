const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "pulse",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run pulse (pass CLI args after --)");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: one test binary per module that carries tests.
    const test_files = [_][]const u8{
        "src/common/types.zig",
        "src/common/logging.zig",
        "src/config/config.zig",
        "src/engine/planner.zig",
        "src/engine/entities.zig",
        "src/engine/ranking.zig",
        "src/engine/search.zig",
        "src/ingestion/rss.zig",
        "src/ingestion/sources.zig",
        "src/ingestion/normalizer.zig",
        "src/storage/memory.zig",
        "src/storage/postgres.zig",
        "src/storage/redis.zig",
        "src/storage/object_store.zig",
        "src/api/auth.zig",
        "src/api/ratelimit.zig",
        "src/api/metrics.zig",
    };
    const test_step = b.step("test", "Run all unit tests");
    for (test_files) |f| {
        const mod = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}

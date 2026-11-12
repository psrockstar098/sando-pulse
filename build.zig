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
    // NOTE: Zig 0.17.1's std.Build has no `b.args` passthrough, so
    // `zig build run` always runs the default command (serve). Pass CLI
    // args by running the built binary directly: ./zig-out/bin/pulse <cmd>.
    const run_step = b.step("run", "Run pulse (default: serve)");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: one test binary rooted at src/root.zig, which re-exports
    // every module. (Per-file `zig test` fails in Zig 0.17.1 for files that
    // import outside their own directory; the root module is the way.)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meters = b.dependency("meters", .{
        .target = target,
        .optimize = optimize,
    });

    // Library module declaration (std + meters only)
    const mod = b.addModule("resonator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "meters", .module = meters.module("meters") },
        },
    });

    // Library installation
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "resonator",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Library unit tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}

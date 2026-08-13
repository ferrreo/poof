const std = @import("std");

const correctness_modes = [_]std.builtin.OptimizeMode{
    .Debug,
    .ReleaseSafe,
    .ReleaseFast,
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .none,
    });
    const dependency = b.dependency("ploof", .{});
    const ploof = dependency.module("ploof");
    const ploof_testing = dependency.module("ploof_testing");
    _ = dependency.artifact("ploof-assets");

    const test_step = b.step("test", "Build production and testing consumers");
    inline for (correctness_modes) |optimize| {
        const mode = @tagName(optimize);
        const executable = b.addExecutable(.{
            .name = b.fmt("package-api-fixture-{s}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{.{ .name = "ploof", .module = ploof }},
            }),
        });
        b.installArtifact(executable);

        const tests = b.addTest(.{
            .name = b.fmt("package-api-testing-{s}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testing.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{
                    .{ .name = "ploof", .module = ploof },
                    .{ .name = "ploof_testing", .module = ploof_testing },
                },
            }),
        });
        test_step.dependOn(&executable.step);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

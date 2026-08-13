const std = @import("std");

const CompileFailureCase = @import("compile_failures/case.zig").CompileFailureCase;
const case_groups = .{
    @import("compile_failures/core.zig").cases,
    @import("compile_failures/multipart.zig").cases,
    @import("compile_failures/html.zig").cases,
};

pub fn addChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    ploof: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    comptime modes: []const std.builtin.OptimizeMode,
) void {
    inline for (modes) |optimize| {
        inline for (case_groups) |cases| {
            inline for (cases) |case| {
                addCompileFailureCheck(b, test_step, ploof, target, optimize, case);
            }
        }
    }
}

fn addCompileFailureCheck(
    b: *std.Build,
    test_step: *std.Build.Step,
    ploof: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime case: CompileFailureCase,
) void {
    _ = ploof;
    _ = target;

    const check = b.addSystemCommand(&.{"sh"});
    check.setName(b.fmt("compile failure {s}-{s}", .{ case.name, @tagName(optimize) }));
    check.addFileArg(b.path("tools/check-compile-failure.sh"));
    check.addArg(case.message);
    check.addArg(b.graph.zig_exe);
    check.addArgs(&.{
        "build-obj",
        b.fmt("-O{s}", .{@tagName(optimize)}),
        "-target",
        "x86_64-linux-none",
        "-mcpu",
        "x86_64_v3",
        "--dep",
        "ploof_compile",
    });
    check.addPrefixedFileArg("-Mroot=", b.path(case.root ++ case.file));
    check.addPrefixedFileArg("-Mploof_compile=", b.path("compile_failure_api.zig"));
    check.addArg("-fno-emit-bin");
    test_step.dependOn(&check.step);
}

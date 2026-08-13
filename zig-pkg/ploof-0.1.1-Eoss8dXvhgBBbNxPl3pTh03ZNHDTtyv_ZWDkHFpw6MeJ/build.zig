const std = @import("std");
const builtin = @import("builtin");
const build_compile_failures = @import("build/compile_failures.zig");
const build_fuzz = @import("build_fuzz.zig");

const required_zig = std.SemanticVersion{
    .major = 0,
    .minor = 16,
    .patch = 0,
};

const correctness_modes = [_]std.builtin.OptimizeMode{
    .Debug,
    .ReleaseSafe,
    .ReleaseFast,
};

const release_modes = [_]std.builtin.OptimizeMode{
    .ReleaseSafe,
    .ReleaseFast,
};

pub fn build(b: *std.Build) void {
    requireZigVersion();

    const ploof = b.addModule("ploof", .{
        .root_source_file = b.path("src/ploof.zig"),
    });
    _ = b.addModule("ploof_testing", .{
        .root_source_file = b.path("src/testing/facade.zig"),
        .imports = &.{.{ .name = "ploof", .module = ploof }},
    });

    const assets = b.addExecutable(.{
        .name = "ploof-assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ploof-assets.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = false,
        }),
    });
    b.installArtifact(assets);

    const target = supportedTarget(b);
    const test_step = b.step("test", "Run all current correctness checks");
    const untrusted_step = b.step(
        "test-untrusted",
        "Run bounded hosted-runner correctness checks",
    );
    const format_check = b.addFmt(.{
        .paths = &.{
            "benchmark.zig",
            "build.zig",
            "build",
            "build_fuzz.zig",
            "compile_failure_api.zig",
            "fuzz.zig",
            "proxy_origin.zig",
            "test.zig",
            "tsan.zig",
            "benchmarks",
            "fuzz",
            "src",
            "tests",
            "tools/asset_compiler.zig",
            "tools/load_driver.zig",
            "tools/load_driver_config.zig",
            "tools/load_driver_engine.zig",
            "tools/load_driver_histogram.zig",
            "tools/load_driver_http.zig",
            "tools/load_driver_linux.zig",
            "tools/load_driver_report.zig",
            "tools/ploof-assets.zig",
        },
        .check = true,
    });
    test_step.dependOn(&format_check.step);
    test_step.dependOn(&assets.step);
    const load_driver = b.addExecutable(.{
        .name = "ploof-load-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/load_driver.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = false,
        }),
    });
    b.installArtifact(load_driver);
    addLoadDriverChecks(b, test_step, target, load_driver);
    addTechEmpower(b, test_step, target);
    addUnitTests(b, &.{ test_step, untrusted_step }, target, .Debug);
    addUnitTests(b, &.{test_step}, target, .ReleaseSafe);
    addUnitTests(b, &.{test_step}, target, .ReleaseFast);
    addThreadSanitizerTests(b, test_step);
    addTargetDiagnosticTests(b, test_step);
    addLibcFreeCheck(b, test_step, ploof, target);
    addIoUringProbeChecks(b, test_step, ploof, target);
    addServerLifecycleChecks(b, test_step, ploof, target);
    addPackageCheck(b, test_step);
    addPackageApiCheck(b, test_step);
    addAssetCompilerChecks(b, test_step, assets);
    build_compile_failures.addChecks(b, test_step, ploof, target, &correctness_modes);
    addProxyInteropStep(b, target);
    build_fuzz.addSteps(b, test_step, target);
    const benchmarks = b.option(bool, "benchmarks", "Enable lazy sigbench steps") orelse false;
    if (benchmarks) addBenchmarkSteps(b, target);
}

fn addTechEmpower(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
) void {
    const executable = b.addExecutable(.{
        .name = "ploof-techempower",
        .root_module = b.createModule(.{
            .root_source_file = b.path("techempower.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = false,
        }),
    });
    const install = b.addInstallArtifact(executable, .{});
    const build_step = b.step("techempower", "Build the TechEmpower HTTP benchmark server");
    build_step.dependOn(&install.step);

    const tests = b.addTest(.{
        .name = "techempower",
        .root_module = b.createModule(.{
            .root_source_file = b.path("techempower.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = false,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addLoadDriverChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    load_driver: *std.Build.Step.Compile,
) void {
    const build_step = b.step("load-driver", "Build the bounded HTTP/1.1 load driver");
    build_step.dependOn(&load_driver.step);
    const checks = b.step("test-load-driver", "Test the bounded HTTP/1.1 load driver");
    const integration = b.addSystemCommand(&.{"bash"});
    integration.addFileArg(b.path("tools/test-load-driver.sh"));
    inline for (correctness_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("load-driver-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/load_driver.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        checks.dependOn(&run_tests.step);

        const driver = b.addExecutable(.{
            .name = b.fmt("ploof-load-driver-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/load_driver.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
            }),
        });
        const origin = b.addExecutable(.{
            .name = b.fmt("ploof-load-origin-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("proxy_origin.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
            }),
        });
        integration.addArg(@tagName(optimize));
        integration.addArtifactArg(driver);
        integration.addArtifactArg(origin);
    }
    test_step.dependOn(&integration.step);
    checks.dependOn(&integration.step);

    const libc_check = b.addSystemCommand(&.{"sh"});
    libc_check.addFileArg(b.path("tools/check-libc-free.sh"));
    libc_check.addArtifactArg(load_driver);
    test_step.dependOn(&libc_check.step);
    checks.dependOn(&libc_check.step);
}

fn addAssetCompilerChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    assets: *std.Build.Step.Compile,
) void {
    inline for (correctness_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("asset-compiler-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/asset_compiler.zig"),
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = false,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const libc_check = b.addSystemCommand(&.{"sh"});
    libc_check.addFileArg(b.path("tools/check-libc-free.sh"));
    libc_check.addArtifactArg(assets);
    test_step.dependOn(&libc_check.step);

    const cache = b.graph.global_cache_root.join(
        b.allocator,
        &.{"ploof-asset-compiler-fixture"},
    ) catch @panic("out of memory");
    const fixture = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--cache-dir",
        cache,
    });
    fixture.setCwd(b.path("tests/fixtures/asset_compiler"));
    test_step.dependOn(&fixture.step);
}

fn addProxyInteropStep(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const required = b.option(
        bool,
        "proxy-interop-required",
        "Fail when pinned proxy interop prerequisites are unavailable",
    ) orelse false;
    const step = b.step(
        "test-proxy-interop",
        "Test direct, Caddy, and nginx forwarding interoperability",
    );
    const run = b.addSystemCommand(&.{"bash"});
    run.addFileArg(b.path("tools/test-proxy-interop.sh"));
    run.addArg(if (required) "--required" else "--optional");
    inline for (correctness_modes) |optimize| {
        const origin = b.addExecutable(.{
            .name = b.fmt("ploof-proxy-interop-origin-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("proxy_origin.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
            }),
        });
        run.addArtifactArg(origin);
    }
    run.setCwd(b.path("."));
    step.dependOn(&run.step);
}

fn addThreadSanitizerTests(
    b: *std.Build,
    test_step: *std.Build.Step,
) void {
    const sanitizer_step = b.step(
        "test-thread-sanitizer",
        "Run concurrent runtime tests under ThreadSanitizer",
    );
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .gnu,
    });
    inline for (correctness_modes) |optimize| {
        const module = b.createModule(.{
            .root_source_file = b.path("tsan.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.sanitize_thread = true;
        const tests = b.addTest(.{
            .name = b.fmt("runtime-tsan-{s}", .{@tagName(optimize)}),
            .root_module = module,
        });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        sanitizer_step.dependOn(&run.step);
    }
}

fn addBenchmarkSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    inline for (release_modes) |optimize| {
        const dependency = b.lazyDependency("sigbench", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        const module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{.{ .name = "sigbench", .module = dependency.module("sigbench") }},
        });
        const executable = b.addExecutable(.{
            .name = b.fmt("ploof-bench-{s}", .{@tagName(optimize)}),
            .root_module = module,
        });
        const run = b.addRunArtifact(executable);
        if (b.args) |args| run.addArgs(args);
        const step_name = if (optimize == .ReleaseSafe)
            "bench-release-safe"
        else
            "bench-release-fast";
        const step = b.step(step_name, b.fmt("Run {s} benchmarks", .{@tagName(optimize)}));
        step.dependOn(&run.step);
        if (optimize == .ReleaseSafe) {
            const headline = b.step("bench", "Run headline ReleaseSafe benchmarks");
            headline.dependOn(&run.step);
        }
    }
}

fn addIoUringProbeChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    ploof: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    inline for (correctness_modes) |optimize| {
        const fixture = b.addExecutable(.{
            .name = b.fmt("ploof-io-uring-probe-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/io_uring_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{.{ .name = "ploof", .module = ploof }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(fixture).step);

        if (optimize != .Debug) {
            const check = b.addSystemCommand(&.{"sh"});
            check.addFileArg(b.path("tools/check-libc-free.sh"));
            check.addArtifactArg(fixture);
            test_step.dependOn(&check.step);
        }

        const failure_fixture = b.addExecutable(.{
            .name = b.fmt("ploof-io-uring-probe-failure-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/io_uring_probe_failure.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{.{ .name = "ploof", .module = ploof }},
            }),
        });
        const failure_run = b.addRunArtifact(failure_fixture);
        failure_run.expectExitCode(1);
        failure_run.expectStdErrMatch("PLOOF-E1001 startup failure");
        failure_run.expectStdErrMatch("no fallback reactor");
        test_step.dependOn(&failure_run.step);
    }
}

fn addServerLifecycleChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    ploof: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    const fixture = b.addExecutable(.{
        .name = "ploof-server-moved-ReleaseFast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/server_moved_release_fast.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = false,
            .imports = &.{.{ .name = "ploof", .module = ploof }},
        }),
    });
    const run = b.addRunArtifact(fixture);
    run.expectExitCode(73);
    test_step.dependOn(&run.step);
}

fn requireZigVersion() void {
    if (builtin.zig_version.order(required_zig) != .eq) {
        @panic("Ploof requires Zig 0.16.0 exactly");
    }
}

fn supportedTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .none,
    });
}

fn addUnitTests(
    b: *std.Build,
    test_steps: []const *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const production_tests_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const production = b.createModule(.{
        .root_source_file = b.path("src/ploof.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const testing = b.createModule(.{
        .root_source_file = b.path("src/testing/facade.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{.{ .name = "ploof", .module = production }},
    });

    const production_tests = b.addTest(.{ .root_module = production_tests_module });
    const testing_tests = b.addTest(.{ .root_module = testing });
    const production_run = &b.addRunArtifact(production_tests).step;
    const testing_run = &b.addRunArtifact(testing_tests).step;
    for (test_steps) |test_step| {
        test_step.dependOn(production_run);
        test_step.dependOn(testing_run);
    }
}

fn addTargetDiagnosticTests(b: *std.Build, test_step: *std.Build.Step) void {
    inline for (correctness_modes) |optimize| {
        addTargetDiagnostic(b, test_step, optimize, "os", .{
            .cpu_arch = .x86_64,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
            .os_tag = .windows,
            .abi = .msvc,
        }, "Ploof requires Linux");
        addTargetDiagnostic(b, test_step, optimize, "architecture", .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .none,
        }, "Ploof requires x86_64");
        addTargetDiagnostic(b, test_step, optimize, "cpu", .{
            .cpu_arch = .x86_64,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
            .os_tag = .linux,
            .abi = .none,
        }, "Ploof requires x86-64-v3 or newer");
    }
}

fn addTargetDiagnostic(
    b: *std.Build,
    test_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    query: std.Target.Query,
    message: []const u8,
) void {
    const object = b.addObject(.{
        .name = b.fmt("unsupported-{s}-{s}", .{ name, @tagName(optimize) }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ploof.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
            .link_libc = false,
        }),
    });
    object.expect_errors = .{ .contains = message };
    test_step.dependOn(&object.step);
}

fn addLibcFreeCheck(
    b: *std.Build,
    test_step: *std.Build.Step,
    ploof: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    inline for (release_modes) |optimize| {
        const fixture = b.addExecutable(.{
            .name = b.fmt("ploof-libc-free-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/libc_free.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{.{ .name = "ploof", .module = ploof }},
            }),
        });

        const check = b.addSystemCommand(&.{"sh"});
        check.addFileArg(b.path("tools/check-libc-free.sh"));
        check.addArtifactArg(fixture);
        test_step.dependOn(&check.step);
    }
}

fn addPackageCheck(b: *std.Build, test_step: *std.Build.Step) void {
    const check = b.addSystemCommand(&.{"sh"});
    check.addFileArg(b.path("tools/check-package.sh"));
    check.addArgs(&.{ b.graph.zig_exe, "." });
    check.setCwd(b.path("."));
    test_step.dependOn(&check.step);
}

fn addPackageApiCheck(b: *std.Build, test_step: *std.Build.Step) void {
    const cache = b.graph.global_cache_root.join(
        b.allocator,
        &.{"ploof-package-api-fixture"},
    ) catch @panic("out of memory");
    const check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "test",
        "--cache-dir",
        cache,
    });
    check.setCwd(b.path("tests/fixtures/package_api"));
    test_step.dependOn(&check.step);
}

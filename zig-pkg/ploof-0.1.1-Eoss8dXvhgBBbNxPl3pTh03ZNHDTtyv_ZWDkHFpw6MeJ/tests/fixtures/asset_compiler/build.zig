const std = @import("std");

const correctness_modes = [_]std.builtin.OptimizeMode{
    .Debug,
    .ReleaseSafe,
    .ReleaseFast,
};

pub fn build(b: *std.Build) void {
    const dependency = b.dependency("ploof", .{});
    const tool = dependency.artifact("ploof-assets");
    const first = generateBundle(b, tool, "first.zig", false);
    const second = generateBundle(b, tool, "second.zig", true);
    const bundle = b.createModule(.{ .root_source_file = first });
    const step = b.step("test", "Test deterministic Ploof asset compilation");

    addComparison(b, step, first, second);
    addConsumerTests(b, step, dependency, bundle);
    addContractFailureTests(b, step, dependency, bundle);
    addFailureTests(b, step, tool);
}

fn generateBundle(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    basename: []const u8,
    reverse: bool,
) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("--output");
    const output = run.addOutputFileArg(basename);
    if (reverse) {
        addAsset(b, run, "logo.bin", "binary", "assets/logo.bin");
        addAsset(b, run, "app.css", "css", "assets/app.css");
    } else {
        addAsset(b, run, "app.css", "css", "assets/app.css");
        addAsset(b, run, "logo.bin", "binary", "assets/logo.bin");
    }
    return output;
}

fn addAsset(
    b: *std.Build,
    run: *std.Build.Step.Run,
    name: []const u8,
    kind: []const u8,
    path: []const u8,
) void {
    run.addArgs(&.{ "--asset", name, kind });
    run.addFileArg(b.path(path));
}

fn addComparison(
    b: *std.Build,
    step: *std.Build.Step,
    first: std.Build.LazyPath,
    second: std.Build.LazyPath,
) void {
    const executable = b.addExecutable(.{
        .name = "compare-generated-assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compare_generated.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = false,
        }),
    });
    const run = b.addRunArtifact(executable);
    run.addFileArg(first);
    run.addFileArg(second);
    step.dependOn(&run.step);
}

fn addConsumerTests(
    b: *std.Build,
    step: *std.Build.Step,
    dependency: *std.Build.Dependency,
    bundle: *std.Build.Module,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .none,
    });
    inline for (correctness_modes) |optimize| {
        const tests = b.addTest(.{
            .name = b.fmt("asset-consumer-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/consumer.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{.{ .name = "asset_bundle", .module = bundle }},
            }),
        });
        step.dependOn(&b.addRunArtifact(tests).step);

        const runtime_tests = b.addTest(.{
            .name = b.fmt("asset-runtime-consumer-{s}", .{@tagName(optimize)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/runtime_consumer.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{
                    .{ .name = "asset_bundle", .module = bundle },
                    .{
                        .name = "asset_runtime",
                        .module = b.createModule(.{
                            .root_source_file = dependency.path("src/asset.zig"),
                        }),
                    },
                },
            }),
        });
        step.dependOn(&b.addRunArtifact(runtime_tests).step);
    }
}

fn addFailureTests(
    b: *std.Build,
    step: *std.Build.Step,
    tool: *std.Build.Step.Compile,
) void {
    addFailure(b, step, tool, .{
        .name = "invalid-name",
        .arguments = &.{ "--asset", "App.css", "css" },
        .exit_code = 2,
        .message = "PLOOF-E5009 invalid embedded asset logical name\n",
    });
    addFailure(b, step, tool, .{
        .name = "input-limit",
        .arguments = &.{ "--input-bytes-max", "1", "--asset", "app.css", "css" },
        .exit_code = 3,
        .message = "PLOOF-E5013 embedded asset bytes exceed configured limit\n",
    });
    addFailure(b, step, tool, .{
        .name = "generated-limit",
        .arguments = &.{ "--generated-bytes-max", "1", "--asset", "app.css", "css" },
        .exit_code = 4,
        .message = "PLOOF-E5015 generated module exceeds configured limit\n",
    });
    addDuplicateFailure(b, step, tool);
    addFailure(b, step, tool, .{
        .name = "invalid-media",
        .arguments = &.{ "--asset", "app.css", "wat" },
        .exit_code = 2,
        .message = "PLOOF-E5011 invalid embedded asset media kind\n",
    });
    addFailure(b, step, tool, .{
        .name = "invalid-prefix",
        .arguments = &.{ "--prefix", "assets/", "--asset", "app.css", "css" },
        .exit_code = 2,
        .message = "PLOOF-E5007 invalid asset route prefix\n",
    });
    addAssetCountFailure(b, step, tool);
}

const ContractFailure = struct {
    case: u8,
    name: []const u8,
    message: []const u8,
};

const contract_failures = [_]ContractFailure{
    .{
        .case = 0,
        .name = "shape",
        .message = "PLOOF-E5100 invalid generated embedded asset module shape",
    },
    .{
        .case = 1,
        .name = "version",
        .message = "PLOOF-E5101 unsupported embedded asset module format version",
    },
    .{
        .case = 2,
        .name = "count",
        .message = "PLOOF-E5102 embedded asset count must be 1 to 4096",
    },
    .{
        .case = 3,
        .name = "prefix",
        .message = "PLOOF-E5103 invalid generated embedded asset route prefix",
    },
    .{
        .case = 4,
        .name = "media-table",
        .message = "PLOOF-E5104 invalid embedded asset media-kind table",
    },
    .{
        .case = 5,
        .name = "order",
        .message = "PLOOF-E5106 embedded assets must have unique sorted logical names",
    },
    .{
        .case = 6,
        .name = "path",
        .message = "PLOOF-E5107 invalid content-addressed embedded asset path",
    },
    .{
        .case = 7,
        .name = "media",
        .message = "PLOOF-E5108 invalid embedded asset media metadata",
    },
    .{
        .case = 8,
        .name = "etag",
        .message = "PLOOF-E5109 invalid embedded asset identity metadata",
    },
    .{
        .case = 9,
        .name = "gzip",
        .message = "PLOOF-E5110 invalid embedded asset gzip policy",
    },
    .{
        .case = 11,
        .name = "unknown",
        .message = "PLOOF-E5112 unknown embedded asset 'missing.bin'",
    },
    .{
        .case = 12,
        .name = "limits",
        .message = "PLOOF-E5113 invalid embedded asset origin limits",
    },
    .{
        .case = 13,
        .name = "origin",
        .message = "PLOOF-E5114 invalid embedded asset origin at index 0: UnsupportedScheme",
    },
    .{
        .case = 14,
        .name = "identity-digest",
        .message = "PLOOF-E5109 invalid embedded asset identity metadata",
    },
    .{
        .case = 15,
        .name = "gzip-digest",
        .message = "PLOOF-E5110 invalid embedded asset gzip metadata",
    },
};

fn addContractFailureTests(
    b: *std.Build,
    step: *std.Build.Step,
    dependency: *std.Build.Dependency,
    bundle: *std.Build.Module,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .none,
    });
    inline for (correctness_modes) |optimize| {
        for (contract_failures) |failure| {
            const values = b.addOptions();
            values.addOption(u8, "case", failure.case);
            const object = b.addObject(.{
                .name = b.fmt("asset-contract-{s}-{s}", .{
                    failure.name,
                    @tagName(optimize),
                }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/contract_failure.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = false,
                    .imports = &.{
                        .{ .name = "asset_bundle", .module = bundle },
                        .{ .name = "contract_options", .module = values.createModule() },
                        .{
                            .name = "asset_runtime",
                            .module = b.createModule(.{
                                .root_source_file = dependency.path("src/asset.zig"),
                            }),
                        },
                    },
                }),
            });
            object.expect_errors = .{ .contains = failure.message };
            step.dependOn(&object.step);
        }
    }
}

const Failure = struct {
    name: []const u8,
    arguments: []const []const u8,
    exit_code: u8,
    message: []const u8,
};

fn addFailure(
    b: *std.Build,
    step: *std.Build.Step,
    tool: *std.Build.Step.Compile,
    failure: Failure,
) void {
    const run = b.addRunArtifact(tool);
    run.addArg("--output");
    _ = run.addOutputFileArg(b.fmt("failure-{s}.zig", .{failure.name}));
    run.addArgs(failure.arguments);
    run.addFileArg(b.path("assets/app.css"));
    run.expectExitCode(failure.exit_code);
    run.expectStdErrEqual(failure.message);
    run.expectStdOutEqual("");
    step.dependOn(&run.step);
}

fn addDuplicateFailure(
    b: *std.Build,
    step: *std.Build.Step,
    tool: *std.Build.Step.Compile,
) void {
    const run = b.addRunArtifact(tool);
    run.addArg("--output");
    _ = run.addOutputFileArg("failure-duplicate.zig");
    run.addArgs(&.{ "--asset", "app.css", "css" });
    run.addFileArg(b.path("assets/app.css"));
    run.addArgs(&.{ "--asset", "app.css", "css" });
    run.addFileArg(b.path("assets/app.css"));
    expectFailure(run, 2, "PLOOF-E5010 duplicate embedded asset logical name\n");
    step.dependOn(&run.step);
}

fn addAssetCountFailure(
    b: *std.Build,
    step: *std.Build.Step,
    tool: *std.Build.Step.Compile,
) void {
    const run = b.addRunArtifact(tool);
    run.addArg("--output");
    _ = run.addOutputFileArg("failure-count.zig");
    run.addArgs(&.{ "--assets-max", "1", "--asset", "app.css", "css" });
    run.addFileArg(b.path("assets/app.css"));
    run.addArgs(&.{ "--asset", "logo.bin", "binary" });
    run.addFileArg(b.path("assets/logo.bin"));
    expectFailure(run, 2, "PLOOF-E5008 embedded asset count exceeds configured limit\n");
    step.dependOn(&run.step);
}

fn expectFailure(run: *std.Build.Step.Run, code: u8, message: []const u8) void {
    run.expectExitCode(code);
    run.expectStdErrEqual(message);
    run.expectStdOutEqual("");
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .os_tag = .linux,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    const ploof_dependency = b.dependency("ploof", .{});
    const zhl_dependency = b.dependency("zhl", .{
        .target = target,
        .optimize = optimize,
    });
    const pg_dependency = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    });

    const generated_assets = compileAssets(b, ploof_dependency);
    const assets_module = b.createModule(.{ .root_source_file = generated_assets });
    const application_module = applicationModule(
        b,
        target,
        optimize,
        ploof_dependency,
        zhl_dependency,
        pg_dependency,
        assets_module,
    );

    const executable = b.addExecutable(.{
        .name = "poof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "poof", .module = application_module },
                .{ .name = "ploof", .module = ploof_dependency.module("ploof") },
            },
        }),
    });
    b.installArtifact(executable);

    const run_artifact = b.addRunArtifact(executable);
    if (b.args) |arguments| run_artifact.addArgs(arguments);
    const run_step = b.step("run", "Run Poof");
    run_step.dependOn(&run_artifact.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "poof", .module = application_module },
                .{
                    .name = "ploof_testing",
                    .module = ploof_dependency.module("ploof_testing"),
                },
            },
        }),
    });
    const test_step = b.step("test", "Run Poof tests");
    const module_tests = b.addTest(.{ .root_module = application_module });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const integration_options = b.addOptions();
    integration_options.addOption(
        []const u8,
        "database_url",
        b.option(
            []const u8,
            "database-url",
            "PostgreSQL URL used by integration tests",
        ) orelse
            "postgresql://poof:poof@127.0.0.1:5432/poof_test?sslmode=disable",
    );
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "poof", .module = application_module },
                .{
                    .name = "ploof_testing",
                    .module = ploof_dependency.module("ploof_testing"),
                },
                .{
                    .name = "integration_options",
                    .module = integration_options.createModule(),
                },
            },
        }),
    });
    const integration_step = b.step(
        "test-integration",
        "Run live PostgreSQL integration tests",
    );
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    const format = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tests" },
        .check = true,
    });
    const format_step = b.step("fmt-check", "Check Zig formatting");
    format_step.dependOn(&format.step);
    test_step.dependOn(&format.step);
}

fn compileAssets(
    b: *std.Build,
    ploof_dependency: *std.Build.Dependency,
) std.Build.LazyPath {
    const run = b.addRunArtifact(ploof_dependency.artifact("ploof-assets"));
    run.addArg("--output");
    const generated = run.addOutputFileArg("poof_assets.zig");
    addAsset(b, run, "app.css", "css", "assets/app.css");
    addAsset(b, run, "app.js", "javascript", "assets/app.js");
    return generated;
}

fn addAsset(
    b: *std.Build,
    run: *std.Build.Step.Run,
    name: []const u8,
    media_kind: []const u8,
    path: []const u8,
) void {
    run.addArgs(&.{ "--asset", name, media_kind });
    run.addFileArg(b.path(path));
}

fn applicationModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ploof_dependency: *std.Build.Dependency,
    zhl_dependency: *std.Build.Dependency,
    pg_dependency: *std.Build.Dependency,
    assets_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "ploof", .module = ploof_dependency.module("ploof") },
            .{ .name = "zhl", .module = zhl_dependency.module("zhl") },
            .{
                .name = "zhl_grammars",
                .module = zhl_dependency.module("zhl_grammars"),
            },
            .{ .name = "pg", .module = pg_dependency.module("pg") },
            .{ .name = "assets", .module = assets_module },
        },
    });
    module.addAnonymousImport("migration_001", .{
        .root_source_file = b.path("migrations/001_initial.sql"),
    });
    module.addAnonymousImport("migration_002", .{
        .root_source_file = b.path("migrations/002_seed_default_board.sql"),
    });
    module.addAnonymousImport("migration_003", .{
        .root_source_file = b.path("migrations/003_action_rate_limits.sql"),
    });
    module.addAnonymousImport("migration_004", .{
        .root_source_file = b.path("migrations/004_concurrency_guards.sql"),
    });
    module.addAnonymousImport("migration_005", .{
        .root_source_file = b.path("migrations/005_site_settings.sql"),
    });
    return module;
}

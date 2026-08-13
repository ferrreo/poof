const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const langs = b.option(
        []const u8,
        "langs",
        "Languages to bake in: native (default), full, or comma-separated e.g. zig,haskell,elixir",
    ) orelse "native";

    const select_grammars_cmd = b.addSystemCommand(&.{
        "sh", "-c", "OUT_DIR=zig-out/grammars_selected LANGS=\"$1\" sh tools/select_grammars.sh", "sh",
    });
    select_grammars_cmd.addArg(langs);

    const zhl_mod = b.addModule("zhl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const grammars_mod = b.addModule("zhl_grammars", .{
        .root_source_file = b.path("src/grammars/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
        },
    });

    const zhl_tests = b.addTest(.{ .root_module = zhl_mod });
    const run_zhl_tests = b.addRunArtifact(zhl_tests);

    const grammar_tests = b.addTest(.{ .root_module = grammars_mod });
    const run_grammar_tests = b.addRunArtifact(grammar_tests);

    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);

    const zhlc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zhlc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    const run_zhlc_tests = b.addRunArtifact(zhlc_tests);

    const test_step = b.step("test", "Run unit tests");
    const line_check_cmd = b.addSystemCommand(&.{ "sh", "tools/check_file_lines.sh" });
    const license_check_cmd = b.addSystemCommand(&.{ "sh", "tools/check_licenses.sh" });
    const corpus_count_cmd = b.addSystemCommand(&.{ "sh", "tools/check_corpus_counts.sh" });
    const corpus_cache_cmd = b.addSystemCommand(&.{ "sh", "tools/check_corpus_cache.sh" });
    const runtime_boundary_cmd = b.addSystemCommand(&.{ "sh", "tools/check_runtime_boundary.sh" });
    const public_api_docs_cmd = b.addSystemCommand(&.{ "sh", "tools/check_public_api_docs.sh" });
    const release_docs_cmd = b.addSystemCommand(&.{ "sh", "tools/check_release_docs.sh" });
    const compatibility_summary_cmd = b.addSystemCommand(&.{ "sh", "tools/write_compatibility_summary.sh" });
    test_step.dependOn(&line_check_cmd.step);
    test_step.dependOn(&license_check_cmd.step);
    test_step.dependOn(&corpus_count_cmd.step);
    test_step.dependOn(&runtime_boundary_cmd.step);
    test_step.dependOn(&public_api_docs_cmd.step);
    test_step.dependOn(&release_docs_cmd.step);
    test_step.dependOn(&run_zhl_tests.step);
    test_step.dependOn(&run_grammar_tests.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_zhlc_tests.step);
    const line_check_step = b.step("check-lines", "Enforce 750-line non-test file cap");
    line_check_step.dependOn(&line_check_cmd.step);
    const license_check_step = b.step("check-licenses", "Ensure bundled third-party files carry licenses");
    license_check_step.dependOn(&license_check_cmd.step);
    const corpus_count_step = b.step("check-corpus-counts", "Ensure documented grammar corpus counts stay current");
    corpus_count_step.dependOn(&corpus_count_cmd.step);
    const corpus_cache_step = b.step("check-corpus-cache", "Ensure corpus cache manifest and locked counts are current");
    corpus_cache_step.dependOn(&corpus_cache_cmd.step);
    const runtime_boundary_step = b.step("check-runtime-boundary", "Ensure runtime code does not import offline grammar converters");
    runtime_boundary_step.dependOn(&runtime_boundary_cmd.step);
    const public_api_docs_step = b.step("check-public-api-docs", "Ensure public API docs match root exports");
    public_api_docs_step.dependOn(&public_api_docs_cmd.step);
    const release_docs_step = b.step("check-release-docs", "Ensure v1 release docs are present");
    release_docs_step.dependOn(&release_docs_cmd.step);
    const compatibility_summary_step = b.step("check-compatibility-summary", "Write and validate compatibility summary artifacts");
    compatibility_summary_step.dependOn(&compatibility_summary_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmark/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
        },
    });
    bench_mod.addAnonymousImport("zig_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/zig.txt") });
    bench_mod.addAnonymousImport("zig_adversarial_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/zig_adversarial.txt") });
    bench_mod.addAnonymousImport("typescript_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/typescript.txt") });
    bench_mod.addAnonymousImport("rust_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/rust.txt") });
    bench_mod.addAnonymousImport("python_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/python.txt") });
    bench_mod.addAnonymousImport("json_min_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/json_min.txt") });
    bench_mod.addAnonymousImport("javascript_min_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/javascript_min.txt") });
    bench_mod.addAnonymousImport("textmate_json_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/textmate_json.txt") });
    bench_mod.addAnonymousImport("cpp_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/cpp-textmate.cpp") });
    bench_mod.addAnonymousImport("csharp_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/csharp-textmate.cs") });
    bench_mod.addAnonymousImport("html_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/html-textmate.html") });
    bench_mod.addAnonymousImport("java_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/java-textmate.java") });
    bench_mod.addAnonymousImport("jsx_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/jsx-textmate.jsx") });
    bench_mod.addAnonymousImport("kotlin_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/kotlin-textmate.kt") });
    bench_mod.addAnonymousImport("markdown_bench_corpus", .{ .root_source_file = b.path("README.md") });
    bench_mod.addAnonymousImport("php_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/php-textmate.php") });
    bench_mod.addAnonymousImport("ruby_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/ruby-textmate.rb") });
    bench_mod.addAnonymousImport("swift_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/swift-textmate.swift") });
    bench_mod.addAnonymousImport("tsx_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/tsx-textmate.tsx") });
    bench_mod.addAnonymousImport("zig_real_regex_source", .{ .root_source_file = b.path("src/regex/parser.zig") });
    bench_mod.addAnonymousImport("zig_real_regex_vm_source", .{ .root_source_file = b.path("src/regex/vm.zig") });
    bench_mod.addAnonymousImport("zig_real_native_runtime_source", .{ .root_source_file = b.path("src/runtime/native_runtime.zig") });
    bench_mod.addAnonymousImport("zig_real_textmate_import_source", .{ .root_source_file = b.path("src/textmate/import.zig") });
    bench_mod.addAnonymousImport("zig_real_textmate_plist_source", .{ .root_source_file = b.path("src/textmate/plist.zig") });
    bench_mod.addAnonymousImport("zig_real_dsl_source", .{ .root_source_file = b.path("src/native/dsl.zig") });
    bench_mod.addAnonymousImport("zig_real_sublime_source", .{ .root_source_file = b.path("src/sublime/import.zig") });
    bench_mod.addAnonymousImport("zig_real_tree_sitter_source", .{ .root_source_file = b.path("src/tree_sitter/root.zig") });
    bench_mod.addAnonymousImport("zig_real_engine_source", .{ .root_source_file = b.path("src/runtime/engine.zig") });
    bench_mod.addAnonymousImport("bash_real_gate_source", .{ .root_source_file = b.path("benchmark/gate.sh") });
    bench_mod.addAnonymousImport("bash_real_integrations_source", .{ .root_source_file = b.path("tools/check_integrations.sh") });
    bench_mod.addAnonymousImport("bash_real_lines_source", .{ .root_source_file = b.path("tools/check_file_lines.sh") });
    bench_mod.addAnonymousImport("bash_real_compare_source", .{ .root_source_file = b.path("benchmark/run_compare.sh") });
    bench_mod.addAnonymousImport("javascript_real_visual_source", .{ .root_source_file = b.path("benchmark/visual_compare.mjs") });
    bench_mod.addAnonymousImport("javascript_real_diff_source", .{ .root_source_file = b.path("benchmark/differential_native.mjs") });
    bench_mod.addAnonymousImport("javascript_real_shiki_source", .{ .root_source_file = b.path("benchmark/shiki.mjs") });
    bench_mod.addAnonymousImport("javascript_real_wasm_source", .{ .root_source_file = b.path("benchmark/wasm.mjs") });
    bench_mod.addAnonymousImport("json_real_package_lock_source", .{ .root_source_file = b.path("benchmark/package-lock.json") });
    bench_mod.addAnonymousImport("json_real_textmate_source", .{ .root_source_file = b.path("grammars/textmate/json.tmLanguage.json") });
    bench_mod.addAnonymousImport("rust_real_syntect_source", .{ .root_source_file = b.path("benchmark/syntect/src/main.rs") });
    bench_mod.addAnonymousImport("toml_real_syntect_lock_source", .{ .root_source_file = b.path("benchmark/syntect/Cargo.lock") });
    bench_mod.addAnonymousImport("toml_real_syntect_fancy_lock_source", .{ .root_source_file = b.path("benchmark/syntect_fancy/Cargo.lock") });
    bench_mod.addAnonymousImport("toml_real_syntect_manifest_source", .{ .root_source_file = b.path("benchmark/syntect/Cargo.toml") });
    bench_mod.addAnonymousImport("toml_real_syntect_fancy_manifest_source", .{ .root_source_file = b.path("benchmark/syntect_fancy/Cargo.toml") });
    bench_mod.addAnonymousImport("yaml_real_ci_source", .{ .root_source_file = b.path(".github/workflows/ci.yml") });
    bench_mod.addAnonymousImport("c_real_gzread_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/c_real_gzread.c") });
    bench_mod.addAnonymousImport("python_real_requests_adapters_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/python_real_requests_adapters.py") });
    bench_mod.addAnonymousImport("typescript_real_vscode_range_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/typescript_real_vscode_range.ts") });
    const bench = b.addExecutable(.{
        .name = "zhl-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const zhlc = b.addExecutable(.{
        .name = "zhlc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zhlc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    zhlc.stack_size = 16 * 1024 * 1024;
    b.installArtifact(zhlc);
    const check_zhlc = if (optimize == .Debug) blk: {
        const fast_zhlc = b.addExecutable(.{
            .name = "zhlc-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/zhlc.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zhl", .module = zhl_mod },
                    .{ .name = "zhl_grammars", .module = grammars_mod },
                },
            }),
        });
        fast_zhlc.stack_size = 16 * 1024 * 1024;
        break :blk fast_zhlc;
    } else zhlc;

    const tree_sitter_example = b.addExecutable(.{
        .name = "tree-sitter-overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tree_sitter_overlay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    const run_tree_sitter_example = b.addRunArtifact(tree_sitter_example);
    const tree_sitter_example_step = b.step("tree-sitter-example", "Run optional Tree-sitter overlay example");
    tree_sitter_example_step.dependOn(&run_tree_sitter_example.step);
    test_step.dependOn(&run_tree_sitter_example.step);

    const editor_example = b.addExecutable(.{
        .name = "editor-tokens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/editor_tokens.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhl", .module = zhl_mod },
                .{ .name = "zhl_grammars", .module = grammars_mod },
            },
        }),
    });
    const run_editor_example = b.addRunArtifact(editor_example);
    const editor_example_step = b.step("editor-example", "Run editor token adapter example");
    editor_example_step.dependOn(&run_editor_example.step);
    test_step.dependOn(&run_editor_example.step);

    const integration_step = b.step("check-integrations", "Run end-to-end grammar integration checks");
    const integration_cmd = b.addSystemCommand(&.{ "sh", "tools/check_integrations.sh", "all" });
    integration_cmd.addArtifactArg(check_zhlc);
    integration_step.dependOn(&integration_cmd.step);
    test_step.dependOn(&integration_cmd.step);

    const shiki_ecosystem_step = b.step("check-shiki-ecosystem", "Check Shiki TextMate grammar ecosystem conversion");
    const shiki_ecosystem_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" npm --prefix benchmark run check:shiki-ecosystem", "sh" });
    shiki_ecosystem_cmd.addArtifactArg(check_zhlc);
    shiki_ecosystem_step.dependOn(&shiki_ecosystem_cmd.step);

    const differential_step = b.step("check-diff-native", "Check native zhl spans against Shiki");
    const differential_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" npm --prefix benchmark run diff:native", "sh" });
    differential_cmd.addArtifactArg(check_zhlc);
    differential_step.dependOn(&differential_cmd.step);

    const oracle_spans_step = b.step("check-oracle-spans", "Check selected native zhl spans against TextMate oracle");
    const oracle_spans_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" node benchmark/oracle_spans.mjs", "sh" });
    oracle_spans_cmd.addArtifactArg(check_zhlc);
    oracle_spans_step.dependOn(&oracle_spans_cmd.step);
    compatibility_summary_cmd.step.dependOn(&oracle_spans_cmd.step);

    const visual_step = b.step("check-visual", "Run visual comparison assertions");
    const visual_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" npm --prefix benchmark run visual", "sh" });
    visual_cmd.addArtifactArg(check_zhlc);
    visual_step.dependOn(&visual_cmd.step);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmark harness");
    bench_step.dependOn(&bench_cmd.step);

    const bench_cases_step = b.step("check-bench-cases", "Check benchmark case parity");
    const bench_cases_cmd = b.addSystemCommand(&.{ "npm", "--prefix", "benchmark", "run", "check:cases" });
    bench_cases_step.dependOn(&bench_cases_cmd.step);

    const onig_cases_step = b.step("check-oniguruma-cases", "Check regex VM conformance cases against Oniguruma");
    const onig_cases_cmd = b.addSystemCommand(&.{ "npm", "--prefix", "benchmark", "run", "check:onig-cases" });
    onig_cases_step.dependOn(&onig_cases_cmd.step);

    const corpus_regex_patterns_step = b.step("check-corpus-regex-patterns", "Check cached corpus regex patterns");
    const corpus_regex_patterns_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" node benchmark/check_corpus_regex_patterns.mjs", "sh" });
    corpus_regex_patterns_cmd.addArtifactArg(check_zhlc);
    corpus_regex_patterns_cmd.step.dependOn(&corpus_cache_cmd.step);
    corpus_regex_patterns_step.dependOn(&corpus_regex_patterns_cmd.step);
    compatibility_summary_cmd.step.dependOn(&corpus_regex_patterns_cmd.step);

    const bench_gate_step = b.step("check-bench-native", "Gate native benchmark throughput and allocations");
    const bench_gate_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHL_BENCH=\"$1\" sh benchmark/gate.sh", "sh" });
    bench_gate_cmd.addArtifactArg(bench);
    bench_gate_step.dependOn(&bench_gate_cmd.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/wasm_export.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
        },
    });
    wasm_mod.addAnonymousImport("zig_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/zig.txt") });
    wasm_mod.addAnonymousImport("zig_adversarial_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/zig_adversarial.txt") });
    wasm_mod.addAnonymousImport("typescript_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/typescript.txt") });
    wasm_mod.addAnonymousImport("rust_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/rust.txt") });
    wasm_mod.addAnonymousImport("python_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/python.txt") });
    wasm_mod.addAnonymousImport("json_min_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/json_min.txt") });
    wasm_mod.addAnonymousImport("javascript_min_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/javascript_min.txt") });
    wasm_mod.addAnonymousImport("textmate_json_bench_corpus", .{ .root_source_file = b.path("benchmark/corpus/textmate_json.txt") });
    wasm_mod.addAnonymousImport("cpp_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/cpp-textmate.cpp") });
    wasm_mod.addAnonymousImport("csharp_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/csharp-textmate.cs") });
    wasm_mod.addAnonymousImport("html_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/html-textmate.html") });
    wasm_mod.addAnonymousImport("java_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/java-textmate.java") });
    wasm_mod.addAnonymousImport("jsx_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/jsx-textmate.jsx") });
    wasm_mod.addAnonymousImport("kotlin_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/kotlin-textmate.kt") });
    wasm_mod.addAnonymousImport("markdown_bench_corpus", .{ .root_source_file = b.path("README.md") });
    wasm_mod.addAnonymousImport("php_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/php-textmate.php") });
    wasm_mod.addAnonymousImport("ruby_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/ruby-textmate.rb") });
    wasm_mod.addAnonymousImport("swift_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/swift-textmate.swift") });
    wasm_mod.addAnonymousImport("tsx_bench_corpus", .{ .root_source_file = b.path("tests/fixtures/languages/tsx-textmate.tsx") });
    wasm_mod.addAnonymousImport("zig_real_regex_source", .{ .root_source_file = b.path("src/regex/parser.zig") });
    wasm_mod.addAnonymousImport("zig_real_regex_vm_source", .{ .root_source_file = b.path("src/regex/vm.zig") });
    wasm_mod.addAnonymousImport("zig_real_native_runtime_source", .{ .root_source_file = b.path("src/runtime/native_runtime.zig") });
    wasm_mod.addAnonymousImport("zig_real_textmate_import_source", .{ .root_source_file = b.path("src/textmate/import.zig") });
    wasm_mod.addAnonymousImport("zig_real_textmate_plist_source", .{ .root_source_file = b.path("src/textmate/plist.zig") });
    wasm_mod.addAnonymousImport("zig_real_dsl_source", .{ .root_source_file = b.path("src/native/dsl.zig") });
    wasm_mod.addAnonymousImport("zig_real_sublime_source", .{ .root_source_file = b.path("src/sublime/import.zig") });
    wasm_mod.addAnonymousImport("zig_real_tree_sitter_source", .{ .root_source_file = b.path("src/tree_sitter/root.zig") });
    wasm_mod.addAnonymousImport("zig_real_engine_source", .{ .root_source_file = b.path("src/runtime/engine.zig") });
    wasm_mod.addAnonymousImport("bash_real_gate_source", .{ .root_source_file = b.path("benchmark/gate.sh") });
    wasm_mod.addAnonymousImport("bash_real_integrations_source", .{ .root_source_file = b.path("tools/check_integrations.sh") });
    wasm_mod.addAnonymousImport("bash_real_lines_source", .{ .root_source_file = b.path("tools/check_file_lines.sh") });
    wasm_mod.addAnonymousImport("bash_real_compare_source", .{ .root_source_file = b.path("benchmark/run_compare.sh") });
    wasm_mod.addAnonymousImport("javascript_real_visual_source", .{ .root_source_file = b.path("benchmark/visual_compare.mjs") });
    wasm_mod.addAnonymousImport("javascript_real_diff_source", .{ .root_source_file = b.path("benchmark/differential_native.mjs") });
    wasm_mod.addAnonymousImport("javascript_real_shiki_source", .{ .root_source_file = b.path("benchmark/shiki.mjs") });
    wasm_mod.addAnonymousImport("javascript_real_wasm_source", .{ .root_source_file = b.path("benchmark/wasm.mjs") });
    wasm_mod.addAnonymousImport("json_real_package_lock_source", .{ .root_source_file = b.path("benchmark/package-lock.json") });
    wasm_mod.addAnonymousImport("json_real_textmate_source", .{ .root_source_file = b.path("grammars/textmate/json.tmLanguage.json") });
    wasm_mod.addAnonymousImport("rust_real_syntect_source", .{ .root_source_file = b.path("benchmark/syntect/src/main.rs") });
    wasm_mod.addAnonymousImport("toml_real_syntect_lock_source", .{ .root_source_file = b.path("benchmark/syntect/Cargo.lock") });
    wasm_mod.addAnonymousImport("toml_real_syntect_fancy_lock_source", .{ .root_source_file = b.path("benchmark/syntect_fancy/Cargo.lock") });
    wasm_mod.addAnonymousImport("toml_real_syntect_manifest_source", .{ .root_source_file = b.path("benchmark/syntect/Cargo.toml") });
    wasm_mod.addAnonymousImport("toml_real_syntect_fancy_manifest_source", .{ .root_source_file = b.path("benchmark/syntect_fancy/Cargo.toml") });
    wasm_mod.addAnonymousImport("yaml_real_ci_source", .{ .root_source_file = b.path(".github/workflows/ci.yml") });
    wasm_mod.addAnonymousImport("c_real_gzread_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/c_real_gzread.c") });
    wasm_mod.addAnonymousImport("python_real_requests_adapters_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/python_real_requests_adapters.py") });
    wasm_mod.addAnonymousImport("typescript_real_vscode_range_source", .{ .root_source_file = b.path("benchmark/corpus/third_party/typescript_real_vscode_range.ts") });
    const wasm_exe = b.addExecutable(.{
        .name = "zhl_wasm",
        .root_module = wasm_mod,
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build WASM ABI example");
    wasm_step.dependOn(&install_wasm.step);

    const api_wasm_selected_mod = b.createModule(.{
        .root_source_file = b.path("zig-out/grammars_selected/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
        },
    });
    const api_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/api_export.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
            .{ .name = "zhl_grammars_selected", .module = api_wasm_selected_mod },
        },
    });
    const api_wasm_exe = b.addExecutable(.{
        .name = "zhl_api",
        .root_module = api_wasm_mod,
    });
    api_wasm_exe.entry = .disabled;
    api_wasm_exe.rdynamic = true;
    api_wasm_exe.step.dependOn(&select_grammars_cmd.step);
    const install_api_wasm = b.addInstallArtifact(api_wasm_exe, .{});
    const wasm_api_step = b.step("wasm-api", "Build general-purpose WASM API module (-Dlangs=native|full|lang,lang,...)");
    wasm_api_step.dependOn(&install_api_wasm.step);

    const api_shared_selected_mod = b.createModule(.{
        .root_source_file = b.path("zig-out/grammars_selected/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
        },
    });
    const api_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/api_export.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zhl", .module = zhl_mod },
            .{ .name = "zhl_grammars", .module = grammars_mod },
            .{ .name = "zhl_grammars_selected", .module = api_shared_selected_mod },
        },
    });
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zhl",
        .root_module = api_shared_mod,
    });
    shared_lib.step.dependOn(&select_grammars_cmd.step);
    const install_shared = b.addInstallArtifact(shared_lib, .{});
    const shared_step = b.step("shared", "Build native shared library with C ABI (-Dlangs=native|full|lang,lang,...)");
    shared_step.dependOn(&install_shared.step);

    const wasm_bench_step = b.step("check-wasm-bench", "Run WASM benchmark row");
    const wasm_bench_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHL_WASM=\"$(realpath \"$1\")\" npm --prefix benchmark run wasm", "sh" });
    wasm_bench_cmd.addArtifactArg(wasm_exe);
    wasm_bench_step.dependOn(&wasm_bench_cmd.step);

    const tree_sitter_step = b.step("check-tree-sitter", "Run Tree-sitter parser-backed overlay proof");
    const tree_sitter_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHLC=\"$1\" npm --prefix benchmark run tree-sitter", "sh" });
    tree_sitter_cmd.addArtifactArg(check_zhlc);
    tree_sitter_step.dependOn(&tree_sitter_cmd.step);

    const compare_step = b.step("check-benchmark-compare", "Run external benchmark comparisons");
    const compare_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHL_SKIP_NATIVE_GATE=1 ZHL_SKIP_WASM=1 benchmark/run_compare.sh" });
    compare_step.dependOn(&compare_cmd.step);

    const v1_compare_cmd = b.addSystemCommand(&.{ "sh", "-c", "ZHL_SKIP_NATIVE_GATE=1 ZHL_SKIP_WASM=1 benchmark/run_compare.sh" });
    v1_compare_cmd.step.dependOn(&bench_gate_cmd.step);

    const v1_step = b.step("check-v1", "Run v1 release validation gates");
    v1_step.dependOn(b.getInstallStep());
    v1_step.dependOn(test_step);
    v1_step.dependOn(shiki_ecosystem_step);
    v1_step.dependOn(differential_step);
    v1_step.dependOn(visual_step);
    v1_step.dependOn(bench_cases_step);
    v1_step.dependOn(onig_cases_step);
    v1_step.dependOn(bench_gate_step);
    v1_step.dependOn(wasm_bench_step);
    v1_step.dependOn(tree_sitter_step);
    v1_step.dependOn(&v1_compare_cmd.step);

    const universal_offline_step = b.step("check-universal-offline", "Run universal offline compatibility gates");
    universal_offline_step.dependOn(v1_step);
    universal_offline_step.dependOn(corpus_cache_step);
    universal_offline_step.dependOn(corpus_regex_patterns_step);
    universal_offline_step.dependOn(runtime_boundary_step);
    universal_offline_step.dependOn(compatibility_summary_step);
    universal_offline_step.dependOn(oracle_spans_step);
}

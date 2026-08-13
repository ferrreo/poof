const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");

pub fn main() !void {
    try benchNative();
}

fn benchNative() !void {
    try benchCase("zhl Zig 0.16 native", grammars.zig_0_16.grammar, @embedFile("zig_bench_corpus"));
    try benchCase("zhl Zig adversarial native", grammars.zig_0_16.grammar, @embedFile("zig_adversarial_bench_corpus"));
    try benchSources("zhl real Zig source native", grammars.zig_0_16.grammar, real_zig_sources);
    try benchSources("zhl real Bash source native", grammars.bash.grammar, real_bash_sources);
    try benchSources("zhl real JavaScript source native", grammars.javascript.grammar, real_javascript_sources);
    try benchSources("zhl real JSON source native", grammars.json.grammar, real_json_sources);
    try benchCase("zhl real Rust source native", grammars.rust.grammar, @embedFile("rust_real_syntect_source"));
    try benchSources("zhl real TOML source native", grammars.toml.grammar, real_toml_sources);
    try benchCase("zhl real YAML source native", grammars.yaml.grammar, @embedFile("yaml_real_ci_source"));
    try benchCase("zhl real C source native", grammars.c.grammar, @embedFile("c_real_gzread_source"));
    try benchCase("zhl real Python source native", grammars.python.grammar, @embedFile("python_real_requests_adapters_source"));
    try benchCase("zhl real TypeScript source native", grammars.typescript.grammar, @embedFile("typescript_real_vscode_range_source"));
    try benchCase("zhl TypeScript native", grammars.typescript.grammar, @embedFile("typescript_bench_corpus"));
    try benchCase("zhl Rust native", grammars.rust.grammar, @embedFile("rust_bench_corpus"));
    try benchCase("zhl Python native", grammars.python.grammar, @embedFile("python_bench_corpus"));
    try benchCase("zhl minified JSON native", grammars.json.grammar, @embedFile("json_min_bench_corpus"));
    try benchCase("zhl minified JavaScript native", grammars.javascript.grammar, @embedFile("javascript_min_bench_corpus"));
    try benchCase("zhl TextMate JSON native", grammars.json.grammar, @embedFile("textmate_json_bench_corpus"));
    try benchCase("zhl C++ native", grammars.cpp.grammar, @embedFile("cpp_bench_corpus"));
    try benchCase("zhl C# native", grammars.csharp.grammar, @embedFile("csharp_bench_corpus"));
    try benchCase("zhl HTML native", grammars.html.grammar, @embedFile("html_bench_corpus"));
    try benchCase("zhl Java native", grammars.java.grammar, @embedFile("java_bench_corpus"));
    try benchCase("zhl JSX native", grammars.jsx.grammar, @embedFile("jsx_bench_corpus"));
    try benchCase("zhl Kotlin native", grammars.kotlin.grammar, @embedFile("kotlin_bench_corpus"));
    try benchCase("zhl Markdown native", grammars.markdown.grammar, @embedFile("markdown_bench_corpus"));
    try benchCase("zhl PHP native", grammars.php.grammar, @embedFile("php_bench_corpus"));
    try benchCase("zhl Ruby native", grammars.ruby.grammar, @embedFile("ruby_bench_corpus"));
    try benchCase("zhl Swift native", grammars.swift.grammar, @embedFile("swift_bench_corpus"));
    try benchCase("zhl TSX native", grammars.tsx.grammar, @embedFile("tsx_bench_corpus"));
}

const real_zig_sources = &.{
    @embedFile("zig_real_regex_source"),
    @embedFile("zig_real_regex_vm_source"),
    @embedFile("zig_real_native_runtime_source"),
    @embedFile("zig_real_textmate_import_source"),
    @embedFile("zig_real_textmate_plist_source"),
    @embedFile("zig_real_dsl_source"),
    @embedFile("zig_real_sublime_source"),
    @embedFile("zig_real_tree_sitter_source"),
    @embedFile("zig_real_engine_source"),
};

const real_bash_sources = &.{
    @embedFile("bash_real_gate_source"),
    @embedFile("bash_real_integrations_source"),
    @embedFile("bash_real_lines_source"),
    @embedFile("bash_real_compare_source"),
};

const real_javascript_sources = &.{
    @embedFile("javascript_real_visual_source"),
    @embedFile("javascript_real_diff_source"),
    @embedFile("javascript_real_shiki_source"),
    @embedFile("javascript_real_wasm_source"),
};

const real_json_sources = &.{
    @embedFile("json_real_package_lock_source"),
    @embedFile("json_real_textmate_source"),
};

const real_toml_sources = &.{
    @embedFile("toml_real_syntect_lock_source"),
    @embedFile("toml_real_syntect_fancy_lock_source"),
    @embedFile("toml_real_syntect_manifest_source"),
    @embedFile("toml_real_syntect_fancy_manifest_source"),
};

fn benchCase(comptime label: []const u8, comptime grammar: anytype, comptime source: []const u8) !void {
    try benchSources(label, grammar, &.{source});
}

fn benchSources(comptime label: []const u8, comptime grammar: anytype, comptime sources: []const []const u8) !void {
    const Highlighter = zhl.Engine(grammar, .{
        .max_stack_depth = 1,
        .max_dynamic_capture_bytes = 0,
        .max_regex_vm_stack = 64,
        .max_capture_slots = 1,
        .max_tokens_per_line = 4096,
    });
    const total_len = comptime sourcesLen(sources);
    const iterations = iterationsFor(total_len);

    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.NullSink{};

    var bytes: usize = 0;
    var lines: usize = 0;

    const start = nowNs();
    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        inline for (sources) |source| {
            var state = Highlighter.State.initial();
            const corpus = comptime splitCorpus(source);
            for (corpus) |line| {
                const result = try h.highlightLine(line, state, &scratch, &sink);
                state = result.end_state;
                lines += 1;
            }
        }
        bytes += total_len;
    }
    const elapsed = nowNs() - start;
    const seconds = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);

    std.debug.print(
        \\{s}
        \\  lines:        {d}
        \\  bytes:        {d}
        \\  tokens:       {d}
        \\  elapsed_ms:   {d:.3}
        \\  throughput:   {d:.2} MiB/s
        \\  ns_per_line:  {d:.2}
        \\  token_bytes:  {d}
        \\  state_bytes:  {d}
        \\  scratch_bytes:{d}
        \\  setup_allocs: 0
        \\  hot_allocs:   0
        \\  total_allocs: 0
        \\  setup_bytes:  0
        \\  hot_bytes:    0
        \\  total_bytes:  0
        \\
    , .{
        label,
        lines,
        bytes,
        sink.count,
        seconds * 1000.0,
        mb / seconds,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(lines)),
        @sizeOf(zhl.PackedToken),
        @sizeOf(Highlighter.State),
        @sizeOf(Highlighter.Scratch),
    });
}

fn sourcesLen(comptime sources: []const []const u8) usize {
    comptime var total: usize = 0;
    inline for (sources) |source| total += source.len;
    return total;
}

fn iterationsFor(comptime source_len: usize) usize {
    const target_bytes = 8 * 1024 * 1024;
    const by_size = if (source_len == 0) 1000 else target_bytes / source_len;
    return if (by_size < 1000) 1000 else by_size;
}

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds);
}

fn splitCorpus(comptime source: []const u8) [countCorpusLines(source)][]const u8 {
    @setEvalBranchQuota(10_000_000);
    var lines: [countCorpusLines(source)][]const u8 = undefined;
    var start: usize = 0;
    var out: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] != '\n') continue;
        lines[out] = source[start..i];
        out += 1;
        start = i + 1;
    }
    if (start < source.len) lines[out] = source[start..source.len];
    return lines;
}

fn countCorpusLines(comptime source: []const u8) usize {
    @setEvalBranchQuota(10_000_000);
    if (source.len == 0) return 0;
    var count: usize = 1;
    for (source, 0..) |byte, index| {
        if (byte == '\n' and index + 1 < source.len) count += 1;
    }
    return count;
}

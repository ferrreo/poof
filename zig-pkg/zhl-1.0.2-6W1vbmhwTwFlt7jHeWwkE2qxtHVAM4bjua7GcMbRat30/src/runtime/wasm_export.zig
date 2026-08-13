const zhl = @import("zhl");
const grammars = @import("zhl_grammars");

const zig_source = @embedFile("zig_bench_corpus");
const zig_adversarial_source = @embedFile("zig_adversarial_bench_corpus");
const typescript_source = @embedFile("typescript_bench_corpus");
const rust_source = @embedFile("rust_bench_corpus");
const python_source = @embedFile("python_bench_corpus");
const json_min_source = @embedFile("json_min_bench_corpus");
const javascript_min_source = @embedFile("javascript_min_bench_corpus");
const textmate_json_source = @embedFile("textmate_json_bench_corpus");
const cpp_source = @embedFile("cpp_bench_corpus");
const csharp_source = @embedFile("csharp_bench_corpus");
const html_source = @embedFile("html_bench_corpus");
const java_source = @embedFile("java_bench_corpus");
const jsx_source = @embedFile("jsx_bench_corpus");
const kotlin_source = @embedFile("kotlin_bench_corpus");
const markdown_source = @embedFile("markdown_bench_corpus");
const php_source = @embedFile("php_bench_corpus");
const ruby_source = @embedFile("ruby_bench_corpus");
const swift_source = @embedFile("swift_bench_corpus");
const tsx_source = @embedFile("tsx_bench_corpus");

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

var last_error: u32 = 0;

pub export fn zhl_token_abi_size() usize {
    return @sizeOf(zhl.wasm.TokenAbi);
}

pub export fn zhl_packed_token_size() usize {
    return @sizeOf(zhl.PackedToken);
}

pub export fn zhl_style_keyword() u16 {
    return @intFromEnum(zhl.StyleId.keyword);
}

pub export fn zhl_wasm_case_count() u32 {
    return 29;
}

pub export fn zhl_wasm_corpus_lines(case_id: u32) u32 {
    return switch (case_id) {
        0 => countCorpusLines(zig_source),
        1 => countCorpusLines(zig_adversarial_source),
        2 => countSourcesLines(real_zig_sources),
        3 => countSourcesLines(real_bash_sources),
        4 => countSourcesLines(real_javascript_sources),
        5 => countSourcesLines(real_json_sources),
        6 => countCorpusLines(@embedFile("rust_real_syntect_source")),
        7 => countSourcesLines(real_toml_sources),
        8 => countCorpusLines(@embedFile("yaml_real_ci_source")),
        9 => countCorpusLines(@embedFile("c_real_gzread_source")),
        10 => countCorpusLines(@embedFile("python_real_requests_adapters_source")),
        11 => countCorpusLines(@embedFile("typescript_real_vscode_range_source")),
        12 => countCorpusLines(typescript_source),
        13 => countCorpusLines(rust_source),
        14 => countCorpusLines(python_source),
        15 => countCorpusLines(json_min_source),
        16 => countCorpusLines(javascript_min_source),
        17 => countCorpusLines(textmate_json_source),
        18 => countCorpusLines(cpp_source),
        19 => countCorpusLines(csharp_source),
        20 => countCorpusLines(html_source),
        21 => countCorpusLines(java_source),
        22 => countCorpusLines(jsx_source),
        23 => countCorpusLines(kotlin_source),
        24 => countCorpusLines(markdown_source),
        25 => countCorpusLines(php_source),
        26 => countCorpusLines(ruby_source),
        27 => countCorpusLines(swift_source),
        28 => countCorpusLines(tsx_source),
        else => 0,
    };
}

pub export fn zhl_wasm_corpus_bytes(case_id: u32) u32 {
    return switch (case_id) {
        0 => zig_source.len,
        1 => zig_adversarial_source.len,
        2 => sourcesLen(real_zig_sources),
        3 => sourcesLen(real_bash_sources),
        4 => sourcesLen(real_javascript_sources),
        5 => sourcesLen(real_json_sources),
        6 => @embedFile("rust_real_syntect_source").len,
        7 => sourcesLen(real_toml_sources),
        8 => @embedFile("yaml_real_ci_source").len,
        9 => @embedFile("c_real_gzread_source").len,
        10 => @embedFile("python_real_requests_adapters_source").len,
        11 => @embedFile("typescript_real_vscode_range_source").len,
        12 => typescript_source.len,
        13 => rust_source.len,
        14 => python_source.len,
        15 => json_min_source.len,
        16 => javascript_min_source.len,
        17 => textmate_json_source.len,
        18 => cpp_source.len,
        19 => csharp_source.len,
        20 => html_source.len,
        21 => java_source.len,
        22 => jsx_source.len,
        23 => kotlin_source.len,
        24 => markdown_source.len,
        25 => php_source.len,
        26 => ruby_source.len,
        27 => swift_source.len,
        28 => tsx_source.len,
        else => 0,
    };
}

pub export fn zhl_wasm_last_error() u32 {
    return last_error;
}

pub export fn zhl_wasm_bench(iterations: u32) u32 {
    return zhl_wasm_bench_case(0, iterations);
}

pub export fn zhl_wasm_bench_case(case_id: u32, iterations: u32) u32 {
    return switch (case_id) {
        0 => bench(grammars.zig_0_16.grammar, &.{zig_source}, iterations),
        1 => bench(grammars.zig_0_16.grammar, &.{zig_adversarial_source}, iterations),
        2 => bench(grammars.zig_0_16.grammar, real_zig_sources, iterations),
        3 => bench(grammars.bash.grammar, real_bash_sources, iterations),
        4 => bench(grammars.javascript.grammar, real_javascript_sources, iterations),
        5 => bench(grammars.json.grammar, real_json_sources, iterations),
        6 => bench(grammars.rust.grammar, &.{@embedFile("rust_real_syntect_source")}, iterations),
        7 => bench(grammars.toml.grammar, real_toml_sources, iterations),
        8 => bench(grammars.yaml.grammar, &.{@embedFile("yaml_real_ci_source")}, iterations),
        9 => bench(grammars.c.grammar, &.{@embedFile("c_real_gzread_source")}, iterations),
        10 => bench(grammars.python.grammar, &.{@embedFile("python_real_requests_adapters_source")}, iterations),
        11 => bench(grammars.typescript.grammar, &.{@embedFile("typescript_real_vscode_range_source")}, iterations),
        12 => bench(grammars.typescript.grammar, &.{typescript_source}, iterations),
        13 => bench(grammars.rust.grammar, &.{rust_source}, iterations),
        14 => bench(grammars.python.grammar, &.{python_source}, iterations),
        15 => bench(grammars.json.grammar, &.{json_min_source}, iterations),
        16 => bench(grammars.javascript.grammar, &.{javascript_min_source}, iterations),
        17 => bench(grammars.json.grammar, &.{textmate_json_source}, iterations),
        18 => bench(grammars.cpp.grammar, &.{cpp_source}, iterations),
        19 => bench(grammars.csharp.grammar, &.{csharp_source}, iterations),
        20 => bench(grammars.html.grammar, &.{html_source}, iterations),
        21 => bench(grammars.java.grammar, &.{java_source}, iterations),
        22 => bench(grammars.jsx.grammar, &.{jsx_source}, iterations),
        23 => bench(grammars.kotlin.grammar, &.{kotlin_source}, iterations),
        24 => bench(grammars.markdown.grammar, &.{markdown_source}, iterations),
        25 => bench(grammars.php.grammar, &.{php_source}, iterations),
        26 => bench(grammars.ruby.grammar, &.{ruby_source}, iterations),
        27 => bench(grammars.swift.grammar, &.{swift_source}, iterations),
        28 => bench(grammars.tsx.grammar, &.{tsx_source}, iterations),
        else => 0,
    };
}

fn bench(comptime grammar: anytype, comptime sources: []const []const u8, iterations: u32) u32 {
    const Highlighter = zhl.Engine(grammar, .{
        .max_stack_depth = 1,
        .max_dynamic_capture_bytes = 0,
        .max_regex_vm_stack = 64,
        .max_capture_slots = 1,
        .max_tokens_per_line = 4096,
    });
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.NullSink{};
    last_error = 0;

    var n: u32 = 0;
    while (n < iterations) : (n += 1) {
        inline for (sources) |source| {
            const corpus = comptime splitCorpus(source);
            var state = Highlighter.State.initial();
            for (corpus) |line| {
                const result = h.highlightLine(line, state, &scratch, &sink) catch |err| {
                    last_error = wasmErrorCode(err);
                    return 0;
                };
                state = result.end_state;
            }
        }
    }
    return @intCast(sink.count);
}

fn wasmErrorCode(err: zhl.HighlightError) u32 {
    return switch (err) {
        error.StackOverflow => 1,
        error.DynamicCaptureOverflow => 2,
        error.RegexVmStackOverflow => 3,
        error.RegexCaptureOverflow => 4,
        error.RegexStepLimitExceeded => 5,
        error.TokenOverflow => 6,
        error.LineTooLong => 7,
        error.MalformedGrammar => 8,
    };
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

fn countSourcesLines(comptime sources: []const []const u8) u32 {
    var total: u32 = 0;
    inline for (sources) |source| total += @intCast(countCorpusLines(source));
    return total;
}

fn sourcesLen(comptime sources: []const []const u8) u32 {
    var total: u32 = 0;
    inline for (sources) |source| total += @intCast(source.len);
    return total;
}

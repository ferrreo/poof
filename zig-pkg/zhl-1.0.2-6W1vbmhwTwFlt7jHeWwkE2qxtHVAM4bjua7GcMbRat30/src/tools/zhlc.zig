const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");
const sublime_source = @import("sublime_source.zig");
const zig_emit = @import("zig_emit.zig");

const max_input_bytes = 64 * 1024 * 1024;
const max_output_bytes = 8 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const args = try collectArgs(init.gpa, init.minimal.args);
    defer freeArgs(init.gpa, args);

    if (args.len < 3 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try usage(init.io);
        return;
    }

    const command = args[1];
    const path = args[2];
    const report_missing = hasArg(args, "--missing");
    const report_skipped = hasArg(args, "--skipped");
    const report_json = hasArg(args, "--json");
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_input_bytes));
    defer init.gpa.free(input);

    if (commandOutput(command, "dump", "render-html", "render-ansi")) |output| {
        try runHighlight(init.io, init.gpa, args, input, output);
    } else if (std.mem.eql(u8, command, "dump-ir")) {
        const spec = try parseNativeSpec(init.gpa, input);
        defer init.gpa.destroy(spec);
        try dumpNativeIr(init.io, spec);
    } else if (std.mem.eql(u8, command, "check-native")) {
        const spec = try parseNativeSpec(init.gpa, input);
        defer init.gpa.destroy(spec);
        try printStdout(init.io, "native {s} rules={d}\n", .{ spec.slice(spec.name), spec.rule_count });
    } else if (std.mem.eql(u8, command, "check-zhlb")) {
        const header = try zhl.binary.inspect(input);
        try printStdout(init.io, "zhlb version={d} rules={d} scope_len={d} name_len={d}\n", .{
            zhl.binary.version,
            header.rule_count,
            header.grammar_scope_len,
            header.name_len,
        });
    } else if (std.mem.eql(u8, command, "pack-native")) {
        if (args.len < 4) {
            try usage(init.io);
            return error.MissingOutput;
        }
        const spec = try parseNativeSpec(init.gpa, input);
        defer init.gpa.destroy(spec);
        const buf = try allocOutputBuffer(init.gpa);
        defer init.gpa.free(buf);
        const packed_bytes = try zhl.binary.packNative(spec, buf);
        const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
        try file.writeStreamingAll(init.io, packed_bytes);
        try printStdout(init.io, "zhlb {s} bytes={d} rules={d}\n", .{ args[3], packed_bytes.len, spec.rule_count });
    } else if (std.mem.eql(u8, command, "compile-native")) {
        if (args.len < 4) {
            try usage(init.io);
            return error.MissingOutput;
        }
        const spec = try parseNativeSpec(init.gpa, input);
        defer init.gpa.destroy(spec);
        const buf = try allocOutputBuffer(init.gpa);
        defer init.gpa.free(buf);
        var writer = std.Io.Writer.fixed(buf);
        try zig_emit.nativeModule(&writer, spec);
        const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
        try file.writeStreamingAll(init.io, buf[0..writer.end]);
        try printStdout(init.io, "native-zig {s} bytes={d} rules={d}\n", .{ args[3], writer.end, spec.rule_count });
    } else if (std.mem.eql(u8, command, "convert-textmate-json")) {
        var summary = try zhl.textmate.summarizeJson(init.gpa, input);
        defer summary.deinit();
        try convertTextMate(init, args, summary);
    } else if (std.mem.eql(u8, command, "convert-textmate-plist")) {
        var summary = try zhl.textmate.summarizePlist(init.gpa, input);
        defer summary.deinit();
        try convertTextMate(init, args, summary);
    } else if (std.mem.eql(u8, command, "convert-sublime")) {
        if (args.len < 4) {
            try usage(init.io);
            return error.MissingOutput;
        }
        const source = try sublime_source.load(init.io, init.gpa, path, input);
        defer init.gpa.free(source);
        var summary = try zhl.sublime.summarizeYaml(init.gpa, source);
        defer summary.deinit();
        const buf = try allocOutputBuffer(init.gpa);
        defer init.gpa.free(buf);
        var writer = std.Io.Writer.fixed(buf);
        const stats = try zhl.sublime_convert.writeSublime(&writer, summary);
        const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
        try file.writeStreamingAll(init.io, buf[0..writer.end]);
        try printStdout(init.io, "converted-sublime {s} converted={d} skipped={d} structural={d}\n", .{ args[3], stats.converted, stats.skipped, stats.structural });
    } else if (std.mem.eql(u8, command, "check-textmate-json")) {
        var summary = try zhl.textmate.summarizeJson(init.gpa, input);
        defer summary.deinit();
        var external = std.ArrayList(zhl.textmate.Summary).empty;
        defer {
            for (external.items) |*item| item.deinit();
            external.deinit(init.gpa);
        }
        try collectExternalTextMateGrammars(init.io, init.gpa, args, summary.scope_name, &external);
        const buf = try allocOutputBuffer(init.gpa);
        defer init.gpa.free(buf);
        var writer = std.Io.Writer.fixed(buf);
        const stats = try zhl.textmate_convert.writeTextMate(&writer, summary, external.items);
        const counts = countTextMate(summary);
        const external_missing = zhl.textmate_reachability.unresolvedExternalIncludes(summary, external.items);
        try printStdout(init.io, "textmate-json {s} rules={d} converted={d} skipped={d} structural={d} match={d} begin_end={d} include={d} external_missing={d} injections={d}/{d}\n", .{
            summary.scope_name,
            summary.rules.len,
            stats.converted,
            stats.skipped,
            stats.structural,
            counts.match,
            counts.begin_end,
            counts.include,
            external_missing,
            summary.injections_applied,
            summary.injections_total,
        });
        if (external_missing != 0) return error.UnresolvedExternalInclude;
    } else if (std.mem.eql(u8, command, "report-textmate-json")) {
        var summary = try zhl.textmate.summarizeJson(init.gpa, input);
        defer summary.deinit();
        var external = std.ArrayList(zhl.textmate.Summary).empty;
        defer {
            for (external.items) |*item| item.deinit();
            external.deinit(init.gpa);
        }
        try collectExternalTextMateGrammars(init.io, init.gpa, args, summary.scope_name, &external);
        const report = analyzeTextMate(summary);
        const external_missing = zhl.textmate_reachability.unresolvedExternalIncludes(summary, external.items);
        if (report_json) {
            const stats = try textMateStats(init.gpa, summary, external.items);
            try writeTextMateJsonReport(init.io, summary, report, stats, external_missing);
            return;
        }
        try printStdout(init.io, "textmate-report {s} rules={d} patterns={d} supported={d} missing={d} external_missing={d} injections={d}/{d}\n", .{
            summary.scope_name,
            summary.rules.len,
            report.patterns,
            report.supported,
            report.missing,
            external_missing,
            summary.injections_applied,
            summary.injections_total,
        });
        if (report_missing) {
            try printMissingTextMate(init.io, summary);
            var missing_writer = StdoutWriter{ .io = init.io };
            try zhl.textmate_reachability.writeUnresolvedExternalIncludes(&missing_writer, summary, external.items);
        }
        if (report_skipped) {
            var skipped_writer = StdoutWriter{ .io = init.io };
            try zhl.textmate_convert.writeTextMateSkippedReport(&skipped_writer, summary, external.items);
        }
    } else if (std.mem.eql(u8, command, "check-textmate-plist")) {
        var summary = try zhl.textmate.summarizePlist(init.gpa, input);
        defer summary.deinit();
        var external = std.ArrayList(zhl.textmate.Summary).empty;
        defer {
            for (external.items) |*item| item.deinit();
            external.deinit(init.gpa);
        }
        try collectExternalTextMateGrammars(init.io, init.gpa, args, summary.scope_name, &external);
        var buf: [1024 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const stats = try zhl.textmate_convert.writeTextMate(&writer, summary, external.items);
        const counts = countTextMate(summary);
        const external_missing = zhl.textmate_reachability.unresolvedExternalIncludes(summary, external.items);
        try printStdout(init.io, "textmate-plist {s} rules={d} converted={d} skipped={d} structural={d} match={d} begin_end={d} include={d} external_missing={d} injections={d}/{d}\n", .{
            summary.scope_name,
            summary.rules.len,
            stats.converted,
            stats.skipped,
            stats.structural,
            counts.match,
            counts.begin_end,
            counts.include,
            external_missing,
            summary.injections_applied,
            summary.injections_total,
        });
        if (external_missing != 0) return error.UnresolvedExternalInclude;
    } else if (std.mem.eql(u8, command, "report-textmate-plist")) {
        var summary = try zhl.textmate.summarizePlist(init.gpa, input);
        defer summary.deinit();
        var external = std.ArrayList(zhl.textmate.Summary).empty;
        defer {
            for (external.items) |*item| item.deinit();
            external.deinit(init.gpa);
        }
        try collectExternalTextMateGrammars(init.io, init.gpa, args, summary.scope_name, &external);
        const report = analyzeTextMate(summary);
        const external_missing = zhl.textmate_reachability.unresolvedExternalIncludes(summary, external.items);
        if (report_json) {
            const stats = try textMateStats(init.gpa, summary, external.items);
            try writeTextMateJsonReport(init.io, summary, report, stats, external_missing);
            return;
        }
        try printStdout(init.io, "textmate-report {s} rules={d} patterns={d} supported={d} missing={d} external_missing={d} injections={d}/{d}\n", .{
            summary.scope_name,
            summary.rules.len,
            report.patterns,
            report.supported,
            report.missing,
            external_missing,
            summary.injections_applied,
            summary.injections_total,
        });
        if (report_missing) {
            try printMissingTextMate(init.io, summary);
            var missing_writer = StdoutWriter{ .io = init.io };
            try zhl.textmate_reachability.writeUnresolvedExternalIncludes(&missing_writer, summary, external.items);
        }
        if (report_skipped) {
            var skipped_writer = StdoutWriter{ .io = init.io };
            try zhl.textmate_convert.writeTextMateSkippedReport(&skipped_writer, summary, external.items);
        }
    } else if (std.mem.eql(u8, command, "check-sublime")) {
        const source = try sublime_source.load(init.io, init.gpa, path, input);
        defer init.gpa.free(source);
        var summary = try zhl.sublime.summarizeYaml(init.gpa, source);
        defer summary.deinit();
        var buf: [512 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const stats = try zhl.sublime_convert.writeSublime(&writer, summary);
        try printStdout(init.io, "sublime {s} rules={d} converted={d} skipped={d} structural={d}\n", .{ summary.scope, summary.rules.len, stats.converted, stats.skipped, stats.structural });
    } else if (std.mem.eql(u8, command, "report-sublime")) {
        const source = try sublime_source.load(init.io, init.gpa, path, input);
        defer init.gpa.free(source);
        var summary = try zhl.sublime.summarizeYaml(init.gpa, source);
        defer summary.deinit();
        const report = analyzeSublime(summary);
        if (report_json) {
            const stats = try sublimeStats(init.gpa, summary);
            try writeSublimeJsonReport(init.io, summary, report, stats);
            return;
        }
        try printStdout(init.io, "sublime-report {s} rules={d} patterns={d} supported={d} missing={d}\n", .{
            summary.scope,
            summary.rules.len,
            report.patterns,
            report.supported,
            report.missing,
        });
        if (report_missing) try printMissingSublime(init.io, summary);
        if (report_skipped) {
            var skipped_writer = StdoutWriter{ .io = init.io };
            try zhl.sublime_convert.writeSublimeSkippedReport(&skipped_writer, summary);
        }
    } else if (std.mem.eql(u8, command, "check-theme-json")) {
        const compiled = try zhl.theme.compileJson(init.gpa, input);
        try printStdout(init.io, "theme-json styles={d}\n", .{compiled.setCount()});
    } else if (std.mem.eql(u8, command, "check-theme-plist")) {
        const compiled = try zhl.textmate_plist.compileTheme(init.gpa, input);
        try printStdout(init.io, "theme-plist styles={d}\n", .{compiled.setCount()});
    } else if (std.mem.eql(u8, command, "compile-theme-json") or std.mem.eql(u8, command, "compile-theme-plist")) {
        if (args.len < 4) {
            try usage(init.io);
            return error.MissingOutput;
        }
        const compiled = if (std.mem.eql(u8, command, "compile-theme-json"))
            try zhl.theme.compileJson(init.gpa, input)
        else
            try zhl.textmate_plist.compileTheme(init.gpa, input);
        var buf: [128 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try zig_emit.themeModule(&writer, compiled);
        const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
        try file.writeStreamingAll(init.io, buf[0..writer.end]);
        try printStdout(init.io, "theme-zig {s} bytes={d} styles={d}\n", .{ args[3], writer.end, compiled.setCount() });
    } else {
        try usage(init.io);
        return error.UnknownCommand;
    }
}

const TextMateCounts = struct {
    match: usize = 0,
    begin_end: usize = 0,
    include: usize = 0,
};

fn convertTextMate(init: std.process.Init, args: []const []const u8, summary: zhl.textmate.Summary) !void {
    if (args.len < 4) {
        try usage(init.io);
        return error.MissingOutput;
    }
    var external = std.ArrayList(zhl.textmate.Summary).empty;
    defer {
        for (external.items) |*item| item.deinit();
        external.deinit(init.gpa);
    }
    try collectExternalTextMateGrammars(init.io, init.gpa, args, summary.scope_name, &external);
    const buf = try allocOutputBuffer(init.gpa);
    defer init.gpa.free(buf);
    var writer = std.Io.Writer.fixed(buf);
    const stats = try zhl.textmate_convert.writeTextMate(&writer, summary, external.items);
    const file = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
    try file.writeStreamingAll(init.io, buf[0..writer.end]);
    try printStdout(init.io, "converted-textmate {s} converted={d} skipped={d} structural={d}\n", .{ args[3], stats.converted, stats.skipped, stats.structural });
}

fn allocOutputBuffer(allocator: std.mem.Allocator) ![]u8 {
    return allocator.alloc(u8, max_output_bytes);
}

fn parseNativeSpec(allocator: std.mem.Allocator, input: []const u8) !*zhl.dsl.NativeSpec {
    const spec = try allocator.create(zhl.dsl.NativeSpec);
    errdefer allocator.destroy(spec);
    try zhl.dsl.parseInto(input, spec);
    return spec;
}

const ReportStats = struct {
    converted: usize,
    skipped: usize,
    structural: usize,
};

fn textMateStats(allocator: std.mem.Allocator, summary: zhl.textmate.Summary, external: []const zhl.textmate.Summary) !ReportStats {
    const buf = try allocOutputBuffer(allocator);
    defer allocator.free(buf);
    var writer = std.Io.Writer.fixed(buf);
    const stats = try zhl.textmate_convert.writeTextMate(&writer, summary, external);
    return .{ .converted = stats.converted, .skipped = stats.skipped, .structural = stats.structural };
}

fn sublimeStats(allocator: std.mem.Allocator, summary: zhl.sublime.Summary) !ReportStats {
    const buf = try allocOutputBuffer(allocator);
    defer allocator.free(buf);
    var writer = std.Io.Writer.fixed(buf);
    const stats = try zhl.sublime_convert.writeSublime(&writer, summary);
    return .{ .converted = stats.converted, .skipped = stats.skipped, .structural = stats.structural };
}

fn countTextMate(summary: zhl.textmate.Summary) TextMateCounts {
    var counts = TextMateCounts{};
    for (summary.rules) |rule| {
        switch (rule.kind) {
            .match => counts.match += 1,
            .begin_end, .while_rule => counts.begin_end += 1,
            .include => counts.include += 1,
            .repository => {},
        }
    }
    return counts;
}

fn dumpNativeIr(io: std.Io, spec: *const zhl.dsl.NativeSpec) !void {
    try printStdout(io, "ir schema=zhl.native-ir.v1 grammar=", .{});
    var writer = StdoutWriter{ .io = io };
    try writeJsonString(&writer, spec.slice(spec.grammar_scope));
    try writer.print(" name=", .{});
    try writeJsonString(&writer, spec.slice(spec.name));
    try writer.print(" root=", .{});
    try writeJsonString(&writer, spec.slice(spec.root_scope));
    try writer.print(" rules={d}\n", .{spec.rule_count});
    for (spec.ruleSlice(), 0..) |rule, index| {
        try writer.print("rule {d} kind={s} value=", .{ index, @tagName(rule.kind) });
        try writeJsonString(&writer, spec.slice(rule.value));
        try writer.print(" escape=", .{});
        try writeJsonString(&writer, spec.slice(rule.escape));
        try writer.print(" scope=", .{});
        try writeJsonString(&writer, spec.slice(rule.scope));
        try writer.print(" nested={}\n", .{rule.nested});
    }
}

const TextMateReport = struct {
    patterns: usize = 0,
    supported: usize = 0,
    missing: usize = 0,
};

fn writeTextMateJsonReport(io: std.Io, summary: zhl.textmate.Summary, report: TextMateReport, stats: ReportStats, external_missing: usize) !void {
    var writer = StdoutWriter{ .io = io };
    try writer.writeAll("{\"schema\":\"zhl.report.textmate.v1\",\"scope\":");
    try writeJsonString(&writer, summary.scope_name);
    try writer.print(",\"rules\":{d},\"patterns\":{d},\"supported\":{d},\"missing\":{d},\"external_missing\":{d},\"converted\":{d},\"skipped\":{d},\"structural\":{d},\"injections_applied\":{d},\"injections_total\":{d},\"accepted_divergence\":0,\"divergences\":[]}}\n", .{
        summary.rules.len,
        report.patterns,
        report.supported,
        report.missing,
        external_missing,
        stats.converted,
        stats.skipped,
        stats.structural,
        summary.injections_applied,
        summary.injections_total,
    });
}

fn writeSublimeJsonReport(io: std.Io, summary: zhl.sublime.Summary, report: TextMateReport, stats: ReportStats) !void {
    var writer = StdoutWriter{ .io = io };
    try writer.writeAll("{\"schema\":\"zhl.report.sublime.v1\",\"scope\":");
    try writeJsonString(&writer, summary.scope);
    try writer.print(",\"rules\":{d},\"patterns\":{d},\"supported\":{d},\"missing\":{d},\"converted\":{d},\"skipped\":{d},\"structural\":{d},\"accepted_divergence\":0,\"divergences\":[]}}\n", .{
        summary.rules.len,
        report.patterns,
        report.supported,
        report.missing,
        stats.converted,
        stats.skipped,
        stats.structural,
    });
}

fn writeJsonString(writer: *StdoutWriter, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0...0x1f => {
            const hex = "0123456789abcdef";
            const escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
            try writer.writeAll(escaped[0..]);
        },
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn analyzeTextMate(summary: zhl.textmate.Summary) TextMateReport {
    var report = TextMateReport{};
    if (summary.first_line_match) |pattern| analyzePattern(pattern, &report);
    for (summary.rules) |rule| {
        if (rule.pattern) |pattern| analyzePattern(pattern, &report);
        if (rule.end) |pattern| analyzeEndPattern(pattern, &report);
    }
    return report;
}

fn analyzeSublime(summary: zhl.sublime.Summary) TextMateReport {
    var report = TextMateReport{};
    for (summary.rules) |rule| {
        if (rule.match.len != 0) analyzeEndPattern(rule.match, &report);
        if (rule.escape.len != 0) analyzeEndPattern(rule.escape, &report);
    }
    return report;
}

fn analyzeEndPattern(pattern: []const u8, report: *TextMateReport) void {
    if (zhl.textmate_dynamic.parse(pattern) != null) {
        report.patterns += 1;
        report.supported += 1;
    } else analyzePattern(pattern, report);
}

fn analyzePattern(pattern: []const u8, report: *TextMateReport) void {
    report.patterns += 1;
    if (canCompilePattern(pattern)) {
        report.supported += 1;
    } else {
        report.missing += 1;
    }
}

fn printMissingTextMate(io: std.Io, summary: zhl.textmate.Summary) !void {
    if (summary.first_line_match) |pattern| try printMissingPattern(io, "firstLineMatch", pattern);
    for (summary.rules, 0..) |rule, index| {
        if (rule.pattern) |pattern| try printMissingRulePattern(io, index, "pattern", pattern);
        if (rule.end) |pattern| {
            if (zhl.textmate_dynamic.parse(pattern) == null) try printMissingRulePattern(io, index, "end", pattern);
        }
    }
}

fn printMissingSublime(io: std.Io, summary: zhl.sublime.Summary) !void {
    for (summary.rules, 0..) |rule, index| {
        if (rule.match.len != 0 and zhl.textmate_dynamic.parse(rule.match) == null) try printMissingRulePattern(io, index, "match", rule.match);
        if (rule.escape.len != 0 and zhl.textmate_dynamic.parse(rule.escape) == null) try printMissingRulePattern(io, index, "escape", rule.escape);
    }
}

fn printMissingRulePattern(io: std.Io, index: usize, field: []const u8, pattern: []const u8) !void {
    var label: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&label);
    try writer.print("rule[{d}].{s}", .{ index, field });
    try printMissingPattern(io, label[0..writer.end], pattern);
}

fn printMissingPattern(io: std.Io, label: []const u8, pattern: []const u8) !void {
    if (!canCompilePattern(pattern)) {
        try writeMissing(io, label, pattern);
        return;
    }
}

fn writeMissing(io: std.Io, label: []const u8, pattern: []const u8) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "missing ");
    try stdout.writeStreamingAll(io, label);
    try stdout.writeStreamingAll(io, " ");
    try stdout.writeStreamingAll(io, pattern);
    try stdout.writeStreamingAll(io, "\n");
}

fn canCompilePattern(pattern: []const u8) bool {
    _ = zhl.regex.Program(64).compile(pattern) catch {
        _ = zhl.regex_vm.Program(zhl.textmate_types.MaxRegexVmPattern).compile(pattern) catch |err| switch (err) {
            error.PatternTooLarge => _ = zhl.regex_vm.Program(zhl.textmate_types.MaxLargeRegexVmPattern).compile(pattern) catch return zhl.textmate_convert_regex.canSplitAlternation(pattern),
            else => return zhl.textmate_convert_regex.canSplitAlternation(pattern),
        };
    };
    return true;
}

fn usage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\usage:
        \\  zhlc dump SOURCE --grammar NAME
        \\  zhlc dump-ir FILE.zhl
        \\  zhlc render-html SOURCE --grammar NAME
        \\  zhlc render-ansi SOURCE --grammar NAME
        \\  zhlc check-native FILE.zhl
        \\  zhlc check-zhlb FILE.zhlb
        \\  zhlc pack-native FILE.zhl OUT.zhlb
        \\  zhlc compile-native FILE.zhl OUT.zig
        \\  zhlc convert-textmate-json FILE.json OUT.zhl [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc convert-textmate-plist FILE.tmLanguage OUT.zhl [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc convert-sublime FILE.sublime-syntax OUT.zhl
        \\  zhlc check-textmate-json FILE.json [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc report-textmate-json FILE.json [--json] [--missing] [--skipped] [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc check-textmate-plist FILE.tmLanguage [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc report-textmate-plist FILE.tmLanguage [--json] [--missing] [--skipped] [--include-grammar FILE] [--include-dir DIR]
        \\  zhlc check-sublime FILE.sublime-syntax
        \\  zhlc report-sublime FILE.sublime-syntax [--json] [--missing] [--skipped]
        \\  zhlc check-theme-json FILE.json
        \\  zhlc check-theme-plist FILE.tmTheme
        \\  zhlc compile-theme-json FILE.json OUT.zig
        \\  zhlc compile-theme-plist FILE.tmTheme OUT.zig
        \\
    );
}

fn runHighlight(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, source: []const u8, output: LineOutput) !void {
    const grammar_arg = argValue(args, "--grammar") orelse {
        try usage(io);
        return error.MissingGrammar;
    };
    const metadata = grammars.findByName(grammar_arg) orelse return error.UnsupportedGrammarFile;
    return runRegisteredGrammar(io, allocator, metadata.id, source, output);
}

const LineOutput = enum { dump, html, ansi };

fn collectExternalTextMateGrammars(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, root_scope: []const u8, out: *std.ArrayList(zhl.textmate.Summary)) !void {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--include-grammar")) {
            if (index + 1 >= args.len) return error.MissingGrammar;
            var summary = try summarizeTextMatePath(io, allocator, args[index + 1]);
            try appendExternalSummary(allocator, out, root_scope, &summary);
        } else if (std.mem.eql(u8, arg, "--include-dir")) {
            if (index + 1 >= args.len) return error.MissingGrammar;
            try collectExternalTextMateDir(io, allocator, args[index + 1], root_scope, out);
        }
    }
}

fn collectExternalTextMateDir(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, root_scope: []const u8, out: *std.ArrayList(zhl.textmate.Summary)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !isTextMateGrammarFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, textMateNameLessThan);

    for (names.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(path);
        var summary = try summarizeTextMatePath(io, allocator, path);
        try appendExternalSummary(allocator, out, root_scope, &summary);
    }
}

fn isTextMateGrammarFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".tmLanguage") or std.mem.endsWith(u8, name, ".tmLanguage.json");
}

fn textMateNameLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn appendExternalSummary(allocator: std.mem.Allocator, out: *std.ArrayList(zhl.textmate.Summary), root_scope: []const u8, summary: *zhl.textmate.Summary) !void {
    errdefer summary.deinit();
    if (std.mem.eql(u8, root_scope, summary.scope_name) or hasSummaryScope(out.items, summary.scope_name)) {
        summary.deinit();
        return;
    }
    try out.append(allocator, summary.*);
}

fn hasSummaryScope(items: []const zhl.textmate.Summary, scope: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.scope_name, scope)) return true;
    }
    return false;
}

fn summarizeTextMatePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !zhl.textmate.Summary {
    const grammar = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_input_bytes));
    defer allocator.free(grammar);
    if (std.mem.endsWith(u8, path, ".tmLanguage")) return try zhl.textmate.summarizePlist(allocator, grammar);
    if (std.mem.endsWith(u8, path, ".json")) return try zhl.textmate.summarizeJson(allocator, grammar);
    return error.UnsupportedGrammarFile;
}

fn runRegisteredGrammar(io: std.Io, allocator: std.mem.Allocator, id: grammars.LanguageId, source: []const u8, output: LineOutput) !void {
    return switch (id) {
        .bash => runNativeGrammar(io, allocator, grammars.bash.grammar, source, output),
        .c => runNativeGrammar(io, allocator, grammars.c.grammar, source, output),
        .cpp => runNativeGrammar(io, allocator, grammars.cpp.grammar, source, output),
        .csharp => runNativeGrammar(io, allocator, grammars.csharp.grammar, source, output),
        .css => runNativeGrammar(io, allocator, grammars.css.grammar, source, output),
        .go => runNativeGrammar(io, allocator, grammars.go.grammar, source, output),
        .html => runNativeGrammar(io, allocator, grammars.html.grammar, source, output),
        .java => runNativeGrammar(io, allocator, grammars.java.grammar, source, output),
        .javascript => runNativeGrammar(io, allocator, grammars.javascript.grammar, source, output),
        .jsx => runNativeGrammar(io, allocator, grammars.jsx.grammar, source, output),
        .json => runNativeGrammar(io, allocator, grammars.json.grammar, source, output),
        .kotlin => runNativeGrammar(io, allocator, grammars.kotlin.grammar, source, output),
        .log => runNativeGrammar(io, allocator, grammars.log.grammar, source, output),
        .markdown => runNativeGrammar(io, allocator, grammars.markdown.grammar, source, output),
        .php => runNativeGrammar(io, allocator, grammars.php.grammar, source, output),
        .python => runNativeGrammar(io, allocator, grammars.python.grammar, source, output),
        .ruby => runNativeGrammar(io, allocator, grammars.ruby.grammar, source, output),
        .rust => runNativeGrammar(io, allocator, grammars.rust.grammar, source, output),
        .sql => runNativeGrammar(io, allocator, grammars.sql.grammar, source, output),
        .swift => runNativeGrammar(io, allocator, grammars.swift.grammar, source, output),
        .toml => runNativeGrammar(io, allocator, grammars.toml.grammar, source, output),
        .tsx => runNativeGrammar(io, allocator, grammars.tsx.grammar, source, output),
        .typescript => runNativeGrammar(io, allocator, grammars.typescript.grammar, source, output),
        .xml => runNativeGrammar(io, allocator, grammars.xml.grammar, source, output),
        .yaml => runNativeGrammar(io, allocator, grammars.yaml.grammar, source, output),
        .zig => runNativeGrammar(io, allocator, grammars.zig_0_16.grammar, source, output),
    };
}

fn runNativeGrammar(io: std.Io, allocator: std.mem.Allocator, comptime grammar: anytype, source: []const u8, output: LineOutput) !void {
    const Highlighter = zhl.Engine(grammar, .{});
    const highlighter = try allocator.create(Highlighter);
    defer allocator.destroy(highlighter);
    highlighter.* = Highlighter.init(.{});
    const scratch = try allocator.create(Highlighter.Scratch);
    defer allocator.destroy(scratch);
    scratch.* = Highlighter.Scratch.init();
    const state = try allocator.create(Highlighter.State);
    defer allocator.destroy(state);
    state.* = Highlighter.State.initial();
    var line_it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var writer = StdoutWriter{ .io = io };
    const Sink = zhl.sinks.TokenBuffer(8192);
    const sink = try allocator.create(Sink);
    defer allocator.destroy(sink);

    while (line_it.next()) |line| : (line_no += 1) {
        sink.* = Sink.init();
        const result = try highlighter.highlightLine(line, state.*, scratch, sink);
        state.* = result.end_state;
        switch (output) {
            .dump => try zhl.renderers.renderDebugLine(&writer, line_no, sink.slice()),
            .html => {
                try zhl.renderers.renderHtmlLine(&writer, line, sink.slice());
                try writer.writeByte('\n');
            },
            .ansi => {
                try zhl.renderers.renderAnsiLine(&writer, line, sink.slice());
                try writer.writeByte('\n');
            },
        }
    }
}

const StdoutWriter = struct {
    io: std.Io,

    pub fn writeAll(self: *StdoutWriter, bytes: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
    }

    pub fn writeByte(self: *StdoutWriter, byte: u8) !void {
        const bytes = [_]u8{byte};
        try self.writeAll(bytes[0..]);
    }

    pub fn print(self: *StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn collectArgs(allocator: std.mem.Allocator, source: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(source, allocator);
    defer it.deinit();
    var args = std.ArrayList([]const u8).empty;
    errdefer freeArgs(allocator, args.items);
    while (it.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

fn argValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args[0..args.len -| 1], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) return args[index + 1];
    }
    return null;
}

fn commandOutput(command: []const u8, dump: []const u8, html: []const u8, ansi: []const u8) ?LineOutput {
    if (std.mem.eql(u8, command, dump)) return .dump;
    if (std.mem.eql(u8, command, html)) return .html;
    if (std.mem.eql(u8, command, ansi)) return .ansi;
    return null;
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

test "TextMate report counts supported patterns" {
    var summary = zhl.textmate.Summary{
        .allocator = std.testing.allocator,
        .scope_name = try std.testing.allocator.dupe(u8, "source.test"),
        .name = null,
        .first_line_match = try std.testing.allocator.dupe(u8, "^#!/usr/bin/env zig"),
        .rules = try std.testing.allocator.dupe(zhl.textmate.RuleSummary, &.{
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "//") },
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "a.*b") },
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "(?>a)") },
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "(a|b)+") },
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "\\p{L}") },
            .{ .kind = .match, .pattern = try std.testing.allocator.dupe(u8, "(?(1)yes|no)") },
            .{ .kind = .begin_end, .pattern = try std.testing.allocator.dupe(u8, "(EOF)"), .end = try std.testing.allocator.dupe(u8, "\\1") },
        }),
    };
    defer summary.deinit();

    const report = analyzeTextMate(summary);
    try std.testing.expectEqual(@as(usize, 9), report.patterns);
    try std.testing.expectEqual(@as(usize, 9), report.supported);
    try std.testing.expectEqual(@as(usize, 0), report.missing);
}

test "TextMate external report treats root scope as resolved" {
    var root = zhl.textmate.Summary{
        .allocator = std.testing.allocator,
        .scope_name = try std.testing.allocator.dupe(u8, "source.root"),
        .name = null,
        .first_line_match = null,
        .rules = try std.testing.allocator.dupe(zhl.textmate.RuleSummary, &.{
            .{ .kind = .include, .include = try std.testing.allocator.dupe(u8, "source.child") },
        }),
    };
    defer root.deinit();
    var child = zhl.textmate.Summary{
        .allocator = std.testing.allocator,
        .scope_name = try std.testing.allocator.dupe(u8, "source.child"),
        .name = null,
        .first_line_match = null,
        .rules = try std.testing.allocator.dupe(zhl.textmate.RuleSummary, &.{
            .{ .kind = .include, .include = try std.testing.allocator.dupe(u8, "source.root") },
        }),
    };
    defer child.deinit();

    try std.testing.expectEqual(@as(usize, 0), zhl.textmate_reachability.unresolvedExternalIncludes(root, &.{child}));
}

test "TextMate external report treats root repository includes as resolved" {
    var root = zhl.textmate.Summary{
        .allocator = std.testing.allocator,
        .scope_name = try std.testing.allocator.dupe(u8, "source.root"),
        .name = null,
        .first_line_match = null,
        .rules = try std.testing.allocator.dupe(zhl.textmate.RuleSummary, &.{
            .{ .kind = .include, .include = try std.testing.allocator.dupe(u8, "source.root#repo") },
        }),
    };
    defer root.deinit();

    try std.testing.expectEqual(@as(usize, 0), zhl.textmate_reachability.unresolvedExternalIncludes(root, &.{}));
}

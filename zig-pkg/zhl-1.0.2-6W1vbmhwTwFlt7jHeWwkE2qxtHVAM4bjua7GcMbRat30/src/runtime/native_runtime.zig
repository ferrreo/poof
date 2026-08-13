const std = @import("std");
const native_format = @import("../native/format.zig");

const zhl = struct {
    const ByteMask256 = @import("../ByteMask256.zig");
    const scan = @import("scan.zig");
    const style = @import("../theme/style.zig");
    const dsl = @import("../native/dsl.zig");
    const fast_regex = @import("fast_regex.zig");
    const rule_meta = @import("rule_meta.zig");
    const regex = @import("../regex/parser.zig");
    const regex_vm = @import("../regex/vm.zig");
    const regex_scratch = @import("../regex/scratch.zig");
    const textmate_dynamic = @import("../textmate/dynamic/root.zig");
    const sinks = @import("sinks.zig");
    const Engine = @import("engine.zig").Engine;
    const EngineOptions = @import("engine.zig").EngineOptions;
    const HighlightError = @import("engine.zig").HighlightError;
    const LineResult = @import("engine.zig").LineResult;
    const StyleId = style.StyleId;
    const ScopeStackId = style.ScopeStackId;
    const Token = @import("token.zig").Token;
};

pub const RuleKind = enum {
    line_comment,
    string,
    char,
    multiline_prefix,
    builtin_prefix,
    prefix_identifier,
    number,
    keywords,
    operators,
    function_call,
    capitalized_identifier,
    identifier_before,
    identifier_after,
    quoted_key_before,
    block_comment,
    regex_line_comment,
    regex_vm_line_comment,
    marker_string,
    regex,
    regex_vm,
    regex_block_comment,
    delimited,
    dynamic_block,
    regex_capture,
    regex_vm_capture,
    regex_vm_after_line_block,
    regex_vm_block,
    dotted_prefix_identifier,
};

pub const Rule = struct {
    kind: RuleKind,
    value: []const u8,
    scope: []const u8,
    escape: []const u8 = "",
    nested: bool = false,
};

fn regexVmLimit(comptime len: usize) comptime_int {
    return if (len <= 64) 64 else if (len <= 512) 512 else zhl.dsl.max_string_bytes;
}
pub fn Grammar(comptime grammar_name: []const u8, comptime root_scope: []const u8, comptime rules: []const Rule) type {
    return struct {
        pub const name = grammar_name;
        pub const scope_root = root_scope;

        const interesting = buildMask(rules);
        const fast_identifiers = canUseIdentifierFastPath(rules);

        pub fn highlightLine(
            comptime options: zhl.EngineOptions,
            line: []const u8,
            state: anytype,
            scratch: anytype,
            sink: anytype,
        ) zhl.HighlightError!zhl.LineResult(@TypeOf(state)) {
            @setEvalBranchQuota(10_000_000);
            var emitted: usize = 0;
            var i: usize = 0;
            var next_state = state;
            if (next_state.depth != 0) {
                const id = next_state.frames[0].context_id;
                inline for (rules, 0..) |rule, rule_index| {
                    if (id == rule_index + 1) {
                        const match = switch (rule.kind) {
                            .dynamic_block => scanDynamicBlock(rule, next_state, line, 0),
                            .regex_vm_block => try scanRegexVmBlock(rule, line, 0),
                            .regex_vm_after_line_block => try scanRegexVmAfterLineBlock(rule, line),
                            .block_comment, .regex_block_comment => scanBlock(rule, line, 0, @max(@as(u16, 1), next_state.frames[0].end_matcher_id)),
                            else => .{ .end = 0, .closed = true, .depth = 0 },
                        };
                        try emit(sink, 0, match.end, styleFromRule(rule), &emitted);
                        i = match.end;
                        if (!match.closed) return .{ .end_state = next_state, .token_count = emitted };
                        clearBlockState(&next_state);
                    }
                }
            }
            if (i == 0) {
                if (try tryAnchoredRule(options, line, &next_state, scratch, sink, &emitted)) |end| {
                    i = end;
                }
            }
            while (i < line.len) {
                const next = zhl.scan.findNextInteresting(interesting, line, i);
                if (next > i) {
                    try emit(sink, i, next, .plain, &emitted);
                    i = next;
                }
                if (i >= line.len) break;

                if (try tryRule(options, line, i, &next_state, scratch, sink, &emitted)) |end| {
                    i = end;
                } else if (line[i] == ' ' or line[i] == '\t') {
                    const end = zhl.scan.scanAsciiWhitespace(line, i);
                    try emit(sink, i, end, .plain, &emitted);
                    i = end;
                } else if (zhl.scan.isIdentStart(line[i])) {
                    const end = zhl.scan.scanAsciiIdentifier(line, i);
                    try emit(sink, i, end, .plain, &emitted);
                    i = end;
                } else {
                    try emit(sink, i, i + 1, .plain, &emitted);
                    i += 1;
                }
            }
            return .{ .end_state = next_state, .token_count = emitted };
        }
        fn tryAnchoredRule(comptime options: zhl.EngineOptions, line: []const u8, state: anytype, scratch: anytype, sink: anytype, emitted: *usize) zhl.HighlightError!?usize {
            @setEvalBranchQuota(10_000_000);
            _ = state;
            inline for (rules) |rule| {
                if (comptime rule.kind == .regex and zhl.rule_meta.regexIsAnchored(rule.value)) {
                    if (zhl.fast_regex.match(rule.value, line, 0)) |end| {
                        try emit(sink, 0, end, styleFromRule(rule), emitted);
                        return end;
                    }
                    const program = comptime zhl.regex.Program(64).compile(rule.value) catch unreachable;
                    var rule_scratch = zhl.regex_scratch.VmScratchView(options.max_regex_vm_stack).init(&scratch.regex_vm_stack);
                    if (try program.matchAt(line, 0, &rule_scratch)) |match| {
                        if (match.end > match.start and match.start == 0) {
                            try emit(sink, 0, match.end, styleFromRule(rule), emitted);
                            return match.end;
                        }
                    }
                }
            }
            return null;
        }

        fn tryRule(comptime options: zhl.EngineOptions, line: []const u8, start: usize, state: anytype, scratch: anytype, sink: anytype, emitted: *usize) zhl.HighlightError!?usize {
            @setEvalBranchQuota(10_000_000);
            if (fast_identifiers and zhl.scan.isIdentStart(line[start])) {
                return try tryIdentifierRules(line, start, sink, emitted);
            }
            inline for (rules, 0..) |rule, rule_index| {
                switch (rule.kind) {
                    .line_comment, .multiline_prefix => {
                        if (std.mem.startsWith(u8, line[start..], rule.value)) {
                            try emit(sink, start, line.len, styleFromRule(rule), emitted);
                            return line.len;
                        }
                    },
                    .regex_line_comment => {
                        const program = comptime zhl.regex.Program(64).compile(rule.value) catch unreachable;
                        var rule_scratch = zhl.regex_scratch.VmScratchView(options.max_regex_vm_stack).init(&scratch.regex_vm_stack);
                        if (try program.matchAt(line, start, &rule_scratch)) |open| {
                            if (open.start == start and open.end > start) {
                                try emit(sink, start, line.len, styleFromRule(rule), emitted);
                                return line.len;
                            }
                        }
                    },
                    .regex_vm_line_comment => vm: {
                        if (!zhl.rule_meta.regexMayStartByte(rule.value, line[start])) break :vm;
                        const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                        var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                        if (try program.matchAt(line, start, &regex_scratch)) |open| {
                            if (open.start == start and open.end > start) {
                                try emit(sink, start, line.len, styleFromRule(rule), emitted);
                                return line.len;
                            }
                        }
                    },
                    .block_comment => {
                        if (std.mem.startsWith(u8, line[start..], rule.value)) {
                            const match = scanBlock(rule, line, start + rule.value.len, 1);
                            try emit(sink, start, match.end, styleFromRule(rule), emitted);
                            if (!match.closed) setBlockState(state, rule_index, match.depth);
                            return match.end;
                        }
                    },
                    .regex_block_comment => {
                        const program = comptime zhl.regex.Program(64).compile(rule.value) catch unreachable;
                        var rule_scratch = zhl.regex_scratch.VmScratchView(options.max_regex_vm_stack).init(&scratch.regex_vm_stack);
                        if (try program.matchAt(line, start, &rule_scratch)) |open| {
                            if (open.start == start and open.end > start) {
                                const match = scanBlock(rule, line, open.end, 1);
                                try emit(sink, start, match.end, styleFromRule(rule), emitted);
                                if (!match.closed) setBlockState(state, rule_index, match.depth);
                                return match.end;
                            }
                        }
                    },
                    .dynamic_block => vm: {
                        if (!zhl.rule_meta.regexMayStartByte(rule.value, line[start])) break :vm;
                        const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                        var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                        var captures = [_]zhl.regex_vm.Capture{.{}} ** 16;
                        if (try program.matchAtCaptures(line, start, &regex_scratch, &captures)) |open| {
                            if (open.start == start and open.end > start) {
                                if (try dynamicState(state.*, rule, rule_index, line, &captures)) |dyn| {
                                    const match = scanDynamicBlock(rule, dyn, line, open.end);
                                    try emit(sink, start, match.end, styleFromRule(rule), emitted);
                                    if (!match.closed) state.* = dyn;
                                    return match.end;
                                }
                            }
                        }
                    },
                    .regex_vm_block => vm: {
                        if (!zhl.rule_meta.regexMayStartByte(rule.value, line[start])) break :vm;
                        const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                        var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                        if (try program.matchAt(line, start, &regex_scratch)) |open| {
                            if (open.start == start and open.end > start) {
                                const match = try scanRegexVmBlock(rule, line, open.end);
                                try emit(sink, start, match.end, styleFromRule(rule), emitted);
                                if (!match.closed) setBlockState(state, rule_index, 1);
                                return match.end;
                            }
                        }
                    },
                    .regex_vm_after_line_block => vm: {
                        if (!zhl.rule_meta.regexMayStartByte(rule.value, line[start])) break :vm;
                        const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                        var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                        if (try program.matchAt(line, start, &regex_scratch)) |open| {
                            if (open.start == start and open.end > start) setBlockState(state, rule_index, 1);
                        }
                    },
                    .string, .char => {
                        if (rule.value.len != 0 and std.mem.startsWith(u8, line[start..], rule.value)) {
                            const end = scanDelimited(line, start, rule.value, rule.value, rule.escape);
                            try native_format.emitDelimited(line, start, end, rule.value, rule.value, rule.escape, rule.kind == .string, styleFromRule(rule), sink, emitted);
                            return end;
                        }
                    },
                    .delimited => {
                        const pair = comptime delimitedPair(rule.value) orelse unreachable;
                        if (pair.open.len != 0 and std.mem.startsWith(u8, line[start..], pair.open)) {
                            const end = scanDelimited(line, start, pair.open, pair.close, rule.escape);
                            try native_format.emitDelimited(line, start, end, pair.open, pair.close, rule.escape, false, styleFromRule(rule), sink, emitted);
                            return end;
                        }
                    },
                    .marker_string => {
                        if (scanMarkerString(line, start, rule.value, rule.escape)) |end| {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .builtin_prefix, .prefix_identifier => {
                        if (std.mem.startsWith(u8, line[start..], rule.value)) {
                            const end = scanBuiltin(line, start + rule.value.len);
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .dotted_prefix_identifier => {
                        if (std.mem.startsWith(u8, line[start..], rule.value)) {
                            const end = scanDottedIdentifier(line, start + rule.value.len);
                            if (end > start + rule.value.len) {
                                try emit(sink, start, end, styleFromRule(rule), emitted);
                                return end;
                            }
                        }
                    },
                    .number => if (zhl.scan.isDigit(line[start])) {
                        const end = scanNumber(line, start);
                        try emit(sink, start, end, styleFromRule(rule), emitted);
                        return end;
                    },
                    .keywords => if (zhl.scan.isIdentStart(line[start])) {
                        const end = zhl.scan.scanAsciiIdentifier(line, start);
                        if (zhl.rule_meta.wordInSet(rule.value, line[start..end])) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .operators => {
                        const end = zhl.rule_meta.scanOperatorSet(rule.value, line, start);
                        if (end > start) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .function_call => if (zhl.scan.isIdentStart(line[start])) {
                        const end = zhl.scan.scanAsciiIdentifier(line, start);
                        const open = skipInlineWhitespace(line, end);
                        if (open < line.len and line[open] == '(') {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .capitalized_identifier => if (line[start] >= 'A' and line[start] <= 'Z') {
                        const end = zhl.scan.scanAsciiIdentifier(line, start);
                        try emit(sink, start, end, styleFromRule(rule), emitted);
                        return end;
                    },
                    .identifier_before => if (zhl.scan.isIdentStart(line[start])) {
                        const end = zhl.scan.scanAsciiIdentifier(line, start);
                        if (hasDelimiterAfter(line, end, rule.value)) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .identifier_after => if (zhl.scan.isIdentStart(line[start])) {
                        const end = zhl.scan.scanAsciiIdentifier(line, start);
                        if (hasDelimiterBefore(line, start, rule.value)) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .quoted_key_before => if (line[start] == '"' or line[start] == '\'') {
                        const end = scanDelimited(line, start, line[start .. start + 1], line[start .. start + 1], "\\");
                        if (hasDelimiterAfter(line, end, rule.value)) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .regex => {
                        if (zhl.fast_regex.match(rule.value, line, start)) |end| {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        } else {
                            const program = comptime zhl.regex.Program(64).compile(rule.value) catch unreachable;
                            var rule_scratch = zhl.regex_scratch.VmScratchView(options.max_regex_vm_stack).init(&scratch.regex_vm_stack);
                            if (try program.matchAt(line, start, &rule_scratch)) |match| {
                                if (match.end > match.start and match.start >= start) {
                                    if (match.start > start) try emit(sink, start, match.start, .plain, emitted);
                                    try emit(sink, match.start, match.end, styleFromRule(rule), emitted);
                                    return match.end;
                                }
                            }
                        }
                    },
                    .regex_vm => {
                        if (zhl.rule_meta.regexMayStartByte(rule.value, line[start])) {
                            const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                            var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                            if (try program.matchAt(line, start, &regex_scratch)) |match| {
                                if (match.end > match.start and match.start >= start) {
                                    if (match.start > start) try emit(sink, start, match.start, .plain, emitted);
                                    try emit(sink, match.start, match.end, styleFromRule(rule), emitted);
                                    return match.end;
                                }
                            }
                        }
                    },
                    .regex_capture => {
                        const program = comptime zhl.regex.Program(64).compile(rule.value) catch unreachable;
                        var rule_scratch = zhl.regex_scratch.VmScratchView(options.max_regex_vm_stack).init(&scratch.regex_vm_stack);
                        var captures = [_]zhl.regex.Capture{.{}} ** 16;
                        if (try program.matchAtCaptures(line, start, &rule_scratch, &captures)) |match| {
                            if (try emitCapturedMatch(rule, start, match.start, match.end, &captures, sink, emitted)) |end| return end;
                        }
                    },
                    .regex_vm_capture => vm: {
                        if (!zhl.rule_meta.regexMayStartByte(rule.value, line[start])) break :vm;
                        const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.value.len)).compile(rule.value) catch unreachable;
                        var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
                        var captures = [_]zhl.regex_vm.Capture{.{}} ** 16;
                        if (try program.matchAtCaptures(line, start, &regex_scratch, &captures)) |match| {
                            if (try emitCapturedMatch(rule, start, match.start, match.end, &captures, sink, emitted)) |end| return end;
                        }
                    },
                }
            }
            return null;
        }

        fn tryIdentifierRules(line: []const u8, start: usize, sink: anytype, emitted: *usize) zhl.HighlightError!?usize {
            @setEvalBranchQuota(10_000_000);
            const end = zhl.scan.scanAsciiIdentifier(line, start);
            inline for (rules) |rule| {
                switch (rule.kind) {
                    .keywords => {
                        if (zhl.rule_meta.wordInSet(rule.value, line[start..end])) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .function_call => {
                        const open = skipInlineWhitespace(line, end);
                        if (open < line.len and line[open] == '(') {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .capitalized_identifier => if (line[start] >= 'A' and line[start] <= 'Z') {
                        try emit(sink, start, end, styleFromRule(rule), emitted);
                        return end;
                    },
                    .identifier_before => {
                        if (hasDelimiterAfter(line, end, rule.value)) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    .identifier_after => {
                        if (hasDelimiterBefore(line, start, rule.value)) {
                            try emit(sink, start, end, styleFromRule(rule), emitted);
                            return end;
                        }
                    },
                    else => {},
                }
            }
            return null;
        }
    };
}
fn canUseIdentifierFastPath(comptime rules: []const Rule) bool {
    for (rules) |rule| {
        if (ruleMayStartIdentifier(rule)) return false;
    }
    return true;
}

fn ruleMayStartIdentifier(comptime rule: Rule) bool {
    return switch (rule.kind) {
        .keywords, .function_call, .capitalized_identifier, .identifier_before, .identifier_after => false,
        .regex, .regex_vm, .regex_capture, .regex_vm_capture, .regex_line_comment, .regex_vm_line_comment, .regex_block_comment, .dynamic_block, .regex_vm_block, .regex_vm_after_line_block => zhl.rule_meta.regexMayStartIdentifier(rule.value),
        .operators => zhl.rule_meta.operatorMayStartIdentifier(rule.value),
        else => rule.value.len > 0 and zhl.scan.isIdentStart(rule.value[0]),
    };
}
fn buildMask(comptime rules: []const Rule) zhl.ByteMask256 {
    @setEvalBranchQuota(10_000_000);
    var mask = zhl.ByteMask256.empty();
    for (rules) |rule| switch (rule.kind) {
        .line_comment, .string, .char, .delimited, .multiline_prefix, .builtin_prefix, .prefix_identifier, .dotted_prefix_identifier, .block_comment => if (rule.value.len > 0) mask.set(rule.value[0]),
        .marker_string => if (rule.value.len > 0) mask.set(rule.value[0]) else if (rule.escape.len > 0) mask.set(rule.escape[0]),
        .number => for ("0123456789") |byte| mask.set(byte),
        .keywords, .function_call, .identifier_before, .identifier_after => for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_") |byte| mask.set(byte),
        .capitalized_identifier => for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |byte| mask.set(byte),
        .operators => zhl.rule_meta.setOperatorStarts(rule.value, &mask),
        .quoted_key_before => {
            mask.set('"');
            mask.set('\'');
        },
        .regex => zhl.rule_meta.setRegexStartsNoAnchored(rule.value, &mask),
        .regex_vm, .regex_capture, .regex_vm_capture, .regex_line_comment, .regex_vm_line_comment, .regex_block_comment, .dynamic_block, .regex_vm_block, .regex_vm_after_line_block => zhl.rule_meta.setRegexStarts(rule.value, &mask),
    };
    return mask;
}

fn emit(sink: anytype, start: usize, end: usize, style_id: zhl.StyleId, emitted: *usize) zhl.HighlightError!void {
    if (end <= start) return;
    try sink.emit(.{
        .start = @intCast(start),
        .end = @intCast(end),
        .style_id = style_id,
        .scope_stack_id = zhl.style.scopeStackForStyle(style_id),
    });
    emitted.* += 1;
}
fn styleFromRule(comptime rule: Rule) zhl.StyleId {
    return comptime zhl.style.styleFromScope(rule.scope);
}

fn emitCapturedMatch(comptime rule: Rule, start: usize, match_start: usize, match_end: usize, captures: anytype, sink: anytype, emitted: *usize) zhl.HighlightError!?usize {
    if (match_end <= match_start or match_start < start) return null;
    const slot = parseCaptureSlot(rule.escape) orelse return null;
    if (slot >= captures.len or !captures[slot].set) return null;
    const capture = captures[slot];
    if (capture.end <= capture.start or capture.start < match_start or capture.end > match_end) return null;
    if (match_start > start) try emit(sink, start, match_start, .plain, emitted);
    if (capture.start > match_start) try emit(sink, match_start, capture.start, .plain, emitted);
    try emit(sink, capture.start, capture.end, styleFromRule(rule), emitted);
    if (capture.end < match_end) try emit(sink, capture.end, match_end, .plain, emitted);
    return match_end;
}

fn parseCaptureSlot(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var slot: usize = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return null;
        slot = slot * 10 + byte - '0';
    }
    return slot;
}

const DelimitedPair = struct { open: []const u8, close: []const u8 };

fn delimitedPair(value: []const u8) ?DelimitedPair {
    const split = std.mem.indexOfScalar(u8, value, '\n') orelse return null;
    return .{ .open = value[0..split], .close = value[split + 1 ..] };
}

fn scanDelimited(line: []const u8, start: usize, open: []const u8, close: []const u8, escape: []const u8) usize {
    var i = start + open.len;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], close)) return i + close.len;
        if (escape.len != 0 and std.mem.startsWith(u8, line[i..], escape)) {
            i += escape.len;
            if (i < line.len) i += 1;
            continue;
        }
        i += 1;
    }
    return line.len;
}

fn scanMarkerString(line: []const u8, start: usize, prefix: []const u8, config: []const u8) ?usize {
    if (config.len != 2 or !std.mem.startsWith(u8, line[start..], prefix)) return null;
    const delimiter = config[0];
    const marker = config[1];
    var open_end = start + prefix.len;
    while (open_end < line.len and line[open_end] == marker) : (open_end += 1) {}
    const marker_count = open_end - start - prefix.len;
    if (open_end >= line.len or line[open_end] != delimiter) return null;
    var pos = open_end + 1;
    while (pos < line.len) : (pos += 1) {
        if (line[pos] != delimiter) continue;
        var marker_pos = pos + 1;
        var count: usize = 0;
        while (count < marker_count and marker_pos < line.len and line[marker_pos] == marker) {
            count += 1;
            marker_pos += 1;
        }
        if (count == marker_count) return marker_pos;
    }
    return line.len;
}

fn scanBuiltin(line: []const u8, start: usize) usize {
    if (start < line.len and line[start] == '"') return scanDelimited(line, start, "\"", "\"", "\\");
    const end = zhl.scan.scanAsciiIdentifier(line, start);
    return if (end == start) start else end;
}

fn scanDottedIdentifier(line: []const u8, start: usize) usize {
    var end = zhl.scan.scanAsciiIdentifier(line, start);
    if (end == start) return start;
    while (end + 1 < line.len and line[end] == '.' and zhl.scan.isIdentStart(line[end + 1])) {
        end = zhl.scan.scanAsciiIdentifier(line, end + 1);
    }
    return end;
}

fn scanNumber(line: []const u8, start: usize) usize {
    return zhl.scan.scanGenericNumber(line, start);
}

fn skipInlineWhitespace(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn hasDelimiterAfter(line: []const u8, end: usize, delimiter: []const u8) bool {
    if (delimiter.len == 0) return false;
    const pos = skipInlineWhitespace(line, end);
    return std.mem.startsWith(u8, line[pos..], delimiter);
}

fn hasDelimiterBefore(line: []const u8, start: usize, delimiter: []const u8) bool {
    if (delimiter.len == 0 or start < delimiter.len) return false;
    var pos = start;
    while (pos > 0 and (line[pos - 1] == ' ' or line[pos - 1] == '\t')) : (pos -= 1) {}
    return pos >= delimiter.len and std.mem.eql(u8, line[pos - delimiter.len .. pos], delimiter);
}

const BlockMatch = struct {
    end: usize,
    closed: bool,
    depth: u16,
};

fn scanBlock(rule: Rule, line: []const u8, start: usize, initial_depth: u16) BlockMatch {
    if (rule.escape.len == 0) return .{ .end = line.len, .closed = false, .depth = initial_depth };
    if (!rule.nested) {
        if (std.mem.indexOf(u8, line[start..], rule.escape)) |offset| {
            return .{ .end = start + offset + rule.escape.len, .closed = true, .depth = 0 };
        }
        return .{ .end = line.len, .closed = false, .depth = initial_depth };
    }

    var depth = initial_depth;
    var i = start;
    while (i < line.len) {
        const open = std.mem.indexOf(u8, line[i..], rule.value);
        const close = std.mem.indexOf(u8, line[i..], rule.escape) orelse return .{ .end = line.len, .closed = false, .depth = depth };
        if (open != null and open.? < close) {
            if (depth != std.math.maxInt(u16)) depth += 1;
            i += open.? + rule.value.len;
        } else {
            depth -= 1;
            i += close + rule.escape.len;
            if (depth == 0) return .{ .end = i, .closed = true, .depth = 0 };
        }
    }
    return .{ .end = line.len, .closed = false, .depth = depth };
}

fn scanRegexVmAfterLineBlock(comptime rule: Rule, line: []const u8) zhl.HighlightError!BlockMatch {
    const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.escape.len)).compile(rule.escape) catch unreachable;
    var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
    if (comptime zhl.rule_meta.regexLineStartOnly(rule.escape)) {
        if (try program.matchAt(line, 0, &regex_scratch)) |match| {
            if (match.start == 0) return .{ .end = 0, .closed = true, .depth = 0 };
        }
        return .{ .end = line.len, .closed = false, .depth = 1 };
    }
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (i < line.len and !zhl.rule_meta.regexMayStartByte(rule.escape, line[i])) continue;
        if (try program.matchAt(line, i, &regex_scratch)) |match| {
            if (match.start == i) return .{ .end = i, .closed = true, .depth = 0 };
        }
        if (i == line.len) break;
    }
    return .{ .end = line.len, .closed = false, .depth = 1 };
}
fn scanRegexVmBlock(comptime rule: Rule, line: []const u8, start: usize) zhl.HighlightError!BlockMatch {
    const program = comptime zhl.regex_vm.Program(regexVmLimit(rule.escape.len)).compile(rule.escape) catch unreachable;
    var regex_scratch = zhl.regex_scratch.VmScratch(0).init();
    if (comptime zhl.rule_meta.regexLineStartOnly(rule.escape)) {
        if (start == 0) {
            if (try program.matchAt(line, 0, &regex_scratch)) |match| {
                if (match.start == 0) return .{ .end = match.end, .closed = true, .depth = 0 };
            }
        }
        return .{ .end = line.len, .closed = false, .depth = 1 };
    }
    var i = start;
    while (i <= line.len) : (i += 1) {
        if (i < line.len and !zhl.rule_meta.regexMayStartByte(rule.escape, line[i])) continue;
        if (try program.matchAt(line, i, &regex_scratch)) |match| {
            if (match.start == i) return .{ .end = match.end, .closed = true, .depth = 0 };
        }
        if (i == line.len) break;
    }
    return .{ .end = line.len, .closed = false, .depth = 1 };
}

fn dynamicState(state: anytype, rule: Rule, rule_index: usize, line: []const u8, captures: []const zhl.regex_vm.Capture) zhl.HighlightError!?@TypeOf(state) {
    const pattern = zhl.textmate_dynamic.parse(rule.escape) orelse unreachable;
    const storage = try zhl.textmate_dynamic.storeVm(pattern, captures, line) orelse return null;
    var out = state;
    const bytes = try zhl.textmate_dynamic.serializeStorage(storage, out.dynamic_captures[0..]);
    out.dynamic_capture_len = @intCast(bytes.len);
    out.depth = 1;
    out.frames[0] = .{ .context_id = @intCast(rule_index + 1), .end_matcher_id = 1 };
    out.fingerprint = fingerprintDynamic(rule_index, bytes);
    return out;
}

fn scanDynamicBlock(rule: Rule, state: anytype, line: []const u8, start: usize) BlockMatch {
    const pattern = zhl.textmate_dynamic.parse(rule.escape) orelse return .{ .end = line.len, .closed = false, .depth = 1 };
    const storage = dynamicStorage(state) orelse return .{ .end = line.len, .closed = false, .depth = 1 };
    if (pattern.anchor_start) {
        if (start == 0) {
            if (zhl.textmate_dynamic.match(storage, pattern, line, 0)) |end| return .{ .end = end, .closed = true, .depth = 0 };
        }
        return .{ .end = line.len, .closed = false, .depth = 1 };
    }
    var i = start;
    while (i <= line.len) : (i += 1) {
        if (zhl.textmate_dynamic.match(storage, pattern, line, i)) |end| return .{ .end = end, .closed = true, .depth = 0 };
        if (i == line.len) break;
    }
    return .{ .end = line.len, .closed = false, .depth = 1 };
}

fn dynamicStorage(state: anytype) ?zhl.textmate_dynamic.Storage {
    return zhl.textmate_dynamic.deserializeStorage(state.dynamic_captures[0..state.dynamic_capture_len]);
}

fn fingerprintDynamic(rule_index: usize, bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325 ^ @as(u64, @intCast(rule_index + 1));
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn setBlockState(state: anytype, rule_index: usize, depth: u16) void {
    state.depth = 1;
    state.frames[0] = .{ .context_id = @intCast(rule_index + 1), .end_matcher_id = depth };
    state.fingerprint = 0x9e3779b97f4a7c15 ^ @as(u64, @intCast(rule_index + 1)) ^ (@as(u64, depth) << 32);
}

fn clearBlockState(state: anytype) void {
    state.depth = 0;
    state.frames[0] = .{};
    state.fingerprint = 0;
}

test "native runtime highlights generated-style rules" {
    const rules = [_]Rule{
        .{ .kind = .keywords, .value = "const fn", .scope = "keyword.control.zig" },
        .{ .kind = .builtin_prefix, .value = "@", .scope = "support.function.builtin.zig" },
        .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.zig" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("const x = @import // hi", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expectEqual(zhl.ScopeStackId.keyword, sink.tokens[0].scope_stack_id);
    try std.testing.expect(hasStyle(sink.slice(), .builtin));
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[sink.count - 1].style_id);
}

test "native runtime tries anchored regexes that start with punctuation" {
    const rules = [_]Rule{
        .{ .kind = .regex, .value = "^>.*$", .scope = "comment.line.quote.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("> quoted", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[0].style_id);
    try std.testing.expectEqual(@as(u32, 0), sink.tokens[0].start);
    try std.testing.expectEqual(@as(u32, 8), sink.tokens[0].end);
}

test "native runtime honors configured regex VM stack" {
    const rules = [_]Rule{
        .{ .kind = .regex, .value = "\\w+(?=:)", .scope = "entity.name.label.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{ .max_regex_vm_stack = 128 });
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine(("a" ** 96) ++ ":", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.label, sink.tokens[0].style_id);
}

test "native runtime honors regex line comment opener" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm_line_comment, .value = "//[!/](?=[^/])", .scope = "comment.line.documentation.test" },
        .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("//! docs", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.doc_comment, sink.tokens[0].style_id);

    sink.reset();
    _ = try h.highlightLine("//// plain", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[0].style_id);
}

test "native runtime keeps block comment state" {
    const rules = [_]Rule{
        .{ .kind = .block_comment, .value = "/*", .escape = "*/", .scope = "comment.block.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("const /* open", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[sink.count - 1].style_id);

    sink.reset();
    const second = try h.highlightLine("close */ const", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[0].style_id);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[sink.count - 1].style_id);
}

test "native runtime honors regex block comment opener" {
    const rules = [_]Rule{
        .{ .kind = .regex_block_comment, .value = "/\\*\\*(?!/)", .escape = "*/", .scope = "comment.block.documentation.test" },
        .{ .kind = .block_comment, .value = "/*", .escape = "*/", .scope = "comment.block.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("/** doc */ /**/ ", Highlighter.State.initial(), &scratch, &sink);

    try std.testing.expectEqual(zhl.StyleId.doc_comment, sink.tokens[0].style_id);
    try expectTokenTextStyle("/** doc */ /**/ ", sink.slice(), "/**/", .comment);
}

test "native runtime keeps regex block comment state" {
    const rules = [_]Rule{
        .{ .kind = .regex_block_comment, .value = "/\\*\\*(?!/)", .escape = "*/", .scope = "comment.block.documentation.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("/** open", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);

    sink.reset();
    const second = try h.highlightLine("close */ const", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.doc_comment, sink.tokens[0].style_id);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[sink.count - 1].style_id);
}

test "native runtime keeps after-line regex block state" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm_after_line_block, .value = "^#if 0\\b", .escape = "(?=^#endif\\b)", .scope = "comment.block.preprocessor.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("#if 0", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);
    try std.testing.expect(!hasStyle(sink.slice(), .comment));

    sink.reset();
    const second = try h.highlightLine("const disabled", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[0].style_id);

    sink.reset();
    const third = try h.highlightLine("#endif", second.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), third.end_state.depth);
    try std.testing.expect(!hasStyle(sink.slice(), .comment));
}

test "native runtime keeps dynamic block state" {
    const rules = [_]Rule{
        .{ .kind = .dynamic_block, .value = "<<([A-Z]+)", .escape = "^\\1$", .scope = "string.unquoted.heredoc.test" },
        .{ .kind = .dynamic_block, .value = "<<-([A-Z]+)", .escape = "^\\t*\\1$", .scope = "string.unquoted.heredoc.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("cat <<EOF", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.string, sink.tokens[sink.count - 1].style_id);

    sink.reset();
    const second = try h.highlightLine("body", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.string, sink.tokens[0].style_id);

    sink.reset();
    const third = try h.highlightLine("EOF", second.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), third.end_state.depth);
    try expectTokenTextStyle("EOF", sink.slice(), "EOF", .string);

    sink.reset();
    _ = try h.highlightLine("const", third.end_state, &scratch, &sink);
    try expectTokenTextStyle("const", sink.slice(), "const", .keyword);

    sink.reset();
    const tab_first = try h.highlightLine("cat <<-END", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), tab_first.end_state.depth);

    sink.reset();
    const tab_second = try h.highlightLine("\x09body", tab_first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), tab_second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.string, sink.tokens[0].style_id);

    sink.reset();
    const tab_third = try h.highlightLine("\x09END", tab_second.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), tab_third.end_state.depth);
    try expectTokenTextStyle("\x09END", sink.slice(), "\x09END", .string);
}

test "native runtime closes prefixed dynamic alternatives" {
    const rules = [_]Rule{
        .{ .kind = .dynamic_block, .value = "<([A-Za-z]+)>", .escape = "</\\1\\s*>|/>", .scope = "meta.tag.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("<div>", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);

    sink.reset();
    const second = try h.highlightLine("</div   > const", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try expectTokenTextStyle("</div   > const", sink.slice(), "const", .keyword);

    sink.reset();
    const self_close = try h.highlightLine("<br>/> const", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), self_close.end_state.depth);
}

test "native runtime closes prefixed dynamic suffixes with empty capture" {
    const rules = [_]Rule{
        .{ .kind = .dynamic_block, .value = "[Rr]\"(-*)\\{", .escape = "}\\1\"", .scope = "string.quoted.other.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("R\"{", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);

    sink.reset();
    const second = try h.highlightLine("}\" const", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try expectTokenTextStyle("}\" const", sink.slice(), "const", .keyword);
}

test "native runtime persists dynamic guard captures" {
    const rules = [_]Rule{
        .{ .kind = .dynamic_block, .value = "(XX)(END)", .escape = "^((?!\\1)\\s+)?((\\2))$", .scope = "string.unquoted.guarded.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("XXEND", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);

    sink.reset();
    const guarded = try h.highlightLine("XXEND", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), guarded.end_state.depth);

    sink.reset();
    const closed = try h.highlightLine("  END", guarded.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), closed.end_state.depth);
    try expectTokenTextStyle("  END", sink.slice(), "  END", .string);
}

test "native runtime uses grammar-owned block nesting" {
    const rules = [_]Rule{
        .{ .kind = .block_comment, .value = "/*", .escape = "*/", .scope = "comment.block.test", .nested = true },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("/* outer /* inner */", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.frames[0].end_matcher_id);

    sink.reset();
    const second = try h.highlightLine("still */ const", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[0].style_id);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[sink.count - 1].style_id);

    const flat_rules = [_]Rule{
        .{ .kind = .block_comment, .value = "/*", .escape = "*/", .scope = "comment.block.test" },
        .{ .kind = .keywords, .value = "const", .scope = "keyword.control.test" },
    };
    const flat_grammar = Grammar("Flat", "source.test", &flat_rules){};
    const FlatHighlighter = zhl.Engine(flat_grammar, .{});
    var flat = FlatHighlighter.init(.{});
    var flat_scratch = FlatHighlighter.Scratch.init();
    var flat_sink = zhl.sinks.TokenBuffer(8).init();
    _ = try flat.highlightLine("/* outer /* inner */ const", FlatHighlighter.State.initial(), &flat_scratch, &flat_sink);
    try std.testing.expectEqual(zhl.StyleId.keyword, flat_sink.tokens[flat_sink.count - 1].style_id);
}

test "native runtime uses grammar-owned keyword and operator sets" {
    const rules = [_]Rule{
        .{ .kind = .keywords, .value = "alpha beta", .scope = "keyword.control.test" },
        .{ .kind = .operators, .value = ">> >= >", .scope = "keyword.operator.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("alpha >> gamma", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expectEqual(zhl.StyleId.operator, sink.tokens[2].style_id);
    try std.testing.expectEqual(@as(u32, 8), sink.tokens[2].end);
}

test "native runtime has generic key and call rules" {
    const rules = [_]Rule{
        .{ .kind = .quoted_key_before, .value = ":", .scope = "meta.mapping.key.json" },
        .{ .kind = .function_call, .value = "", .scope = "entity.name.function.test" },
        .{ .kind = .string, .value = "\"", .escape = "\\", .scope = "string.quoted.double.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(16).init();

    _ = try h.highlightLine("\"name\": call(\"value\")", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(zhl.StyleId.field, sink.tokens[0].style_id);
    try std.testing.expect(hasStyle(sink.slice(), .function));
    try std.testing.expect(hasStyle(sink.slice(), .string));
}

test "native runtime highlights dotted prefixed identifiers" {
    const rules = [_]Rule{
        .{ .kind = .dotted_prefix_identifier, .value = "@", .scope = "entity.name.function.decorator.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("@pkg.name.Decorator(value)", Highlighter.State.initial(), &scratch, &sink);
    try expectTokenTextStyle("@pkg.name.Decorator(value)", sink.slice(), "@pkg.name.Decorator", .function);
}

test "native runtime executes regex VM rules" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm, .value = "\\b(?<!_)(?:void|int)(?!_)\\b", .scope = "entity.name.type.test" },
        .{ .kind = .regex_vm, .value = "(?x)% (\\d+)? # field\n [s]", .scope = "constant.other.placeholder.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("x int voidish _int", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expectEqual(zhl.StyleId.type_name, sink.tokens[1].style_id);
    try std.testing.expectEqual(@as(u32, 2), sink.tokens[1].start);
    try std.testing.expectEqual(@as(u32, 5), sink.tokens[1].end);
    sink = zhl.sinks.TokenBuffer(8).init();
    _ = try h.highlightLine("printf %42s", Highlighter.State.initial(), &scratch, &sink);
    try expectTokenTextStyle("printf %42s", sink.slice(), "%42s", .format_placeholder);
}

test "native runtime honors regex keep start" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm, .value = "foo\\Kbar", .scope = "entity.name.function.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(4).init();
    const line = "foobar";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "foo", .plain);
    try expectTokenTextStyle(line, sink.slice(), "bar", .function);
}

test "native runtime starts regex keep escape" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm, .value = "\\Kbar", .scope = "entity.name.function.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(4).init();

    _ = try h.highlightLine("bar", Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle("bar", sink.slice(), "bar", .function);
}

test "native runtime starts escaped byte regex rules" {
    const rules = [_]Rule{
        .{ .kind = .regex, .value = "\\o{101}\\u0042", .scope = "keyword.control.test" },
        .{ .kind = .regex_vm, .value = "\\o{103}\\u0044", .scope = "entity.name.function.test" },
        .{ .kind = .regex_vm, .value = "(?W)EF", .scope = "constant.numeric.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    _ = try h.highlightLine("AB CD EF", Highlighter.State.initial(), &scratch, &sink);
    try expectTokenTextStyle("AB CD EF", sink.slice(), "AB", .keyword);
    try expectTokenTextStyle("AB CD EF", sink.slice(), "CD", .function);
    try expectTokenTextStyle("AB CD EF", sink.slice(), "EF", .number_integer);
}

test "native runtime emits captured regex groups only" {
    const rules = [_]Rule{
        .{ .kind = .regex_capture, .value = "(const) (name)", .escape = "2", .scope = "variable.other.test" },
        .{ .kind = .regex_vm_capture, .value = "(?<!\\w)(let)\\s+([A-Za-z_][A-Za-z0-9_]*)", .escape = "2", .scope = "entity.name.function.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(12).init();

    _ = try h.highlightLine("const name; let run", Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle("const name; let run", sink.slice(), "const ", .plain);
    try expectTokenTextStyle("const name; let run", sink.slice(), "name", .field);
    try expectTokenTextStyle("const name; let run", sink.slice(), "run", .function);
}

test "native runtime uses grammar-owned string escape" {
    const rules = [_]Rule{
        .{ .kind = .string, .value = "\"", .escape = "%", .scope = "string.quoted.test" },
        .{ .kind = .keywords, .value = "tail", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();
    const line = "\"a%\"b\" tail";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "\"a", .string);
    try expectTokenTextStyle(line, sink.slice(), "%\"", .escape);
    try expectTokenTextStyle(line, sink.slice(), "b\"", .string);
    try expectTokenTextStyle(line, sink.slice(), "tail", .keyword);
}

test "native runtime highlights asymmetric delimited strings" {
    const rules = [_]Rule{
        .{ .kind = .delimited, .value = "@\"\n\"", .escape = "\\", .scope = "variable.string.test" },
        .{ .kind = .keywords, .value = "tail", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();
    const line = "@\"a\\\"b\" tail";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "@\"a", .string);
    try expectTokenTextStyle(line, sink.slice(), "\\\"", .escape);
    try expectTokenTextStyle(line, sink.slice(), "b\"", .string);
    try expectTokenTextStyle(line, sink.slice(), "tail", .keyword);
}

test "native runtime highlights brace format placeholders" {
    const rules = [_]Rule{
        .{ .kind = .string, .value = "\"", .escape = "\\", .scope = "string.quoted.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();
    const line = "\"value={}\"";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "{}", .format_placeholder);
}

test "native runtime highlights marker-delimited strings" {
    const rules = [_]Rule{
        .{ .kind = .marker_string, .value = "r", .escape = "\"#", .scope = "string.quoted.double.raw.test" },
        .{ .kind = .keywords, .value = "tail", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();
    const line = "r##\"a\"#\"## tail";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "r##\"a\"#\"##", .string);
    try expectTokenTextStyle(line, sink.slice(), "tail", .keyword);
}

test "native runtime leaves nonmatching marker strings to later rules" {
    const rules = [_]Rule{
        .{ .kind = .marker_string, .value = "r", .escape = "\"#", .scope = "string.quoted.double.raw.test" },
        .{ .kind = .keywords, .value = "r", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();
    const line = "r tail";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "r", .keyword);
}

test "native runtime keeps regex VM block state" {
    const rules = [_]Rule{
        .{ .kind = .regex_vm_block, .value = "(?<!r)\"\"\"", .escape = "\"\"\"(?!\")", .scope = "string.quoted.multi.test" },
        .{ .kind = .keywords, .value = "tail", .scope = "keyword.control.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(8).init();

    const first = try h.highlightLine("\"\"\"open", Highlighter.State.initial(), &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 1), first.end_state.depth);
    try expectTokenTextStyle("\"\"\"open", sink.slice(), "\"\"\"open", .string);

    sink.reset();
    const second = try h.highlightLine("close\"\"\" tail", first.end_state, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 0), second.end_state.depth);
    try expectTokenTextStyle("close\"\"\" tail", sink.slice(), "close\"\"\"", .string);
    try expectTokenTextStyle("close\"\"\" tail", sink.slice(), "tail", .keyword);
}

test "native runtime scans generic number formats" {
    const rules = [_]Rule{
        .{ .kind = .number, .value = "generic", .scope = "constant.numeric.test" },
        .{ .kind = .operators, .value = "..", .scope = "keyword.operator.test" },
    };
    const grammar = Grammar("Test", "source.test", &rules){};
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(32).init();
    const line = "0x2a 0b1010 0o755 1_000 1.5e-10 42u32 42n 0x1.fp3 1..2";

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "0x2a", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "0b1010", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "0o755", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "1_000", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "1.5e-10", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "42u32", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "42n", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "0x1.fp3", .number_integer);
    try expectTokenTextStyle(line, sink.slice(), "..", .operator);
    try expectTokenTextStyle(line, sink.slice(), "2", .number_integer);
}

fn hasStyle(tokens: []const zhl.Token, style_id: zhl.StyleId) bool {
    for (tokens) |tok| if (tok.style_id == style_id) return true;
    return false;
}

fn expectTokenTextStyle(line: []const u8, tokens: []const zhl.Token, text: []const u8, style_id: zhl.StyleId) !void {
    for (tokens) |tok| {
        if (std.mem.eql(u8, line[tok.start..tok.end], text)) {
            try std.testing.expectEqual(style_id, tok.style_id);
            return;
        }
    }
    try std.testing.expect(false);
}

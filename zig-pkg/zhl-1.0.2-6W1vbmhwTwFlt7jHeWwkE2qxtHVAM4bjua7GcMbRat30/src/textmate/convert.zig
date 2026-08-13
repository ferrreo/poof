const std = @import("std");
const dsl = @import("../native/dsl.zig");
const convert_common = @import("../convert_common.zig");
const style = @import("../theme/style.zig");
const textmate = @import("root.zig");
const textmate_captures = @import("captures.zig");
const textmate_convert_emit = @import("convert_emit.zig");
const textmate_convert_regex = @import("convert_regex.zig");
const textmate_convert_blocks = @import("convert_blocks.zig");
const textmate_dynamic = @import("dynamic/root.zig");
const textmate_pattern = @import("pattern.zig");
const textmate_reachability = @import("reachability.zig");

const max_native_string = convert_common.max_native_string;
const writeDslString = convert_common.writeDslString;
const writeHeader = convert_common.writeHeader;
const writeMatchRule = convert_common.writeMatchRule;
const writeCaptureRule = convert_common.writeCaptureRule;
const DiscardWriter = convert_common.DiscardWriter;
pub const Stats = convert_common.Stats;
const RuleDisposition = convert_common.RuleDisposition;
pub fn writeTextMate(writer: anytype, root: textmate.Summary, external: []const textmate.Summary) !Stats {
    var stats = Stats{};
    try writeHeader(writer, root.scope_name, root.name orelse root.scope_name);
    try writeTextMateRules(writer, root, &stats);
    for (external) |summary| {
        if (textmate_reachability.externalReachable(root, summary.scope_name, external)) try writeTextMateRules(writer, summary, &stats);
    }
    try writer.writeAll("    }\n}\n");
    return stats;
}

pub fn writeTextMateSkippedReport(writer: anytype, root: textmate.Summary, external: []const textmate.Summary) !void {
    try writeTextMateSkippedReportOne(writer, root);
    for (external) |summary| {
        if (textmate_reachability.externalReachable(root, summary.scope_name, external)) try writeTextMateSkippedReportOne(writer, summary);
    }
}

fn writeTextMateRules(writer: anytype, summary: textmate.Summary, stats: *Stats) !void {
    for (summary.rules, 0..) |_, index| switch (try convertTextMateRule(writer, summary.scope_name, summary.rules, index)) {
        .converted => stats.converted += 1,
        .skipped => stats.skipped += 1,
        .structural => stats.structural += 1,
    };
}

fn writeTextMateSkippedReportOne(writer: anytype, summary: textmate.Summary) !void {
    var discard = DiscardWriter{};
    for (summary.rules, 0..) |rule, index| {
        if (try convertTextMateRule(&discard, summary.scope_name, summary.rules, index) == .skipped) {
            try writer.print("skipped-textmate {s} rule[{d}] kind={s} parent=", .{ summary.scope_name, index, @tagName(rule.kind) });
            if (rule.parent) |parent| try writer.print("{d}", .{parent}) else try writer.writeAll("none");
            try writeOptionalField(writer, " name=", rule.name);
            try writeOptionalField(writer, " content=", rule.content_name);
            try writeOptionalField(writer, " pattern=", rule.pattern);
            try writeOptionalField(writer, " end=", rule.end);
            try writer.writeByte('\n');
        }
    }
}

fn convertTextMateRule(writer: anytype, summary_scope: []const u8, rules: []const textmate.RuleSummary, index: usize) !RuleDisposition {
    const rule = rules[index];
    switch (rule.kind) {
        .match => {
            const pattern = rule.pattern orelse {
                return .structural;
            };
            const scope = rule.name orelse rule.capture_scope orelse summary_scope;
            return if (try writeMatchRule(writer, pattern, scope)) .converted else .skipped;
        },
        .begin_end => {
            if (isStructuralTextMateBlock(rule)) return .structural;
            const scope = rule.name orelse rule.content_name orelse summary_scope;
            const has_styled_captures = hasStyledBoundaryCapture(rule.pattern orelse "", rule.captures) or hasStyledBoundaryCapture(rule.end orelse "", rule.end_captures);
            return if (try writeBeginEndRule(writer, rule.pattern orelse "", rule.end orelse "", scope, has_styled_captures) or
                try writeBoundaryCaptureRules(writer, rule.pattern orelse "", rule.end orelse "", rule.captures, rule.end_captures) or
                try writeContextualLineBlockRule(writer, rules, index, scope))
                .converted
            else
                .skipped;
        },
        .while_rule => {
            if (isStructuralTextMateBlock(rule)) return .structural;
            const scope = rule.name orelse rule.content_name orelse summary_scope;
            return if (try writeWhileRule(writer, rule.pattern orelse "", rule.end orelse "", scope) or
                try writeBoundaryCaptureRules(writer, rule.pattern orelse "", rule.end orelse "", rule.captures, rule.end_captures))
                .converted
            else
                .skipped;
        },
        .include, .repository => return .structural,
    }
}

fn writeOptionalField(writer: anytype, label: []const u8, value: ?[]const u8) !void {
    if (value) |bytes| {
        try writer.writeAll(label);
        try writer.writeByte('"');
        try writer.writeAll(bytes);
        try writer.writeByte('"');
    }
}

fn isStructuralTextMateBlock(rule: textmate.RuleSummary) bool {
    const plain_scope = (rule.name == null or std.mem.startsWith(u8, rule.name.?, "meta.") or style.styleFromScope(rule.name.?) == .plain) and
        (rule.content_name == null or std.mem.startsWith(u8, rule.content_name.?, "meta.") or style.styleFromScope(rule.content_name.?) == .plain);
    return plain_scope and
        !hasStyledBoundaryCapture(rule.pattern orelse "", rule.captures) and
        !hasStyledBoundaryCapture(rule.end orelse "", rule.end_captures);
}

fn hasStyledBoundaryCapture(pattern: []const u8, captures: []const textmate_captures.CaptureEntry) bool {
    for (captures) |capture| {
        if (capture.style_id == .plain) continue;
        if (capture.slot == 0 or textmate_pattern.capturePattern(pattern, capture.slot) != null) return true;
    }
    return false;
}

fn writeBeginEndRule(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8, has_captures: bool) !bool {
    if (scope.len > max_native_string) return false;
    if (try writeBackrefLineDelimited(writer, begin, end, scope)) return true;
    if (!has_captures) if (textmate_pattern.zeroWidthBoundarySpan(begin, end)) |pattern| return try writeMatchRule(writer, pattern, scope);
    if (try writeDynamicBlockRule(writer, begin, end, scope)) return true;
    if (try writeRegexLookaheadSpan(writer, begin, end, scope, has_captures)) return true;
    if (!has_captures and try textmate_convert_regex.writeSplitAlternationBlockRules(writer, begin, end, scope)) return true;
    if (textmate_pattern.isNextLineStartEnd(end) and begin.len <= max_native_string) {
        const kind = if (textmate_pattern.canCompileNativeRegex(begin)) "regex_line_comment" else if (textmate_pattern.canCompileRegexVm(begin)) "regex_vm_line_comment" else return false;
        try textmate_convert_emit.rule1(writer, kind, begin, scope);
        return true;
    }
    if (textmate_convert_emit.contains(scope, "comment") and textmate_pattern.isLineEndPattern(end)) {
        var line_buf: [max_native_string]u8 = undefined;
        if (textmate_pattern.anchoredLiteral(begin, &line_buf) orelse
            textmate_pattern.regexLiteral(begin, &line_buf) orelse
            textmate_pattern.literalMarkerPrefix(begin, &line_buf)) |begin_lit|
        {
            if (begin_lit.len == 0) return false;
            try textmate_convert_emit.rule1(writer, "line_comment", begin_lit, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileNativeRegex(begin)) {
            try textmate_convert_emit.rule1(writer, "regex_line_comment", begin, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileRegexVm(begin)) {
            try textmate_convert_emit.rule1(writer, "regex_vm_line_comment", begin, scope);
            return true;
        }
        return false;
    }
    var line_end_literal_buf: [max_native_string]u8 = undefined;
    if (textmate_convert_emit.contains(scope, "string") and
        textmate_pattern.isLineEndPattern(end) and
        textmate_pattern.literalOrLineEnd(end, &line_end_literal_buf) == null)
    {
        var begin_buf: [max_native_string]u8 = undefined;
        if (textmate_pattern.anchoredLiteral(begin, &begin_buf) orelse textmate_pattern.regexLiteral(begin, &begin_buf)) |begin_lit| {
            if (begin_lit.len == 0) return false;
            try textmate_convert_emit.rule1(writer, "multiline_prefix", begin_lit, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileNativeRegex(begin)) {
            try textmate_convert_emit.rule1(writer, "regex_line_comment", begin, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileRegexVm(begin)) {
            try textmate_convert_emit.rule1(writer, "regex_vm_line_comment", begin, scope);
            return true;
        }
        return false;
    }
    var end_buf: [max_native_string]u8 = undefined;
    const end_lit_opt = textmate_pattern.regexLiteral(end, &end_buf) orelse
        textmate_pattern.literalOrLineEnd(end, &end_buf) orelse
        textmate_pattern.repeatedLiteral(end, &end_buf);
    if (end_lit_opt == null) return try writeRegexVmBlockRule(writer, begin, end, scope, has_captures);
    const end_lit = end_lit_opt.?;
    if (textmate_convert_emit.contains(scope, "comment")) {
        var begin_buf: [max_native_string]u8 = undefined;
        if (textmate_pattern.anchoredLiteral(begin, &begin_buf) orelse textmate_pattern.regexLiteral(begin, &begin_buf)) |begin_lit| {
            try textmate_convert_emit.rule2(writer, "block_comment", begin_lit, end_lit, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileNativeRegex(begin)) {
            try textmate_convert_emit.rule2(writer, "regex_block_comment", begin, end_lit, scope);
            return true;
        }
        if (begin.len <= max_native_string and textmate_pattern.canCompileRegexVm(begin)) {
            var end_regex_buf: [max_native_string]u8 = undefined;
            const end_regex = textmate_pattern.literalRegex(end_lit, &end_regex_buf) orelse return false;
            try textmate_convert_emit.rule2(writer, "regex_vm_block", begin, end_regex, scope);
            return true;
        }
        return false;
    }
    var begin_buf: [max_native_string]u8 = undefined;
    const begin_lit = textmate_pattern.anchoredLiteral(begin, &begin_buf) orelse textmate_pattern.regexLiteral(begin, &begin_buf) orelse {
        return try writeRegexVmBlockRule(writer, begin, end, scope, has_captures);
    };
    if (textmate_convert_emit.contains(scope, "string") and std.mem.eql(u8, begin_lit, end_lit)) {
        try textmate_convert_emit.delimited(writer, "string", begin_lit, scope);
        return true;
    }
    if (textmate_convert_emit.contains(scope, "string")) {
        try textmate_convert_emit.asymmetricDelimited(writer, begin_lit, end_lit, scope);
        return true;
    }
    if (textmate_convert_emit.contains(scope, "character") and std.mem.eql(u8, begin_lit, end_lit)) {
        try textmate_convert_emit.delimited(writer, "char", begin_lit, scope);
        return true;
    }
    if (textmate_convert_emit.contains(scope, "invalid") and std.mem.eql(u8, begin_lit, end_lit)) {
        try textmate_convert_emit.asymmetricDelimited(writer, begin_lit, end_lit, scope);
        return true;
    }
    if (std.mem.eql(u8, begin_lit, end_lit)) {
        try textmate_convert_emit.asymmetricDelimited(writer, begin_lit, end_lit, scope);
        return true;
    }
    if (!has_captures and try textmate_convert_blocks.writeLiteralRegexVmBlock(writer, begin_lit, end_lit, scope)) return true;
    return false;
}
fn writeRegexVmBlockRule(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8, has_captures: bool) !bool {
    var open_buf: [max_native_string]u8 = undefined;
    const open = textmate_pattern.consumingPositiveLookaheadPattern(begin, &open_buf) orelse begin;
    if (open.len == 0 or open.len > max_native_string or end.len > max_native_string or scope.len > max_native_string or has_captures or
        (lookaheadOnly(begin) and open.len == begin.len) or
        textmate_pattern.isLineEndPattern(end) or std.mem.eql(u8, begin, "\\n") or std.mem.eql(u8, begin, "\n") or
        !textmate_pattern.canCompileRegexVm(open) or !textmate_pattern.canCompileRegexVm(end)) return false;
    try textmate_convert_emit.rule2(writer, "regex_vm_block", open, end, scope);
    return true;
}

fn writeRegexLookaheadSpan(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8, has_captures: bool) !bool {
    const lookahead_string = textmate_convert_emit.contains(scope, "string") and std.mem.startsWith(u8, end, "(?=");
    const line_span = textmate_pattern.isLineEndPattern(end) and !has_captures and !textmate_convert_emit.contains(scope, "comment") and !textmate_convert_emit.contains(scope, "string");
    if (!lookahead_string and !line_span) return false;
    if (begin.len + (if (line_span) 1 else end.len) + 9 > max_native_string) return false;
    var pattern_buf: [max_native_string]u8 = undefined;
    const pattern = textmate_pattern.lazySpanPattern(begin, if (line_span) "$" else end, &pattern_buf) orelse return false;
    return try writeMatchRule(writer, pattern, scope);
}

fn writeDynamicBlockRule(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8) !bool {
    var open_buf: [max_native_string]u8 = undefined;
    const open = textmate_pattern.consumingPositiveLookaheadPattern(begin, &open_buf) orelse begin;
    if (textmate_dynamic.parse(end) == null) return false;
    if (open.len == 0 or open.len > max_native_string or end.len > max_native_string) return false;
    if (!textmate_pattern.canCompileRegexVm(open)) return false;
    try textmate_convert_emit.rule2(writer, "dynamic_block", open, end, scope);
    return true;
}

fn writeContextualLineBlockRule(writer: anytype, rules: []const textmate.RuleSummary, index: usize, scope: []const u8) !bool {
    const rule = rules[index];
    if (!textmate_convert_emit.contains(scope, "comment")) return false;
    const parent_index = rule.parent orelse return false;
    if (parent_index >= rules.len) return false;
    const begin = rule.pattern orelse return false;
    if (begin.len != 0 and !std.mem.eql(u8, begin, "\\n") and !std.mem.eql(u8, begin, "\n")) return false;
    const end = rule.end orelse return false;
    if (!lookaheadOnly(end)) return false;
    const parent = rules[parent_index];
    if (parent.kind != .begin_end) return false;
    const parent_begin = parent.pattern orelse return false;
    if (parent_begin.len > max_native_string or end.len > max_native_string or scope.len > max_native_string) return false;
    if (!textmate_pattern.canCompileRegexVm(parent_begin) or !textmate_pattern.canCompileRegexVm(end)) return false;
    try textmate_convert_emit.rule2(writer, "regex_vm_after_line_block", parent_begin, end, scope);
    return true;
}

fn writeWhileRule(writer: anytype, begin: []const u8, while_pattern: []const u8, scope: []const u8) !bool {
    if (scope.len > max_native_string) return false;
    var begin_buf: [max_native_string]u8 = undefined;
    var while_buf: [max_native_string]u8 = undefined;
    if (textmate_pattern.anchoredLiteral(begin, &begin_buf) orelse textmate_pattern.regexLiteral(begin, &begin_buf)) |begin_lit| {
        if (textmate_pattern.anchoredLiteral(while_pattern, &while_buf) orelse textmate_pattern.regexLiteral(while_pattern, &while_buf)) |while_lit| {
            if (begin_lit.len != 0 and std.mem.eql(u8, begin_lit, while_lit)) {
                var pattern_buf: [max_native_string]u8 = undefined;
                const pattern = textmate_pattern.anchoredLinePattern(begin_lit, &pattern_buf) orelse return false;
                return try writeMatchRule(writer, pattern, scope);
            }
        }
    }
    return try textmate_convert_blocks.writeRegexVmWhileBlock(writer, begin, while_pattern, scope);
}

fn writeBackrefLineDelimited(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8) !bool {
    if (!textmate_convert_emit.contains(scope, "string") and !textmate_convert_emit.contains(scope, "character")) return false;
    const slot = textmate_pattern.backrefLineEndSlot(end) orelse return false;
    var buf: [8]u8 = undefined;
    const delims = textmate_pattern.capturedByteClass(begin, slot, &buf) orelse return false;
    const kind = if (textmate_convert_emit.contains(scope, "character")) "char" else "string";
    for (delims) |byte| {
        const value = [_]u8{byte};
        try textmate_convert_emit.delimited(writer, kind, &value, scope);
    }
    return true;
}

fn writeBoundaryCaptureRules(
    writer: anytype,
    begin: []const u8,
    end: []const u8,
    captures: []const textmate_captures.CaptureEntry,
    end_captures: []const textmate_captures.CaptureEntry,
) !bool {
    const wrote_bounded_begin = try writeCapturedLookaheadRules(writer, begin, end, captures);
    const wrote_begin = try writeCapturedLiteralRules(writer, begin, captures);
    const wrote_end = try writeCapturedLiteralRules(writer, end, end_captures);
    return wrote_bounded_begin or wrote_begin or wrote_end;
}

fn writeCapturedLiteralRules(writer: anytype, pattern: []const u8, captures: []const textmate_captures.CaptureEntry) !bool {
    var wrote = false;
    for (captures) |capture| {
        if (capture.style_id == .plain) continue;
        if (capture.slot == 0 and try writeMatchRule(writer, pattern, capture.style_id.scope())) {
            wrote = true;
            continue;
        }
        var literal_buf: [max_native_string]u8 = undefined;
        if (textmate_pattern.captureIsWholeMatchWithLookahead(pattern, capture.slot)) {
            if (try writeMatchRule(writer, pattern, capture.style_id.scope())) wrote = true;
        } else if (textmate_pattern.optionalCaptureBeforeLookahead(pattern, capture.slot, &literal_buf)) |captured| {
            if (try writeMatchRule(writer, captured, capture.style_id.scope())) wrote = true;
        } else if (promotableBoundaryCapture(capture.style_id)) {
            if (textmate_pattern.captureLiteral(pattern, capture.slot, &literal_buf)) |literal| {
                var pattern_buf: [max_native_string]u8 = undefined;
                const escaped = textmate_pattern.literalRegex(literal, &pattern_buf) orelse continue;
                if (try writeMatchRule(writer, escaped, capture.style_id.scope())) wrote = true;
            } else {
                const captured = textmate_pattern.capturePattern(pattern, capture.slot) orelse continue;
                if (try writeMatchRule(writer, captured, capture.style_id.scope())) wrote = true;
            }
        } else if (!captureCoversWholePattern(pattern, capture.slot)) {
            if (try writeCaptureRule(writer, pattern, capture.slot, capture.style_id.scope())) {
                wrote = true;
            } else {
                const captured = textmate_pattern.capturePattern(pattern, capture.slot) orelse continue;
                if (try writeMatchRule(writer, captured, capture.style_id.scope())) wrote = true;
            }
        } else if (textmate_pattern.captureLiteral(pattern, capture.slot, &literal_buf)) |literal| {
            var pattern_buf: [max_native_string]u8 = undefined;
            const escaped = textmate_pattern.literalRegex(literal, &pattern_buf) orelse continue;
            if (try writeMatchRule(writer, escaped, capture.style_id.scope())) wrote = true;
        }
    }
    return wrote;
}

fn writeCapturedLookaheadRules(writer: anytype, begin: []const u8, end: []const u8, captures: []const textmate_captures.CaptureEntry) !bool {
    if (!lookaheadOnly(end)) return false;
    if (begin.len + end.len > max_native_string) return false;
    var wrote = false;
    var pattern_buf: [max_native_string]u8 = undefined;
    @memcpy(pattern_buf[0..begin.len], begin);
    @memcpy(pattern_buf[begin.len..][0..end.len], end);
    const pattern = pattern_buf[0 .. begin.len + end.len];
    for (captures) |capture| {
        if (capture.style_id == .plain or capture.slot == 0 or promotableBoundaryCapture(capture.style_id)) continue;
        if (!captureCoversWholePattern(begin, capture.slot)) continue;
        if (try writeCaptureRule(writer, pattern, capture.slot, capture.style_id.scope())) wrote = true;
    }
    return wrote;
}

fn lookaheadOnly(pattern: []const u8) bool {
    return std.mem.startsWith(u8, pattern, "(?=") or std.mem.startsWith(u8, pattern, "(?!");
}

fn promotableBoundaryCapture(style_id: style.StyleId) bool {
    return switch (style_id) {
        .keyword, .operator, .punctuation, .comment, .doc_comment, .container_doc_comment, .invalid => true,
        else => false,
    };
}

fn captureCoversWholePattern(pattern: []const u8, slot: u16) bool {
    if (slot != 1 or pattern.len < 2 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return false;
    const inner = textmate_pattern.capturePattern(pattern, slot) orelse return false;
    return inner.len + 2 == pattern.len and std.mem.eql(u8, pattern[1 .. pattern.len - 1], inner);
}

test "TextMate converter emits native zhl" {
    const json =
        \\{"scopeName":"source.test","name":"Test","patterns":[
        \\{"name":"keyword.control.test","match":"\\b(if|else)\\b"},
        \\{"name":"support.function.builtin.test","match":"@[A-Za-z_][A-Za-z0-9_]*"},
        \\{"name":"constant.character.test","match":"\\o{101}\\u0042"},
        \\{"name":"variable.other.test","match":"\\p{Alpha}\\p{XDigit}+"},
        \\{"name":"text.segment.test","match":"\\y\\X\\y"},
        \\{"name":"constant.other.test","match":"\\p{^Alpha}+"},
        \\{"name":"constant.language.test","match":"\\pL\\PN+"},
        \\{"name":"string.quoted.test","begin":"\\\"","end":"\\\""}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    try std.testing.expect(stats.converted >= 3);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate converter emits regex VM rules" {
    const json =
        \\{"scopeName":"source.test","name":"Test","patterns":[
        \\{"name":"storage.type.test","match":"(?<!\\w)(?:void|int)(?!\\w)"},
        \\{"name":"constant.test","match":"a{1,2}+a"},
        \\{"name":"comment.test","match":"a(?#ignored|comment)b"},
        \\{"name":"octal.test","match":"\\010[\\011]\\0"},
        \\{"name":"control.test","match":"\\cA[\\cB]"},
        \\{"name":"control-dash.test","match":"\\C-C[\\C-D]"},
        \\{"name":"meta.test","match":"\\M-a[\\M-\\C-b]"},
        \\{"name":"codepoint-vm.test","match":"a(?#ignored)\\o{142}\\u0063"},
        \\{"name":"flags.test","match":"(?WDS:a(?#ignored)b)"},
        \\{"name":"property-vm.test","match":"a(?#ignored)\\p{Alpha}"},
        \\{"name":"segment-vm.test","match":"a(?#ignored)\\X\\y"},
        \\{"name":"absent-vm.test","match":"(?~|345|\\d*)"},
        \\{"name":"absent-stopper-vm.test","match":"(?~|345)\\O*"},
        \\{"name":"absent-clear-vm.test","match":"(?~|345)\\O*(?~|)345"},
        \\{"name":"absolute-start.test","match":"a\\A"},
        \\{"name":"conditional.test","match":"(?(?=a)a|b)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 16), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"a\\\\A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm \"(?~|345|\\\\d*)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm \"(?~|345)\\\\O*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm \"(?~|345)\\\\O*(?~|)345\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter emits regex VM rules for Unicode scalar classes" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"entity.name.tag.test","match":"[A-Za-zÀ-Ö𐀀-\\x{EFFFF}]+"},
        \\{"name":"entity.other.attribute-name.test","match":"[^\\x7F-\\x{9F}﷐-﷯\\x{4FFFE}\\x{10FFFF}]+"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.tag.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.other.attribute-name.test") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter uses capture scope without rule name" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"match":"([A-Z]+)","captures":{"1":{"name":"entity.name.type.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.type.test") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter separates structural includes from skips" {
    const json =
        \\{"scopeName":"source.test","patterns":[{"include":"#keywords"}],
        \\"repository":{"keywords":{"patterns":[
        \\{"name":"keyword.control.test","match":"\\bif\\b"}]}}}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 2), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate skipped report uses converter decisions" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"variable.other.test","match":"("}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var converted_buf: [1024]u8 = undefined;
    var converted_writer = std.Io.Writer.fixed(&converted_buf);
    const stats = try writeTextMate(&converted_writer, summary, &.{});

    var report_buf: [1024]u8 = undefined;
    var report_writer = std.Io.Writer.fixed(&report_buf);
    try writeTextMateSkippedReport(&report_writer, summary, &.{});
    const report = report_buf[0..report_writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, report, "skipped-textmate source.test rule[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "pattern=\"(\"") != null);
}

test "TextMate converter separates no-style blocks from skips" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"begin":"\\(","end":"\\)","patterns":[
        \\{"name":"keyword.control.test","match":"\\bif\\b"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate converter treats plain metadata blocks as structural" {
    const json =
        \\{"scopeName":"text.test","patterns":[
        \\{"name":"meta.embedded.block.test","contentName":"source.embedded.test","begin":"<script>","end":"</script>","patterns":[
        \\{"name":"support.function.test","match":"\\bprint\\b"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate converter treats meta wrappers as structural" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"meta.function.test","begin":"fn","end":"\\}","patterns":[
        \\{"name":"entity.name.function.test","match":"\\bmain\\b"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate converter treats plain capture wrappers as structural" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"source.test","begin":"\\(","end":"\\)","captures":{"0":{"name":"source.test"}},"endCaptures":{"0":{"name":"source.test"}},"patterns":[
        \\{"name":"keyword.control.test","match":"\\bif\\b"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate converter treats unaddressable capture wrappers as structural" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"begin":"(?=a)","end":"(?!\\G)","beginCaptures":{"1":{"name":"punctuation.definition.test"}},"patterns":[
        \\{"name":"keyword.control.test","match":"\\bif\\b"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "TextMate plist converter uses capture scope without rule name" {
    const plist =
        \\<plist><dict>
        \\<key>scopeName</key><string>source.test</string>
        \\<key>patterns</key><array><dict>
        \\<key>match</key><string>([A-Z]+)</string>
        \\<key>captures</key><dict>
        \\<key>1</key><dict><key>name</key><string>entity.name.type.test</string></dict>
        \\</dict>
        \\</dict></array>
        \\</dict></plist>
    ;
    var summary = try textmate.summarizePlist(std.testing.allocator, plist);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.type.test") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers begin-end line comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.number-sign.test","begin":"#","end":"\\n"},
        \\{"name":"comment.line.semicolon.test","begin":";","end":"$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"#\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \";\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers guarded line comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.documentation.test","begin":"//[!/](?=[^/])","end":"$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_line_comment \"//[!/](?=[^/])\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers consuming lookahead blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.block.test","begin":"(?=(?>^\\[(comment)([#%,.][^]]+)*]$))","end":"((?<=--)|^\\p{blank}*)$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_block \"^\\\\[(comment)([#%,.][^]]+)*]$\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers beginless contextual blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"begin":"^#if 0","end":"^#endif","patterns":[
        \\{"name":"comment.block.test","begin":"","end":"(?=^#(?:else|endif))"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_after_line_block \"^#if 0\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers newline-lookbehind line comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.documentation.test","begin":"^(?>\\s*)(//[!/]+)","end":"(?<=\\n)(?<!\\\\\\n)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_line_comment") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers regex-open block comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.block.documentation.test","begin":"/\\*\\*(?!/)","end":"\\*/"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_block_comment \"/\\\\*\\\\*(?!/)\" \"*/\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers line-ended strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.multiline.test","begin":"\\\\\\\\","end":"$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "multiline_prefix \"\\\\\\\\\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers regex-open line-ended strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.unquoted.test","begin":"[^\"']","end":"(?<!\\\\)(?=\\s*\\n)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_line_comment \"[^\\\"']\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers regex-open lookahead-ended strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.unquoted.test","begin":"[^:#\\s]","end":"(?=\\s*$|\\s+#|\\s*:)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "string.unquoted.test") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers asymmetric delimited strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"variable.string.test","begin":"@\"","end":"\""}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "delimited \"@\\\"\" \"\\\"\" escape \"\\\\\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers literal scoped begin end blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"variable.other.test","begin":"\\{","end":"\\}"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_block \"\\\\{\" \"\\\\}\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers delimiter-or-line-end strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.quoted.test","begin":"\\\"","end":"\\\"|(?<!\\\\)(?=\\s*\\n)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "string \"\\\"\" escape \"\\\\\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers guarded regex begin end blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.quoted.multi.test","begin":"(?<!r)\\\"\\\"\\\"","end":"\\\"\\\"\\\"(?!\\\")"},
        \\{"name":"string.quoted.double.test","begin":"(?<!\\\")\\\"(?!\\\")","end":"\\\""}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];
    const spec = try dsl.parse(out);

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(dsl.RuleKind.regex_vm_block, spec.rules[0].kind);
    try std.testing.expectEqual(dsl.RuleKind.regex_vm_block, spec.rules[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_block \"(?<!r)\\\\\\\"\\\\\\\"\\\\\\\"\" \"\\\\\\\"\\\\\\\"\\\\\\\"(?!\\\\\\\")\"") != null);
}

test "TextMate converter lowers regex VM block comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.block.documentation.test","begin":"/\\*[!*](?![*/])","end":"\\*/"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_block \"/\\\\*[!*](?![*/])\" \"\\\\*/\"") != null);
}

test "TextMate converter lowers invalid delimiter-or-line-end spans" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"invalid.deprecated.test","begin":"`","end":"`|(?<!\\\\)(\\n)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "invalid.deprecated.test") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers whitespace-qualified line comments" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.number-sign.test","begin":"#\\s*(type:)","end":"$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"#\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers same-delimiter styled blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"support.class.test","begin":"'","end":"'"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "delimited \"'\" \"'\"") != null);
}

test "TextMate converter does not broaden guarded line comments" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expect(try writeBeginEndRule(&writer, "//[!/](?=[^/])", "$", "comment.line.documentation.test", false));
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_line_comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"//\"") == null);
}

test "TextMate converter lowers boundary capture literals" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"meta.block.test","begin":"\\{","beginCaptures":{"0":{"name":"punctuation.definition.block.begin.test"}},"end":"}","endCaptures":{"0":{"name":"punctuation.definition.block.end.test"}}},
        \\{"name":"meta.bracket.test","begin":"\\s*(\\[)","beginCaptures":{"1":{"name":"punctuation.definition.bracket.begin.test"}},"end":"(\\])","endCaptures":{"1":{"name":"punctuation.definition.bracket.end.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"\\\\{\" scope \"punctuation.separator.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"\\\\[\" scope \"punctuation.separator.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"\\\\]\" scope \"punctuation.separator.zig\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers whole-pattern boundary captures" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"source.test","begin":"\\bfor\\b","end":"\\bin\\b","captures":{"0":{"name":"keyword.control.test"}},"endCaptures":{"0":{"name":"keyword.control.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "keyword.control.zig") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers captured lookahead boundary as scoped regex" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"meta.assignment.test","begin":"([A-Za-z_][A-Za-z0-9_]*)(?=\\s*=>)","end":"$","beginCaptures":{"1":{"name":"entity.name.function.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "([A-Za-z_][A-Za-z0-9_]*)(?=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "=>)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.function.zig") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers optional capture before lookahead" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.template.test","begin":"([A-Za-z_][A-Za-z0-9_]*)?\\s*(?=`)","end":"`","beginCaptures":{"1":{"name":"entity.name.function.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "(?:[A-Za-z_][A-Za-z0-9_]*)(?=\\\\s*`)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.function.zig") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter promotes safe boundary capture groups" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"source.test","begin":"\\b(if|while)\\b","end":"$","captures":{"1":{"name":"keyword.control.test"}}},
        \\{"name":"source.test","begin":"([_[:alpha:]]\\w*)","end":"$","captures":{"1":{"name":"entity.name.function.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "keyword.control.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.function.zig") == null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers constrained boundary captures" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"source.test","begin":"(const) (name)","end":"$","captures":{"2":{"name":"variable.other.test"}}},
        \\{"name":"source.test","begin":"([A-Za-z_][A-Za-z0-9_]*)","end":"$","captures":{"1":{"name":"variable.other.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_capture") != null or std.mem.indexOf(u8, out, "regex_capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "capture 2 scope \"variable.other.field.zig\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers whole capture with lookahead boundary" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"source.test","begin":"([A-Za-z_][A-Za-z0-9_]*)","end":"(?=,|$)","captures":{"1":{"name":"variable.other.test"}}}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "([A-Za-z_][A-Za-z0-9_]*)(?=,|$)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "capture 1 scope \"variable.other.field.zig\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers contextual newline comment blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"meta.preprocessor.test","begin":"^#if 0\\b","end":"^#endif\\b","patterns":[
        \\{"contentName":"comment.block.preprocessor.test","begin":"\\n","end":"(?=^#endif\\b)"}]}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_after_line_block \"^#if 0\\\\b\" \"(?=^#endif\\\\b)\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers backref line strings" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.quoted.test","begin":"([\\\"'])","end":"(\\1)|(\\n)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];
    const spec = try dsl.parse(out);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.string, rules[0].kind);
    try std.testing.expectEqualStrings("\"", spec.slice(rules[0].value));
    try std.testing.expectEqual(dsl.RuleKind.string, rules[1].kind);
    try std.testing.expectEqualStrings("'", spec.slice(rules[1].value));
}

test "TextMate converter lowers dynamic blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.unquoted.heredoc.test","begin":"<<([A-Z]+)","end":"^\\1$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];
    const spec = try dsl.parse(out);

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "dynamic_block \"<<([A-Z]+)\" \"^\\\\1$\"") != null);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
}

test "TextMate converter lowers grouped backref dynamic blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.quoted.multi.test","begin":"('''|\"\"\")","end":"(\\1)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "dynamic_block \"('''|\\\"\\\"\\\")\" \"(\\\\1)\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers prefixed dynamic end alternatives" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.tag.test","begin":"<([A-Za-z]+)>","end":"</\\1\\s*>|/>"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "dynamic_block \"<([A-Za-z]+)>\" \"</\\\\1\\\\s*>|/>\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers prefixed dynamic end suffixes" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.raw.test","begin":"[Rr]\"(-*)\\{","end":"}\\1\""}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("[Rr]\"(-*)\\{", spec.slice(spec.rules[0].value));
    try std.testing.expectEqualStrings("}\\1\"", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers prefixed dynamic end horizontal space tails" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.raw.test","begin":"\\[(=*)\\[","end":"]\\1][\\t ]*"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("]\\1][\\t ]*", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers dynamic end literal suffixes" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.raw.test","begin":"([q#]+)","end":"\\1\""}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("\\1\"", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers dynamic line contains ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.heredoc.test","begin":"<<([A-Z]+)(END)","end":"^.*?\\2.*?$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("^.*?\\2.*?$", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers whitespace backref suffix ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.embedded.test","begin":"<([%?])","end":"(?<=\\s)(\\1>)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("(?<=\\s)(\\1>)", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers whitespace backref boundary ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"\\b(begin)\\s+(name)\\b","end":"\\s*\\2\\b"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("\\s*\\2\\b", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers whitespace anchored backref ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"\\b(begin)\\s+(name)\\b","end":"^\\s*\\2\\s*$"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("^\\s*\\2\\s*$", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers grouped whitespace backref ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"\\b(begin)\\s+(name)\\b","end":"^(\\s*(\\2))(?!\\\")"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("^(\\s*(\\2))(?!\\\")", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers anchored backref line-tail ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"(a)(b)(key)","end":"^(\\3)\\b(.*)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("^(\\3)\\b(.*)", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers concatenated backref ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"([\\[\\(])([^\\]\\)]+)","end":"\\2\\1"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("\\2\\1", spec.slice(spec.rules[0].escape));
}

test "TextMate converter lowers anchored optional semicolon backref ends" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"string.block.test","begin":"(begin) (end)","end":"^(\\2)(?=;?$)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    const spec = try dsl.parse(out);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, spec.rules[0].kind);
    try std.testing.expectEqualStrings("^(\\2)(?=;?$)", spec.slice(spec.rules[0].escape));
}

test "TextMate plist converter lowers backref line strings" {
    const plist =
        \\<plist><dict>
        \\<key>scopeName</key><string>source.test</string>
        \\<key>patterns</key><array><dict>
        \\<key>name</key><string>string.quoted.test</string>
        \\<key>begin</key><string>([\"'])</string>
        \\<key>end</key><string>(\1)|(\n)</string>
        \\</dict></array>
        \\</dict></plist>
    ;
    var summary = try textmate.summarizePlist(std.testing.allocator, plist);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const spec = try dsl.parse(buf[0..writer.end]);

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 2), spec.ruleSlice().len);
}

test "TextMate converter lowers captured line comment matches" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.doc.test","match":"(///).*$"},
        \\{"name":"comment.line.double-slash.test","match":"(//).*$\\n?"},
        \\{"name":"comment.line.number-sign.test","match":"(?:#).*(?=$)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 3), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"///\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"//\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"#\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex") == null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers simple while line rules" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.line.quote.test","begin":"^>","while":"^>"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"^>.*$\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers regex while line blocks" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.block.test","begin":"^\\s{3,}(?=\\S)","while":"^(?:\\s{3}.*|\\s*$)"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_after_line_block \"^\\\\s{3,}(?=\\\\S)\" \"(?!^(?:\\\\s{3}.*|\\\\s*$))\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_line_comment \"^\\\\s{3,}(?=\\\\S)\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter lowers same-literal while rules" {
    const json =
        \\{"scopeName":"source.test","patterns":[
        \\{"name":"comment.block.documentation.test","begin":"///","while":"///"}]}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex \"^///.*$\"") != null);
}

test "TextMate plist converter lowers begin-end line comments" {
    const plist =
        \\<plist><dict>
        \\<key>scopeName</key><string>source.test</string>
        \\<key>patterns</key><array><dict>
        \\<key>name</key><string>comment.line.number-sign.test</string>
        \\<key>begin</key><string>#</string>
        \\<key>end</key><string>$()</string>
        \\</dict></array>
        \\</dict></plist>
    ;
    var summary = try textmate.summarizePlist(std.testing.allocator, plist);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "line_comment \"#\"") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter keeps supported long regex rules" {
    var pattern = [_]u8{'a'} ** 180;
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const wrote = try writeMatchRule(&writer, &pattern, "constant.test");
    const out = buf[0..writer.end];

    try std.testing.expect(wrote);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter splits oversized top-level alternations" {
    var pattern_buf: [20_000]u8 = undefined;
    var pattern = std.Io.Writer.fixed(&pattern_buf);
    try pattern.writeAll("(?i)(?<![-\\w])(?:");
    for (0..900) |i| {
        if (i != 0) try pattern.writeByte('|');
        try pattern.print("property-name-{d}", .{i});
    }
    try pattern.writeAll(")(?![-\\w])");

    var out_buf: [16_384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const wrote = try writeMatchRule(&writer, pattern_buf[0..pattern.end], "support.type.property-name.test");
    const out = out_buf[0..writer.end];

    try std.testing.expect(wrote);
    try std.testing.expect(std.mem.indexOf(u8, out, "property-name-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "property-name-899") != null);
    try std.testing.expect((std.mem.indexOf(u8, out, "regex_vm") orelse 0) != (std.mem.lastIndexOf(u8, out, "regex_vm") orelse 0));
    _ = try dsl.parse(out);
}

test "TextMate converter splits oversized capturing alternations" {
    var pattern_buf: [20_000]u8 = undefined;
    var pattern = std.Io.Writer.fixed(&pattern_buf);
    try pattern.writeAll("\\b(?i)(");
    for (0..900) |i| {
        if (i != 0) try pattern.writeByte('|');
        try pattern.print("keyword_{d}", .{i});
    }
    try pattern.writeAll(")\\b");

    var out_buf: [16_384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const wrote = try writeMatchRule(&writer, pattern_buf[0..pattern.end], "keyword.other.test");
    const out = out_buf[0..writer.end];

    try std.testing.expect(wrote);
    try std.testing.expect(std.mem.indexOf(u8, out, "keyword_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keyword_899") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter splits oversized noncapturing alternation inside capture" {
    var pattern_buf: [20_000]u8 = undefined;
    var pattern = std.Io.Writer.fixed(&pattern_buf);
    try pattern.writeAll("\\s*((?:-(?:webkit|moz)-)?(?:");
    for (0..900) |i| {
        if (i != 0) try pattern.writeByte('|');
        try pattern.print("property-name-{d}", .{i});
    }
    try pattern.writeAll(")):\\s+");

    var out_buf: [16_384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const wrote = try writeMatchRule(&writer, pattern_buf[0..pattern.end], "support.type.property-name.test");
    const out = out_buf[0..writer.end];

    try std.testing.expect(wrote);
    try std.testing.expect(std.mem.indexOf(u8, out, "property-name-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "property-name-899") != null);
    _ = try dsl.parse(out);
}

test "TextMate converter splits oversized alternation blocks" {
    var json_buf: [32_000]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_buf);
    try json.writeAll("{\"scopeName\":\"source.test\",\"patterns\":[{\"name\":\"support.type.property-name.test\",\"begin\":\"\\\\s*((?:-(?:webkit|moz)-)?(?:");
    for (0..1200) |i| {
        if (i != 0) try json.writeByte('|');
        try json.print("property-name-{d}", .{i});
    }
    try json.writeAll(")):\\\\s+\",\"end\":\"(?<=;$)\"}]}");

    var summary = try textmate.summarizeJson(std.testing.allocator, json_buf[0..json.end]);
    defer summary.deinit();
    var out_buf: [96_000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const out = out_buf[0..writer.end];

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm_block") != null);
    try std.testing.expect((std.mem.indexOf(u8, out, "regex_vm_block") orelse 0) != (std.mem.lastIndexOf(u8, out, "regex_vm_block") orelse 0));
    _ = try dsl.parse(out);
}

test "TextMate converter splits oversized alternations after prefix groups" {
    var pattern_buf: [20_000]u8 = undefined;
    var pattern = std.Io.Writer.fixed(&pattern_buf);
    try pattern.writeAll("(&)(?=[A-Za-z])(");
    for (0..900) |i| {
        if (i != 0) try pattern.writeByte('|');
        try pattern.print("entity_name_{d}", .{i});
    }
    try pattern.writeAll(")(;)");

    var out_buf: [16_384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    const wrote = try writeMatchRule(&writer, pattern_buf[0..pattern.end], "constant.character.entity.named.test");
    const out = out_buf[0..writer.end];

    try std.testing.expect(wrote);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity_name_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity_name_899") != null);
    try std.testing.expect((std.mem.indexOf(u8, out, "regex_vm") orelse 0) != (std.mem.lastIndexOf(u8, out, "regex_vm") orelse 0));
    _ = try dsl.parse(out);
}

test "TextMate converter lowers zero-width boundary content spans" {
    const json =
        \\{
        \\  "scopeName": "source.test",
        \\  "patterns": [
        \\    {
        \\      "contentName": "entity.name.type.test",
        \\      "begin": "(?=[A-Z_a-z][0-9A-Z_a-z]*)",
        \\      "end": "(?![0-9A-Z_a-z])"
        \\    }
        \\  ]
        \\}
    ;
    var summary = try textmate.summarizeJson(std.testing.allocator, json);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeTextMate(&writer, summary, &.{});
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.regex, rules[0].kind);
    try std.testing.expectEqualStrings("[A-Z_a-z][0-9A-Z_a-z]*", spec.slice(rules[0].value));
    try std.testing.expectEqualStrings("entity.name.type.test", spec.slice(rules[0].scope));
}

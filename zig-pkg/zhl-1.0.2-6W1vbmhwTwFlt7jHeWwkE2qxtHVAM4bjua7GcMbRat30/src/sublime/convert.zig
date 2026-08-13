const std = @import("std");
const convert_common = @import("../convert_common.zig");
const dsl = @import("../native/dsl.zig");
const dsl_emit = @import("../native/dsl_emit.zig");
const sublime = @import("import.zig");
const sublime_marker = @import("marker.zig");
const textmate_convert_emit = @import("../textmate/convert_emit.zig");
const textmate_dynamic = @import("../textmate/dynamic/root.zig");
const textmate_pattern = @import("../textmate/pattern.zig");

const max_native_string = dsl.max_string_bytes;
const writeDslString = dsl_emit.writeString;

pub const DynamicPair = struct {
    pop_index: usize,
    scope: []const u8,
};

pub const DelimitedKind = enum { string, char, block_comment };

pub const DelimitedPair = struct {
    pop_index: usize,
    kind: DelimitedKind,
    scope: []const u8,
};

pub fn writeSublime(writer: anytype, summary: sublime.Summary) !convert_common.Stats {
    var stats = convert_common.Stats{};
    try convert_common.writeHeader(writer, summary.scope, summary.name);
    for (summary.rules, 0..) |_, index| switch (try convertRule(writer, summary.rules, index)) {
        .converted => stats.converted += 1,
        .skipped => stats.skipped += 1,
        .structural => stats.structural += 1,
    };
    try writer.writeAll("    }\n}\n");
    return stats;
}

pub fn writeSublimeSkippedReport(writer: anytype, summary: sublime.Summary) !void {
    var discard = convert_common.DiscardWriter{};
    for (summary.rules, 0..) |rule, index| {
        if (try convertRule(&discard, summary.rules, index) == .skipped) {
            try writer.print("skipped-sublime {s} rule[{d}] context=\"{s}\" match=\"{s}\" scope=\"{s}\"\n", .{ summary.scope, index, rule.context, rule.match, ruleScope(rule) });
        }
    }
}

fn convertRule(writer: anytype, rules: []const sublime.Rule, index: usize) !convert_common.RuleDisposition {
    const rule = rules[index];
    if (popConsumed(rules, index)) return .converted;
    var prefix_buf: [max_native_string]u8 = undefined;
    if (sublime_marker.popConsumed(rules, index, &prefix_buf)) return .converted;
    if (try writeMarkerDelimited(writer, rules, index)) return .converted;
    if (try writeDelimited(writer, rules, index)) return .converted;
    if (try writeDynamicBlock(writer, rules, index)) return .converted;
    if (rule.action == .include or rule.action == .pop) return .structural;
    const scope = ruleScope(rule);
    if (rule.match.len == 0 or scope.len == 0) return .structural;
    return if (try convert_common.writeMatchRule(writer, rule.match, scope)) .converted else .skipped;
}

fn writeDelimited(writer: anytype, rules: []const sublime.Rule, index: usize) !bool {
    const rule = rules[index];
    const pair = delimitedPair(rules, index) orelse return false;
    var open_buf: [max_native_string]u8 = undefined;
    const open = textmate_pattern.regexLiteral(rule.match, &open_buf) orelse return false;
    var close_buf: [max_native_string]u8 = undefined;
    const close = textmate_pattern.regexLiteral(rules[pair.pop_index].match, &close_buf) orelse return false;
    switch (pair.kind) {
        .string, .char => try textmate_convert_emit.delimited(writer, delimitedKindName(pair.kind), open, pair.scope),
        .block_comment => try textmate_convert_emit.rule2(writer, "block_comment", open, close, pair.scope),
    }
    return true;
}

fn writeMarkerDelimited(writer: anytype, rules: []const sublime.Rule, index: usize) !bool {
    var prefix_buf: [max_native_string]u8 = undefined;
    const found = sublime_marker.pair(rules, index, &prefix_buf) orelse return false;
    var config = [_]u8{ found.delimiter, found.marker };
    try writer.writeAll("        marker_string ");
    try writeDslString(writer, found.prefix);
    try writer.writeAll(" escape ");
    try writeDslString(writer, &config);
    try writer.writeAll(" scope ");
    try writeDslString(writer, found.scope);
    try writer.writeAll(";\n");
    return true;
}

fn popConsumed(rules: []const sublime.Rule, index: usize) bool {
    const rule = rules[index];
    if (rule.action != .pop) return false;
    for (rules, 0..) |open_rule, open_index| {
        if (open_rule.action != .push and open_rule.action != .set) continue;
        if (delimitedPair(rules, open_index)) |pair| if (pair.pop_index == index) return true;
        if (dynamicPair(rules, open_index)) |dynamic| if (dynamic.pop_index == index) return true;
    }
    return false;
}

fn ruleScope(rule: sublime.Rule) []const u8 {
    const direct = directRuleScope(rule);
    return if (direct.len != 0) direct else rule.context_scope;
}

pub fn writeDynamicBlock(writer: anytype, rules: []const sublime.Rule, index: usize) !bool {
    const rule = rules[index];
    const found = dynamicPair(rules, index) orelse return false;
    const open = textmate_pattern.consumingPositiveLookahead(rule.match) orelse rule.match;
    try writer.writeAll("        dynamic_block ");
    try writeDslString(writer, open);
    try writer.writeByte(' ');
    try writeDslString(writer, rules[found.pop_index].match);
    try writer.writeAll(" scope ");
    try writeDslString(writer, found.scope);
    try writer.writeAll(";\n");
    return true;
}

pub fn dynamicPair(rules: []const sublime.Rule, index: usize) ?DynamicPair {
    const open_rule = rules[index];
    if (open_rule.action != .push and open_rule.action != .set) return null;
    if (open_rule.target.len == 0 or open_rule.match.len == 0) return null;
    const open = textmate_pattern.consumingPositiveLookahead(open_rule.match) orelse open_rule.match;
    if (open.len == 0 or open.len > max_native_string or !textmate_pattern.canCompileRegexVm(open)) return null;
    for (rules, 0..) |pop_rule, pop_index| {
        if (pop_rule.action != .pop or !std.mem.eql(u8, pop_rule.context, open_rule.target)) continue;
        if (pop_rule.match.len == 0 or pop_rule.match.len > max_native_string or textmate_dynamic.parse(pop_rule.match) == null) continue;
        const scope = if (pop_rule.context_scope.len != 0) pop_rule.context_scope else contextMetaScope(rules, open_rule.target);
        if (scope.len == 0 or scope.len > max_native_string) continue;
        return .{ .pop_index = pop_index, .scope = scope };
    }
    return null;
}

pub fn delimitedPair(rules: []const sublime.Rule, index: usize) ?DelimitedPair {
    const open_rule = rules[index];
    if (open_rule.action != .push and open_rule.action != .set) return null;
    if (open_rule.target.len == 0 or open_rule.match.len == 0) return null;
    var open_buf: [max_native_string]u8 = undefined;
    const open = textmate_pattern.regexLiteral(open_rule.match, &open_buf) orelse return null;
    if (open.len == 0) return null;
    for (rules, 0..) |pop_rule, pop_index| {
        if (pop_rule.action != .pop or !std.mem.eql(u8, pop_rule.context, open_rule.target)) continue;
        const scope = preferredDelimitedScope(open_rule, pop_rule) orelse continue;
        const kind = delimitedKind(scope) orelse continue;
        var close_buf: [max_native_string]u8 = undefined;
        const close = textmate_pattern.regexLiteral(pop_rule.match, &close_buf) orelse continue;
        if ((kind == .string or kind == .char) and !std.mem.eql(u8, open, close)) continue;
        return .{ .pop_index = pop_index, .kind = kind, .scope = scope };
    }
    return null;
}

pub fn delimitedKindName(kind: DelimitedKind) []const u8 {
    return switch (kind) {
        .string => "string",
        .char => "char",
        .block_comment => "block_comment",
    };
}

fn contextMetaScope(rules: []const sublime.Rule, context: []const u8) []const u8 {
    for (rules) |rule| {
        if (rule.match.len == 0 and std.mem.eql(u8, rule.context, context) and rule.context_scope.len != 0) return rule.context_scope;
    }
    return "";
}

fn preferredDelimitedScope(open_rule: sublime.Rule, pop_rule: sublime.Rule) ?[]const u8 {
    if (delimitedKind(pop_rule.context_scope) != null) return pop_rule.context_scope;
    const open_scope = directRuleScope(open_rule);
    if (delimitedKind(open_scope) != null) return open_scope;
    const pop_scope = directRuleScope(pop_rule);
    if (delimitedKind(pop_scope) != null) return pop_scope;
    return null;
}

fn directRuleScope(rule: sublime.Rule) []const u8 {
    return if (rule.scope.len != 0) rule.scope else rule.capture_scope;
}

fn delimitedKind(scope: []const u8) ?DelimitedKind {
    if (contains(scope, "character")) return .char;
    if (contains(scope, "string")) return .string;
    if (contains(scope, "comment")) return .block_comment;
    return null;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "Sublime converter emits native zhl" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: \b(if|else)\b
        \\      scope: keyword.control.test
        \\    - match: (?<!\w)(?:void|int)(?!\w)
        \\      scope: storage.type.test
        \\    - match: ([A-Z]+)
        \\      captures:
        \\        1: entity.name.type.test
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const out = buf[0..writer.end];
    try std.testing.expectEqual(@as(usize, 3), stats.converted);
    try std.testing.expect(std.mem.indexOf(u8, out, "regex_vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "entity.name.type.test") != null);
    _ = try dsl.parse(out);
}

test "Sublime converter separates structural includes from skips" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - include: keywords
        \\  keywords:
        \\    - match: \bif\b
        \\      scope: keyword.control.test
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "Sublime converter separates no-scope control rules from skips" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: \bif\b
        \\      scope: keyword.control.test
        \\    - match: (?=\S)
        \\      pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "Sublime converter treats unpaired scoped pop rules as structural" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: \1
        \\      scope: string.test
        \\      pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);

    try std.testing.expectEqual(@as(usize, 0), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "Sublime converter separates no-style consume rules from skips" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: (?=;)
        \\    - match: \bif\b
        \\      scope: keyword.control.test
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);

    try std.testing.expectEqual(@as(usize, 1), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), stats.structural);
    _ = try dsl.parse(buf[0..writer.end]);
}

test "Sublime converter lowers push-pop strings" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  string:
        \\    - match: '"'
        \\      scope: string.quoted.test
        \\      pop: true
        \\  main:
        \\    - match: '"'
        \\      scope: string.quoted.test
        \\      push: string
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.string, rules[0].kind);
    try std.testing.expectEqualStrings("\"", spec.slice(rules[0].value));
}

test "Sublime converter lowers marker-delimited strings" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: (r)(#*)"
        \\      push: raw
        \\  raw:
        \\    - meta_scope: string.quoted.double.raw.test
        \\    - match: '"\2'
        \\      scope: punctuation.definition.string.end.test
        \\      pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.marker_string, rules[0].kind);
    try std.testing.expectEqualStrings("r", spec.slice(rules[0].value));
    try std.testing.expectEqualStrings("\"#", spec.slice(rules[0].escape));
    try std.testing.expectEqualStrings("string.quoted.double.raw.test", spec.slice(rules[0].scope));
}

test "Sublime converter lowers dynamic push-pop pairs" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: (`+)
        \\      set: code-span-body
        \\  code-span-body:
        \\    - meta_scope: markup.raw.inline.test
        \\    - match: \1(?!`)
        \\      scope: punctuation.definition.raw.end.test
        \\      pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.dynamic_block, rules[0].kind);
    try std.testing.expectEqualStrings("(`+)", spec.slice(rules[0].value));
    try std.testing.expectEqualStrings("\\1(?!`)", spec.slice(rules[0].escape));
    try std.testing.expectEqualStrings("markup.raw.inline.test", spec.slice(rules[0].scope));
}

test "Sublime converter lowers meta-scope block comments" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  comments:
        \\    - match: /\*
        \\      scope: punctuation.definition.comment.begin.test
        \\      push: block-comment-body
        \\  block-comment-body:
        \\    - meta_scope: comment.block.test
        \\    - match: \*/
        \\      scope: punctuation.definition.comment.end.test
        \\      pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.block_comment, rules[0].kind);
    try std.testing.expectEqualStrings("/*", spec.slice(rules[0].value));
    try std.testing.expectEqualStrings("*/", spec.slice(rules[0].escape));
    try std.testing.expectEqualStrings("comment.block.test", spec.slice(rules[0].scope));
}

test "Sublime converter lowers inline meta-scope block comments" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: /\*
        \\      scope: punctuation.definition.comment.begin.test
        \\      push:
        \\        - meta_scope: comment.block.test
        \\        - match: \*/
        \\          scope: punctuation.definition.comment.end.test
        \\          pop: true
    ;
    var summary = try sublime.summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const stats = try writeSublime(&writer, summary);
    const spec = try dsl.parse(buf[0..writer.end]);
    const rules = spec.ruleSlice();

    try std.testing.expectEqual(@as(usize, 2), stats.converted);
    try std.testing.expectEqual(@as(usize, 0), stats.skipped);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(dsl.RuleKind.block_comment, rules[0].kind);
    try std.testing.expectEqualStrings("/*", spec.slice(rules[0].value));
    try std.testing.expectEqualStrings("*/", spec.slice(rules[0].escape));
}

test "Sublime dynamic pair finds captured pop contexts" {
    const rules = [_]sublime.Rule{
        .{ .context = @constCast("main"), .match = @constCast("(`+)"), .target = @constCast("body"), .action = .set },
        .{ .context = @constCast("body"), .context_scope = @constCast("markup.raw.inline.test"), .match = @constCast("\\1(?!`)"), .action = .pop },
    };
    const found = dynamicPair(&rules, 0).?;
    try std.testing.expectEqual(@as(usize, 1), found.pop_index);
    try std.testing.expectEqualStrings("markup.raw.inline.test", found.scope);
}

test "Sublime dynamic pair accepts exact repeated backref pops" {
    const rules = [_]sublime.Rule{
        .{ .context = @constCast("main"), .match = @constCast("(-){3}"), .target = @constCast("body"), .action = .push },
        .{ .context = @constCast("body"), .context_scope = @constCast("meta.range.test"), .match = @constCast("\\1{4}"), .action = .pop },
    };
    const found = dynamicPair(&rules, 0).?;
    try std.testing.expectEqual(@as(usize, 1), found.pop_index);
    try std.testing.expectEqualStrings("meta.range.test", found.scope);
}

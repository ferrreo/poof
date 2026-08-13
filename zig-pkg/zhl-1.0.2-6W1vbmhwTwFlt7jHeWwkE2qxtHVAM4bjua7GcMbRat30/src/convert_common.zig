const std = @import("std");
const dsl = @import("native/dsl.zig");
const dsl_emit = @import("native/dsl_emit.zig");
const textmate_convert_emit = @import("textmate/convert_emit.zig");
const textmate_convert_regex = @import("textmate/convert_regex.zig");
const textmate_keyword = @import("textmate/keyword.zig");
const textmate_pattern = @import("textmate/pattern.zig");

pub const max_native_string = dsl.max_string_bytes;
pub const writeDslString = dsl_emit.writeString;

pub const Stats = struct { converted: usize = 0, skipped: usize = 0, structural: usize = 0 };
pub const RuleDisposition = enum { converted, skipped, structural };

pub const DiscardWriter = struct {
    pub fn writeAll(_: *@This(), _: []const u8) !void {}
    pub fn writeByte(_: *@This(), _: u8) !void {}
    pub fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
};

pub fn writeHeader(writer: anytype, scope: []const u8, name: []const u8) !void {
    try writer.writeAll("grammar ");
    try writeDslString(writer, scope);
    try writer.writeAll(" {\n    name ");
    try writeDslString(writer, if (name.len == 0) scope else name);
    try writer.writeAll(";\n    scope root = ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n\n    context main {\n");
}

pub fn writeMatchRule(writer: anytype, pattern: []const u8, scope: []const u8) !bool {
    if (scope.len > max_native_string) return false;
    if (try writeLineComment(writer, pattern, scope)) return true;
    if (try writeBuiltinPrefix(writer, pattern, scope)) return true;
    if (textmate_keyword.canCompile(pattern)) {
        try writeKeywords(writer, pattern, scope);
        return true;
    }
    if (textmate_convert_emit.contains(scope, "numeric") or textmate_convert_emit.contains(scope, "number")) {
        try textmate_convert_emit.nameRule(writer, "number", "generic", scope);
        return true;
    }
    if (pattern.len <= max_native_string and textmate_pattern.canCompileNativeRegex(pattern)) {
        try textmate_convert_emit.rule1(writer, "regex", pattern, scope);
        return true;
    }
    if (pattern.len <= max_native_string and textmate_pattern.canCompileRegexVm(pattern)) {
        try textmate_convert_emit.rule1(writer, "regex_vm", pattern, scope);
        return true;
    }
    if (try textmate_convert_regex.writeSplitAlternationRules(writer, pattern, scope)) return true;
    return false;
}

pub fn writeCaptureRule(writer: anytype, pattern: []const u8, slot: u16, scope: []const u8) !bool {
    if (scope.len > max_native_string or pattern.len > max_native_string) return false;
    const kind = if (textmate_pattern.canCompileNativeRegex(pattern))
        "regex_capture"
    else if (textmate_pattern.canCompileRegexVm(pattern))
        "regex_vm_capture"
    else
        return false;
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, pattern);
    try writer.print(" capture {d} scope ", .{slot});
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
    return true;
}

fn writeLineComment(writer: anytype, pattern: []const u8, scope: []const u8) !bool {
    if (!textmate_convert_emit.contains(scope, "comment")) return false;
    var buf: [max_native_string]u8 = undefined;
    const marker = lineCommentMarker(pattern, &buf) orelse return false;
    if (marker.len == 0) return false;
    try textmate_convert_emit.rule1(writer, "line_comment", marker, scope);
    return true;
}

fn lineCommentMarker(pattern: []const u8, buf: []u8) ?[]const u8 {
    const head = lineCommentHead(pattern) orelse return null;
    if (std.mem.startsWith(u8, head, "^") or std.mem.startsWith(u8, head, "\\A")) return null;
    if (singleGroup(head)) |inner| return textmate_pattern.regexLiteral(inner, buf);
    return textmate_pattern.regexLiteral(head, buf);
}

fn lineCommentHead(pattern: []const u8) ?[]const u8 {
    const tails = [_][]const u8{ ".*$\\n?", ".*(?=$)", ".*$" };
    for (tails) |tail| {
        if (std.mem.endsWith(u8, pattern, tail)) return pattern[0 .. pattern.len - tail.len];
    }
    return null;
}

fn singleGroup(pattern: []const u8) ?[]const u8 {
    if (pattern.len < 3 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return null;
    const start: usize = if (std.mem.startsWith(u8, pattern, "(?:")) 3 else 1;
    if (std.mem.indexOfAny(u8, pattern[start .. pattern.len - 1], "()|") != null) return null;
    return pattern[start .. pattern.len - 1];
}

fn writeBuiltinPrefix(writer: anytype, pattern: []const u8, scope: []const u8) !bool {
    if (!textmate_convert_emit.contains(scope, "builtin") and !textmate_convert_emit.contains(scope, "support.function")) return false;
    var buf: [max_native_string]u8 = undefined;
    const prefix = textmate_pattern.literalPrefix(pattern, &buf) orelse return false;
    if (prefix.len == 0 or prefix.len == pattern.len) return false;
    try textmate_convert_emit.rule1(writer, "builtin_prefix", prefix, scope);
    return true;
}

fn writeKeywords(writer: anytype, pattern: []const u8, scope: []const u8) !void {
    const inner = pattern[3 .. pattern.len - 3];
    var chunk: [max_native_string]u8 = undefined;
    var chunk_len: usize = 0;
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |word| {
        if (word.len > chunk.len) continue;
        const needed = word.len + @intFromBool(chunk_len != 0);
        if (chunk_len + needed > chunk.len) {
            try textmate_convert_emit.keywordChunk(writer, chunk[0..chunk_len], scope);
            chunk_len = 0;
        }
        if (chunk_len != 0) {
            chunk[chunk_len] = ' ';
            chunk_len += 1;
        }
        @memcpy(chunk[chunk_len..][0..word.len], word);
        chunk_len += word.len;
    }
    if (chunk_len != 0) try textmate_convert_emit.keywordChunk(writer, chunk[0..chunk_len], scope);
}

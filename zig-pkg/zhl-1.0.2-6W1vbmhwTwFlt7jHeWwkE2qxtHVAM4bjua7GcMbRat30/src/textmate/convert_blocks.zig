const std = @import("std");
const dsl = @import("../native/dsl.zig");
const dsl_emit = @import("../native/dsl_emit.zig");
const textmate_pattern = @import("pattern.zig");

const max_native_string = dsl.max_string_bytes;
const writeDslString = dsl_emit.writeString;

pub fn writeLiteralRegexVmBlock(writer: anytype, begin_lit: []const u8, end_lit: []const u8, scope: []const u8) !bool {
    if (begin_lit.len == 0 or end_lit.len == 0) return false;
    var begin_regex_buf: [max_native_string]u8 = undefined;
    var end_regex_buf: [max_native_string]u8 = undefined;
    const begin_regex = textmate_pattern.literalRegex(begin_lit, &begin_regex_buf) orelse return false;
    const end_regex = textmate_pattern.literalRegex(end_lit, &end_regex_buf) orelse return false;
    if (!textmate_pattern.canCompileRegexVm(begin_regex) or !textmate_pattern.canCompileRegexVm(end_regex)) return false;
    try writeRule2(writer, "regex_vm_block", begin_regex, end_regex, scope);
    return true;
}

pub fn writeRegexVmWhileBlock(writer: anytype, begin: []const u8, while_pattern: []const u8, scope: []const u8) !bool {
    if (begin.len == 0 or while_pattern.len == 0) return false;
    if (std.mem.eql(u8, begin, while_pattern)) {
        if (begin.len > max_native_string or !textmate_pattern.canCompileRegexVm(begin)) return false;
        try writeRule1(writer, "regex_vm_line_comment", begin, scope);
        return true;
    }
    if (!std.mem.startsWith(u8, while_pattern, "^") and !std.mem.startsWith(u8, while_pattern, "\\A")) return false;
    if (begin.len > max_native_string or while_pattern.len + 4 > max_native_string) return false;
    if (!textmate_pattern.canCompileRegexVm(begin) or !textmate_pattern.canCompileRegexVm(while_pattern)) return false;
    var end_buf: [max_native_string]u8 = undefined;
    end_buf[0] = '(';
    end_buf[1] = '?';
    end_buf[2] = '!';
    @memcpy(end_buf[3..][0..while_pattern.len], while_pattern);
    end_buf[3 + while_pattern.len] = ')';
    const end = end_buf[0 .. while_pattern.len + 4];
    if (!textmate_pattern.canCompileRegexVm(end)) return false;
    try writeRule2(writer, "regex_vm_after_line_block", begin, end, scope);
    try writeRule1(writer, "regex_vm_line_comment", begin, scope);
    return true;
}

fn writeRule1(writer: anytype, kind: []const u8, value: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, value);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

fn writeRule2(writer: anytype, kind: []const u8, first: []const u8, second: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, first);
    try writer.writeByte(' ');
    try writeDslString(writer, second);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

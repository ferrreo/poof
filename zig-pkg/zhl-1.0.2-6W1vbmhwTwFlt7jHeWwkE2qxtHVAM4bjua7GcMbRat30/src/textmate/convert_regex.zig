const std = @import("std");
const dsl = @import("../native/dsl.zig");
const textmate_pattern = @import("pattern.zig");

const max_native_string = dsl.max_string_bytes;

pub fn canSplitAlternation(pattern: []const u8) bool {
    const split = textmate_pattern.splitTopLevelAlternationGroup(pattern) orelse return false;
    var chunk: [max_native_string]u8 = undefined;
    var out: usize = 0;
    var has_alt = false;

    appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
    var start: usize = 0;
    while (true) {
        const end = textmate_pattern.topLevelPipeFromWithExtended(split.body, start, split.extended) orelse split.body.len;
        const alt = split.body[start..end];
        const extra = alt.len + @intFromBool(has_alt);
        if (out + extra + 1 + split.suffix.len > max_native_string) {
            if (!has_alt or !canFinish(&chunk, out, split.suffix)) return false;
            out = 0;
            has_alt = false;
            appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
        }
        if (has_alt) {
            chunk[out] = '|';
            out += 1;
        }
        if (out + alt.len + 1 + split.suffix.len > max_native_string) return false;
        @memcpy(chunk[out..][0..alt.len], alt);
        out += alt.len;
        has_alt = true;
        if (end == split.body.len) break;
        start = end + 1;
    }
    return has_alt and canFinish(&chunk, out, split.suffix);
}

pub fn writeSplitAlternationRules(writer: anytype, pattern: []const u8, scope: []const u8) !bool {
    if (scope.len > max_native_string) return false;
    if (!canSplitAlternation(pattern)) return false;
    const split = textmate_pattern.splitTopLevelAlternationGroup(pattern) orelse return false;
    var chunk: [max_native_string]u8 = undefined;
    var out: usize = 0;
    var has_alt = false;

    appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
    var start: usize = 0;
    while (true) {
        const end = textmate_pattern.topLevelPipeFromWithExtended(split.body, start, split.extended) orelse split.body.len;
        const alt = split.body[start..end];
        const extra = alt.len + @intFromBool(has_alt);
        if (out + extra + 1 + split.suffix.len > max_native_string) {
            if (!has_alt) return false;
            try finishRule(writer, &chunk, out, split.suffix, scope);
            out = 0;
            has_alt = false;
            appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
        }
        if (has_alt) {
            chunk[out] = '|';
            out += 1;
        }
        if (out + alt.len + 1 + split.suffix.len > max_native_string) return false;
        @memcpy(chunk[out..][0..alt.len], alt);
        out += alt.len;
        has_alt = true;
        if (end == split.body.len) break;
        start = end + 1;
    }
    if (!has_alt) return false;
    try finishRule(writer, &chunk, out, split.suffix, scope);
    return true;
}

pub fn writeSplitAlternationBlockRules(writer: anytype, begin: []const u8, end: []const u8, scope: []const u8) !bool {
    if (scope.len > max_native_string or end.len > max_native_string or !textmate_pattern.canCompileRegexVm(end)) return false;
    if (!canSplitAlternation(begin)) return false;
    const split = textmate_pattern.splitTopLevelAlternationGroup(begin) orelse return false;
    var chunk: [max_native_string]u8 = undefined;
    var out: usize = 0;
    var has_alt = false;

    appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
    var start: usize = 0;
    while (true) {
        const alt_end = textmate_pattern.topLevelPipeFromWithExtended(split.body, start, split.extended) orelse split.body.len;
        const alt = split.body[start..alt_end];
        const extra = alt.len + @intFromBool(has_alt);
        if (out + extra + 1 + split.suffix.len > max_native_string) {
            if (!has_alt) return false;
            try finishBlockRule(writer, &chunk, out, split.suffix, end, scope);
            out = 0;
            has_alt = false;
            appendPrefix(&chunk, &out, split.prefix, split.open) orelse return false;
        }
        if (has_alt) {
            chunk[out] = '|';
            out += 1;
        }
        if (out + alt.len + 1 + split.suffix.len > max_native_string) return false;
        @memcpy(chunk[out..][0..alt.len], alt);
        out += alt.len;
        has_alt = true;
        if (alt_end == split.body.len) break;
        start = alt_end + 1;
    }
    if (!has_alt) return false;
    try finishBlockRule(writer, &chunk, out, split.suffix, end, scope);
    return true;
}

fn appendPrefix(buf: []u8, out: *usize, prefix: []const u8, open: []const u8) ?void {
    if (prefix.len + open.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    out.* = prefix.len;
    @memcpy(buf[out.*..][0..open.len], open);
    out.* += open.len;
}

fn finishBlockRule(writer: anytype, buf: []u8, body_end: usize, suffix: []const u8, end: []const u8, scope: []const u8) !void {
    if (!canFinish(buf, body_end, suffix)) return error.UnsupportedRegex;
    const pattern = buf[0 .. body_end + 1 + suffix.len];
    try writer.writeAll("        regex_vm_block ");
    try writeDslString(writer, pattern);
    try writer.writeByte(' ');
    try writeDslString(writer, end);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

fn finishRule(writer: anytype, buf: []u8, body_end: usize, suffix: []const u8, scope: []const u8) !void {
    if (!canFinish(buf, body_end, suffix)) return error.UnsupportedRegex;
    const end = body_end + 1 + suffix.len;
    const pattern = buf[0..end];
    try writer.writeAll("        regex_vm ");
    try writeDslString(writer, pattern);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

fn canFinish(buf: []u8, body_end: usize, suffix: []const u8) bool {
    var end = body_end;
    buf[end] = ')';
    end += 1;
    @memcpy(buf[end..][0..suffix.len], suffix);
    end += suffix.len;
    return textmate_pattern.canCompileRegexVm(buf[0..end]);
}

fn writeDslString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "split alternation writer skips unsupported chunks without partial output" {
    const pattern = "(?:a|(?=a)+|b)";
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    const wrote = try writeSplitAlternationRules(&out, pattern, "string.quoted.single.haskell");

    try std.testing.expect(!wrote);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

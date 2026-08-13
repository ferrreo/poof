const std = @import("std");
const regex_escape = @import("escape.zig");

pub const Result = struct {
    supported: bool,
    end: ?usize = null,
};

pub fn match(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, ignore_case: bool) Result {
    if (!supported(pattern, start, end)) return .{ .supported = false };

    var i = start;
    var at = pos;
    var matches = true;
    while (i <= end) {
        if (i == end or pattern[i] == '|') {
            if (matches) return .{ .supported = true, .end = at };
            i += 1;
            at = pos;
            matches = true;
            continue;
        }
        const literal = readByte(pattern, &i, end) orelse return .{ .supported = false };
        if (at >= text.len or !bytesEqual(text[at], literal, ignore_case)) matches = false else at += 1;
    }
    return .{ .supported = true };
}

fn supported(pattern: []const u8, start: usize, end: usize) bool {
    if (start == end) return false;
    var i = start;
    var branch_start = start;
    while (i < end) {
        if (pattern[i] == '|') {
            if (i == branch_start) return false;
            i += 1;
            branch_start = i;
            continue;
        }
        if (std.mem.indexOfScalar(u8, ".^$*+?[](){}", pattern[i]) != null) return false;
        if (readByte(pattern, &i, end) == null) return false;
    }
    return branch_start < end;
}

fn readByte(pattern: []const u8, index: *usize, end: usize) ?u8 {
    if (pattern[index.*] != '\\') {
        const byte = pattern[index.*];
        index.* += 1;
        return byte;
    }
    index.* += 1;
    if (index.* >= end) return null;
    if (regex_escape.parseEscapedByte(pattern, index.*, end)) |parsed| {
        index.* = parsed.end;
        return parsed.byte;
    }
    const byte = pattern[index.*];
    if (regex_escape.isClass(byte) or regex_escape.isNonLiteral(byte) or
        byte == 'b' or byte == 'B' or byte == 'g' or byte == 'k' or byte == 'x' or
        byte == 'p' or byte == 'P' or std.ascii.isDigit(byte)) return null;
    index.* += 1;
    return regex_escape.byte(byte);
}

fn bytesEqual(a: u8, b: u8, ignore_case: bool) bool {
    return a == b or (ignore_case and regex_escape.asciiLower(a) == regex_escape.asciiLower(b));
}

test "matches literal alternatives without the regex VM" {
    try std.testing.expectEqual(Result{ .supported = true, .end = 3 }, match("Add|Get|Write", 0, 13, "get-item", 0, true));
    try std.testing.expectEqual(Result{ .supported = true }, match("Add|Get|Write", 0, 13, "set-item", 0, true));
    try std.testing.expectEqual(Result{ .supported = false }, match("Get|G.t", 0, 7, "Get", 0, false));
}

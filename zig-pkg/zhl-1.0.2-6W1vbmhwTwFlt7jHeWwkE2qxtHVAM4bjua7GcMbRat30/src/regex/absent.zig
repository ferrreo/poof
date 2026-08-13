const std = @import("std");
const regex_class_parse = @import("class_parse.zig");

pub const Parts = struct {
    absent_start: usize,
    absent_end: usize,
    expr_start: usize,
    expr_end: usize,
    group_end: usize,
};

pub fn expressionParts(pattern: []const u8, start: usize) ?Parts {
    if (!std.mem.startsWith(u8, pattern[start..], "(?~|")) return null;
    const group_end = findGroupEnd(pattern, start) orelse return null;
    const absent_start = start + 4;
    const split = topLevelPipe(pattern, absent_start, group_end) orelse return null;
    if (split == absent_start or split + 1 == group_end) return null;
    return .{
        .absent_start = absent_start,
        .absent_end = split,
        .expr_start = split + 1,
        .expr_end = group_end,
        .group_end = group_end,
    };
}

pub fn repeaterParts(pattern: []const u8, start: usize) ?Parts {
    if (!std.mem.startsWith(u8, pattern[start..], "(?~") or std.mem.startsWith(u8, pattern[start..], "(?~|")) return null;
    const group_end = findGroupEnd(pattern, start) orelse return null;
    const absent_start = start + 3;
    if (absent_start == group_end) return null;
    return .{
        .absent_start = absent_start,
        .absent_end = group_end,
        .expr_start = 0,
        .expr_end = 0,
        .group_end = group_end,
    };
}

pub fn stopperParts(pattern: []const u8, start: usize) ?Parts {
    if (!std.mem.startsWith(u8, pattern[start..], "(?~|")) return null;
    const group_end = findGroupEnd(pattern, start) orelse return null;
    const absent_start = start + 4;
    if (absent_start == group_end or topLevelPipe(pattern, absent_start, group_end) != null) return null;
    return .{
        .absent_start = absent_start,
        .absent_end = group_end,
        .expr_start = 0,
        .expr_end = 0,
        .group_end = group_end,
    };
}

pub fn rangeClearEnd(pattern: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, pattern[start..], "(?~|")) return null;
    const group_end = findGroupEnd(pattern, start) orelse return null;
    return if (start + 4 == group_end) group_end else null;
}

fn topLevelPipe(pattern: []const u8, start: usize, end: usize) ?usize {
    var i = start;
    while (i < end) : (i += 1) {
        if (pattern[i] == '|') return i;
        if (commentGroupEnd(pattern, i, end)) |next| {
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(') {
            i = findGroupEnd(pattern, i) orelse return null;
        }
    }
    return null;
}

fn findGroupEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (commentGroupEnd(pattern, i, pattern.len)) |next| {
            if (i == start) return next - 1;
            i = next - 1;
            continue;
        }
        if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = regex_class_parse.findEnd(pattern, i) orelse return null else if (pattern[i] == '(') depth += 1 else if (pattern[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn commentGroupEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    if (start + 3 > end or !std.mem.startsWith(u8, pattern[start..end], "(?#")) return null;
    const close = std.mem.indexOfScalar(u8, pattern[start + 3 .. end], ')') orelse return null;
    return start + 4 + close;
}

test "regex absent parser splits expression form" {
    const parts = expressionParts("a(?~|345|\\d*|[a-z]+)z", 1).?;
    const repeater = repeaterParts("a(?~345)z", 1).?;
    const stopper = stopperParts("a(?~|345)z", 1).?;

    try std.testing.expectEqualSlices(u8, "345", "a(?~|345|\\d*|[a-z]+)z"[parts.absent_start..parts.absent_end]);
    try std.testing.expectEqualSlices(u8, "\\d*|[a-z]+", "a(?~|345|\\d*|[a-z]+)z"[parts.expr_start..parts.expr_end]);
    try std.testing.expectEqualSlices(u8, "345", "a(?~345)z"[repeater.absent_start..repeater.absent_end]);
    try std.testing.expectEqualSlices(u8, "345", "a(?~|345)z"[stopper.absent_start..stopper.absent_end]);
    try std.testing.expectEqual(@as(?usize, 4), rangeClearEnd("(?~|)", 0));
    try std.testing.expect(expressionParts("(?~345)", 0) == null);
    try std.testing.expect(expressionParts("(?~|345)", 0) == null);
    try std.testing.expect(repeaterParts("(?~)", 0) == null);
    try std.testing.expect(repeaterParts("(?~|345|\\d*)", 0) == null);
    try std.testing.expect(stopperParts("(?~|)", 0) == null);
    try std.testing.expect(stopperParts("(?~|345|\\d*)", 0) == null);
}

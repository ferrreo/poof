const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_escape = @import("escape.zig");

pub fn commentGroupEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    if (start + 3 > end or !std.mem.startsWith(u8, pattern[start..end], "(?#")) return null;
    const close = std.mem.indexOfScalar(u8, pattern[start + 3 .. end], ')') orelse return null;
    return start + 4 + close;
}

pub fn isolatedFlagEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    if (start + 3 > end or pattern[start] != '(' or pattern[start + 1] != '?') return null;
    return if (regex_escape.flagRunEnd(pattern, start + 2, end, ')')) |i| i + 1 else null;
}

pub fn inlineFlagColonEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    if (start + 3 > end or pattern[start] != '(' or pattern[start + 1] != '?') return null;
    return regex_escape.flagRunEnd(pattern, start + 2, end, ':');
}

pub fn ignoredEnd(pattern: []const u8, start: usize, end: usize, extended: bool) ?usize {
    if (commentGroupEnd(pattern, start, end)) |next| return next;
    if (!extended or start >= end or pattern[start] != '#') return null;
    const newline = std.mem.indexOfScalar(u8, pattern[start..end], '\n') orelse return end;
    return start + newline + 1;
}

pub fn extendedAt(pattern: []const u8, end: usize) bool {
    var extended = false;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (ignoredEnd(pattern, i, end, extended)) |next| {
            i = next - 1;
        } else if (isolatedFlagEnd(pattern, i, end)) |next| {
            extended = applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return extended;
        }
    }
    return extended;
}

pub fn applyExtendedFlag(run: []const u8, parent: bool) bool {
    var extended = parent;
    var negated = false;
    var i: usize = 0;
    while (regex_escape.flagTokenEnd(run, i, run.len)) |next| {
        if (run[i] == '-') negated = true else if (run[i] == 'x') extended = !negated;
        i = next;
    }
    return extended;
}

pub fn topLevelPipe(pattern: []const u8, start: usize, end: usize, initial_extended: bool) ?usize {
    var i = start;
    var extended = initial_extended;
    while (i < end) : (i += 1) {
        if (ignoredEnd(pattern, i, end, extended)) |next| {
            i = next - 1;
        } else if (isolatedFlagEnd(pattern, i, end)) |next| {
            extended = applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '|') {
            return i;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(') {
            i = findGroupEnd(pattern, i, extended) orelse return null;
        }
    }
    return null;
}

pub fn findGroupEnd(pattern: []const u8, start: usize, initial_extended: bool) ?usize {
    var depth: usize = 0;
    var extended = initial_extended;
    var extended_stack = [_]bool{false} ** 64;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            if (i == start) return next - 1;
            i = next - 1;
        } else if (isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(') {
            if (depth == extended_stack.len) return null;
            extended_stack[depth] = extended;
            depth += 1;
            if (inlineFlagColonEnd(pattern, i, pattern.len)) |flag_end| extended = applyExtendedFlag(pattern[i + 2 .. flag_end], extended);
        } else if (pattern[i] == ')') {
            if (depth == 0) return null;
            depth -= 1;
            extended = extended_stack[depth];
            if (depth == 0) return i;
        }
    }
    return null;
}

test "regex scanner ignores active extended comments" {
    try std.testing.expectEqual(@as(?usize, 13), ignoredEnd("(?x)a # (?q)\nb", 6, 14, true));
    try std.testing.expectEqual(@as(?usize, null), ignoredEnd("a # (?q)\nb", 2, 9, false));
    try std.testing.expect(extendedAt("(?x)a # )\n", 10));
    try std.testing.expect(!extendedAt("(?x)(?-x)# )\n", 13));
    try std.testing.expectEqual(@as(?usize, 16), findGroupEnd("(?x)(a # fake )\n)", 4, true));
    try std.testing.expectEqual(@as(?usize, 11), topLevelPipe("a # fake |\n|b", 0, 13, true));
    try std.testing.expectEqual(@as(?usize, 10), findGroupEnd("(?x)(?-x:#)", 4, true));
}

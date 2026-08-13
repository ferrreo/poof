const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_escape = @import("escape.zig");
const regex_refs = @import("refs.zig");
const regex_scan = @import("scan.zig");

pub fn balanced(pattern: []const u8) bool {
    var extended = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
            continue;
        }
        if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return false else if (pattern[i] == '(') {
            if (unsupportedGroupStart(pattern, i)) return false;
            i = findGroupEnd(pattern, i, extended) orelse return false;
        } else if (pattern[i] == ')') return false;
    }
    return true;
}

pub fn escapesSupported(pattern: []const u8) bool {
    var extended = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            if (i + 1 >= pattern.len) return false;
            i += 1;
        }
    }
    return true;
}

pub fn lookaroundSupported(pattern: []const u8) bool {
    var extended = false;
    var i: usize = 0;
    while (i + 3 < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
            continue;
        }
        if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = findClassEnd(pattern, i) orelse return false;
        } else if (std.mem.startsWith(u8, pattern[i..], "(?=") or std.mem.startsWith(u8, pattern[i..], "(?!")) {
            const close = findGroupEnd(pattern, i, extended) orelse return false;
            if (quantifierFollows(pattern, close + 1)) return false;
        } else if (std.mem.startsWith(u8, pattern[i..], "(?<=") or std.mem.startsWith(u8, pattern[i..], "(?<!")) {
            const close = findGroupEnd(pattern, i, extended) orelse return false;
            if (quantifierFollows(pattern, close + 1)) return false;
            if (pattern[i + 3] == '!' and hasCapturingGroup(pattern, i + 4, close, extended)) return false;
            i = close;
        }
    }
    return true;
}

pub fn boundedRepeatsSupported(pattern: []const u8, max_repeat: usize) bool {
    var extended = false;
    var prev_term = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            prev_term = false;
            i = next - 1;
        } else switch (pattern[i]) {
            '\\' => {
                if (i + 1 >= pattern.len) return true;
                if (regex_escape.parseCodepoint(pattern, i + 1, pattern.len)) |parsed| {
                    i = parsed.end - 1;
                } else {
                    i += 1;
                }
                prev_term = true;
            },
            '[' => {
                i = findClassEnd(pattern, i) orelse return true;
                prev_term = true;
            },
            '{' => {
                if (!prev_term) {
                    prev_term = true;
                    continue;
                }
                const bound = parseRepeatBound(pattern, i) orelse {
                    prev_term = true;
                    continue;
                };
                if (bound.max < bound.min or bound.min > max_repeat or bound.max > max_repeat) return false;
                i = bound.end - 1;
                prev_term = false;
            },
            '?', '*', '+' => {
                if (prev_term) {
                    if (i + 1 < pattern.len and (pattern[i + 1] == '?' or pattern[i + 1] == '+')) i += 1;
                    prev_term = false;
                } else {
                    prev_term = true;
                }
            },
            '|' => prev_term = false,
            ')' => prev_term = true,
            else => prev_term = true,
        }
    }
    return true;
}

const Bound = struct { min: usize, max: usize, end: usize };

fn parseRepeatBound(pattern: []const u8, start: usize) ?Bound {
    var i = start + 1;
    const omitted_min = i < pattern.len and pattern[i] == ',';
    const min = if (omitted_min) 0 else readNumber(pattern, &i) orelse return null;
    var max = min;
    if (i < pattern.len and pattern[i] == ',') {
        i += 1;
        if (i < pattern.len and pattern[i] == '}') max = min else max = readNumber(pattern, &i) orelse return null;
    }
    if (i >= pattern.len or pattern[i] != '}') return null;
    return .{ .min = min, .max = max, .end = i + 1 };
}

fn hasCapturingGroup(pattern: []const u8, start: usize, end: usize, initial_extended: bool) bool {
    var extended = initial_extended;
    var i = start;
    while (i < end) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, end, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = findClassEnd(pattern, i) orelse return true;
        } else if (pattern[i] == '(' and isCapturingGroup(pattern, i)) {
            return true;
        }
    }
    return false;
}

fn quantifierFollows(pattern: []const u8, start: usize) bool {
    if (start >= pattern.len) return false;
    return switch (pattern[start]) {
        '?', '*', '+' => true,
        '{' => boundEnd(pattern, start) != null,
        else => false,
    };
}

fn boundEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    const omitted_min = i < pattern.len and pattern[i] == ',';
    if (!omitted_min and readNumber(pattern, &i) == null) return null;
    if (i < pattern.len and pattern[i] == ',') {
        i += 1;
        if (omitted_min and i < pattern.len and pattern[i] == '}') return null;
        _ = readNumber(pattern, &i);
    }
    if (i >= pattern.len or pattern[i] != '}') return null;
    return i + 1;
}

fn readNumber(pattern: []const u8, index: *usize) ?usize {
    const start = index.*;
    var value: usize = 0;
    while (index.* < pattern.len and std.ascii.isDigit(pattern[index.*])) : (index.* += 1) value = value * 10 + pattern[index.*] - '0';
    return if (index.* == start) null else value;
}

fn unsupportedGroupStart(pattern: []const u8, start: usize) bool {
    return start + 1 < pattern.len and pattern[start + 1] == '*';
}

fn isCapturingGroup(pattern: []const u8, start: usize) bool {
    if (start >= 2 and pattern[start - 2] == '(' and pattern[start - 1] == '?') return false;
    if (start + 1 >= pattern.len or pattern[start + 1] != '?') return true;
    return regex_refs.captureName(pattern, start) != null;
}

fn findGroupEnd(pattern: []const u8, start: usize, initial_extended: bool) ?usize {
    return regex_scan.findGroupEnd(pattern, start, initial_extended);
}

fn findClassEnd(pattern: []const u8, start: usize) ?usize {
    return regex_class_parse.findEnd(pattern, start);
}

test "regex validator handles structure and lookaround limits" {
    try std.testing.expect(balanced("(?=a)b"));
    try std.testing.expect(!balanced("(?=a"));
    try std.testing.expect(!balanced("(*callout)"));
    try std.testing.expect(balanced("(?x)(a # comment )\n)"));
    try std.testing.expect(balanced("(?x)(?-x:#)"));
    try std.testing.expect(!balanced("(a # literal )\n)"));
    try std.testing.expect(escapesSupported("(?# \\Q ignored)"));
    try std.testing.expect(escapesSupported("(?x)a # \\Q ignored\n"));
    try std.testing.expect(escapesSupported("\\\\Q"));
    try std.testing.expect(escapesSupported("\\Qliteral\\E"));
    try std.testing.expect(escapesSupported("[\\Q]"));
    try std.testing.expect(lookaroundSupported("(?=a)b"));
    try std.testing.expect(lookaroundSupported("(?x)(?=a # )\n)b"));
    try std.testing.expect(!lookaroundSupported("(?=a)*"));
    try std.testing.expect(!lookaroundSupported("(?<=a)*"));
    try std.testing.expect(!lookaroundSupported("(?<!a){2}"));
    try std.testing.expect(!lookaroundSupported("(?<!(a))b"));
    try std.testing.expect(!lookaroundSupported("(?<x>a)(?<!(b))c"));
    try std.testing.expect(boundedRepeatsSupported("a{1024}", 1024));
    try std.testing.expect(boundedRepeatsSupported("\\x{101}", 1024));
    try std.testing.expect(boundedRepeatsSupported("{1200}", 1024));
    try std.testing.expect(!boundedRepeatsSupported("a{1025}", 1024));
    try std.testing.expect(!boundedRepeatsSupported("(ab){1,1025}", 1024));
}

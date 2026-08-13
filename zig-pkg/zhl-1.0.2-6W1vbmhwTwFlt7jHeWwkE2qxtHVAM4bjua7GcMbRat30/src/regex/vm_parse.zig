const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_classes = @import("classes.zig");
const regex_escape = @import("escape.zig");
const regex_refs = @import("refs.zig");
const regex_scan = @import("scan.zig");

pub const max_repeat = 1024;

pub const Term = struct { start: usize, end: usize };
pub const Repeat = struct { min: usize = 1, max: usize = 1, next: usize, lazy: bool = false, possessive: bool = false, optional_exact: bool = false };

pub fn term(pattern: []const u8, start: usize, end: usize, extended: bool) ?Term {
    if (start >= end) return null;
    const term_end = switch (pattern[start]) {
        '\\' => escapedTermEnd(pattern, start, end),
        '[' => (regex_class_parse.findEnd(pattern, start) orelse return null) + 1,
        '(' => (regex_scan.findGroupEnd(pattern, start, extended) orelse return null) + 1,
        else => if (pattern[start] >= 0x80)
            start + (std.unicode.utf8ByteSequenceLength(pattern[start]) catch return null)
        else
            start + 1,
    };
    return .{ .start = start, .end = term_end };
}

pub fn quantifier(pattern: []const u8, start: usize, end: usize) Repeat {
    var out = Repeat{ .next = start };
    if (start >= end) return out;
    switch (pattern[start]) {
        '?' => out = .{ .min = 0, .max = 1, .next = start + 1 },
        '*' => out = .{ .min = 0, .max = max_repeat, .next = start + 1 },
        '+' => out = .{ .min = 1, .max = max_repeat, .next = start + 1 },
        '{' => out = parseBound(pattern, start, end) orelse out,
        else => {},
    }
    if (out.next < end) {
        if (pattern[out.next] == '?') {
            if (pattern[start] == '{' and out.min == out.max) out.optional_exact = true else out.lazy = true;
            out.next += 1;
        } else if (pattern[out.next] == '+') {
            out.possessive = pattern[start] != '{';
            out.next += 1;
        }
    }
    return out;
}

fn parseBound(pattern: []const u8, start: usize, end: usize) ?Repeat {
    var i = start + 1;
    const omitted_min = i < end and pattern[i] == ',';
    const min: usize = if (omitted_min) 0 else readNumber(pattern, &i) orelse return null;
    var max = min;
    if (i < end and pattern[i] == ',') {
        i += 1;
        if (omitted_min and i < end and pattern[i] == '}') return null;
        max = readNumber(pattern, &i) orelse max_repeat;
    }
    if (i >= end or pattern[i] != '}') return null;
    return .{ .min = min, .max = @min(max, max_repeat), .next = i + 1 };
}

fn readNumber(pattern: []const u8, index: *usize) ?usize {
    const start = index.*;
    var value: usize = 0;
    while (index.* < pattern.len and std.ascii.isDigit(pattern[index.*])) : (index.* += 1) value = value * 10 + pattern[index.*] - '0';
    return if (index.* == start) null else value;
}

fn escapedTermEnd(pattern: []const u8, start: usize, end: usize) usize {
    if (start + 1 >= end) return end;
    if ((pattern[start + 1] == 'p' or pattern[start + 1] == 'P') and start + 2 < end and regex_classes.isShortUnicodeProperty(pattern[start + 2])) {
        return start + 3;
    }
    if ((pattern[start + 1] == 'p' or pattern[start + 1] == 'P') and start + 2 < end and pattern[start + 2] == '{') {
        if (std.mem.indexOfScalar(u8, pattern[start + 3 .. end], '}')) |close| return start + 4 + close;
    }
    if (pattern[start + 1] == 'k' or pattern[start + 1] == 'g') {
        if (regex_refs.name(pattern, start + 1, end)) |value| return start + value.len + 4;
    }
    if (pattern[start + 1] == 'x' or pattern[start + 1] == 'o' or pattern[start + 1] == 'u') {
        if (regex_escape.parseCodepoint(pattern, start + 1, end)) |parsed| return parsed.end;
    }
    if (pattern[start + 1] == '0') {
        if (regex_escape.parseOctal(pattern, start + 1, end)) |parsed| return parsed.end;
    }
    if (pattern[start + 1] == 'c' or pattern[start + 1] == 'C') {
        const parsed = if (pattern[start + 1] == 'c') regex_escape.parseControl(pattern, start + 1, end) else regex_escape.parseControlDash(pattern, start + 1, end);
        if (parsed) |control| return control.end;
    }
    if (pattern[start + 1] == 'M') {
        if (regex_escape.parseMeta(pattern, start + 1, end)) |parsed| return parsed.end;
    }
    return start + 2;
}

const std = @import("std");

pub const Kind = enum(u8) {
    none,
    any,
    unescaped,
};

pub fn classify(pattern: []const u8) Kind {
    if (!hasVirtualNewline(pattern)) return .none;
    return if (needsUnescapedLineEnd(pattern)) .unescaped else .any;
}

pub fn matches(kind: Kind, line: []const u8) bool {
    return switch (kind) {
        .none => false,
        .any => true,
        .unescaped => !endsEscaped(line),
    };
}

fn hasVirtualNewline(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '[') {
            i = classEnd(pattern, i) orelse pattern.len;
        } else if (std.mem.startsWith(u8, pattern[i..], "(?<=")) {
            const end = groupEnd(pattern, i) orelse return false;
            if (containsNewlineToken(pattern[i + 4 .. end], false)) return true;
            i = end;
        } else if (std.mem.startsWith(u8, pattern[i..], "(?<!")) {
            i = groupEnd(pattern, i) orelse pattern.len;
        } else if (std.mem.startsWith(u8, pattern[i..], "(?=")) {
            const end = groupEnd(pattern, i) orelse return false;
            if (containsNewlineToken(pattern[i + 3 .. end], true)) return true;
            i = end;
        } else if (pattern[i] == '\\' and i + 1 < pattern.len) {
            if (pattern[i + 1] == 'n') return true;
            i += 1;
        }
        i += 1;
    }
    return false;
}

fn containsNewlineToken(pattern: []const u8, comptime classes_match: bool) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '[') {
            const end = classEnd(pattern, i) orelse return false;
            if (classes_match and classHasNewline(pattern[i + 1 .. end])) return true;
            i = end;
        } else if (pattern[i] == '\\' and i + 1 < pattern.len) {
            if (pattern[i + 1] == 'n') return true;
            i += 1;
        }
    }
    return false;
}

fn classHasNewline(class: []const u8) bool {
    var i: usize = 0;
    while (i < class.len) : (i += 1) {
        if (class[i] == '\\' and i + 1 < class.len) {
            if (class[i + 1] == 'n') return true;
            i += 1;
        }
    }
    return false;
}

fn needsUnescapedLineEnd(pattern: []const u8) bool {
    return std.mem.indexOf(u8, pattern, "(?<!\\\\)") != null or
        std.mem.indexOf(u8, pattern, "(?<!\\\\\\n)") != null;
}

fn endsEscaped(line: []const u8) bool {
    var count: usize = 0;
    var i = line.len;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) count += 1;
    return count % 2 == 1;
}

fn classEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') i += 1 else if (pattern[i] == ']') return i;
    }
    return null;
}

fn groupEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = classEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(') {
            depth += 1;
        } else if (pattern[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "TextMate line-end classifier finds virtual newline lookahead" {
    try std.testing.expectEqual(Kind.unescaped, classify("(?=[\\n\\&);`{|}]|[\\t ]*#|])(?<!\\\\)"));
    try std.testing.expectEqual(Kind.unescaped, classify("(?<!\\\\)(?=\\s*\\n)"));
    try std.testing.expectEqual(Kind.unescaped, classify("(?<=\\n)(?<!\\\\\\n)"));
    try std.testing.expectEqual(Kind.any, classify("\\n"));
    try std.testing.expectEqual(Kind.none, classify("(\")|([^\\n\\\\])$"));
    try std.testing.expect(matches(.unescaped, "name=\"zhl\""));
    try std.testing.expect(!matches(.unescaped, "printf \\"));
}

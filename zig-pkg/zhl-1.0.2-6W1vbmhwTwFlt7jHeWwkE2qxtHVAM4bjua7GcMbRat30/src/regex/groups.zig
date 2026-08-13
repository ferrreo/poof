const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_escape = @import("escape.zig");
const regex_absent = @import("absent.zig");
const regex_refs = @import("refs.zig");
const regex_scan = @import("scan.zig");

pub fn supported(pattern: []const u8) bool {
    var extended = false;
    var i: usize = 0;
    while (i + 2 < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (pattern[i] == '(' and repeatedIsolatedFlags(pattern, i)) {
            return false;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return false;
        } else if (pattern[i] == '(' and pattern[i + 1] == '?' and !extensionSupported(pattern, i)) {
            return false;
        }
    }
    return true;
}

fn repeatedIsolatedFlags(pattern: []const u8, start: usize) bool {
    if (start + 1 >= pattern.len or pattern[start + 1] != '?') return false;
    const close = regex_escape.flagRunEnd(pattern, start + 2, pattern.len, ')') orelse return false;
    if (close + 1 >= pattern.len) return false;
    return switch (pattern[close + 1]) {
        '*', '+', '?' => true,
        '{' => close + 2 < pattern.len and (std.ascii.isDigit(pattern[close + 2]) or pattern[close + 2] == ',') and std.mem.indexOfScalar(u8, pattern[close + 2 ..], '}') != null,
        else => false,
    };
}

fn extensionSupported(pattern: []const u8, start: usize) bool {
    return regex_escape.flagRunEnd(pattern, start + 2, pattern.len, ':') != null or
        regex_escape.flagRunEnd(pattern, start + 2, pattern.len, ')') != null or
        namedCaptureName(pattern, start) != null or
        std.mem.startsWith(u8, pattern[start..], "(?:") or
        std.mem.startsWith(u8, pattern[start..], "(?>") or
        std.mem.startsWith(u8, pattern[start..], "(?=") or
        std.mem.startsWith(u8, pattern[start..], "(?!") or
        std.mem.startsWith(u8, pattern[start..], "(?<=") or
        std.mem.startsWith(u8, pattern[start..], "(?<!") or
        std.mem.startsWith(u8, pattern[start..], "(?(") or
        regex_absent.expressionParts(pattern, start) != null or
        regex_absent.repeaterParts(pattern, start) != null or
        regex_absent.stopperParts(pattern, start) != null or
        regex_absent.rangeClearEnd(pattern, start) != null;
}

fn namedCaptureName(pattern: []const u8, start: usize) ?[]const u8 {
    return regex_refs.captureName(pattern, start);
}

test "regex group validator accepts supported extensions" {
    try std.testing.expect(supported("(?y{g}:a)(?y{w}:b)(?i)a(?<x>a)(?'y'b)(?:c)(?>d)(?=e)(?!f)(?<=g)(?<!h)(?(1)i|j)(?~x)(?~|x|y)(?~|x)(?~|)(?#k)"));
    try std.testing.expect(supported("(?x)(a # fake (?q) extension\n)"));
    try std.testing.expect(!supported("(?x)(?-x)# real (?q) extension\n"));
    try std.testing.expect(supported("(?<type-name>a)\\g<type-name>"));
    try std.testing.expect(supported("(D??ot)"));
    try std.testing.expect(supported("(?<type.name>a)\\g<type.name>"));
    try std.testing.expect(supported("(?'type.name'a)\\g'type.name'"));
    try std.testing.expect(supported("(?y{w})a"));
    try std.testing.expect(!supported("a(?i)*"));
    try std.testing.expect(!supported("a(?-i){1,2}"));
    try std.testing.expect(!supported("(?~)"));
    try std.testing.expect(!supported("(?q:a)"));
}

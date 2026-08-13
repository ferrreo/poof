const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_escape = @import("escape.zig");
const regex_refs = @import("refs.zig");
const regex_scan = @import("scan.zig");
const Flags = @import("vm_types.zig").Flags;

pub fn groupInnerStart(pattern: []const u8, start: usize) usize {
    if (std.mem.startsWith(u8, pattern[start..], "(?<=") or std.mem.startsWith(u8, pattern[start..], "(?<!")) return start + 4;
    if (std.mem.startsWith(u8, pattern[start..], "(?:") or std.mem.startsWith(u8, pattern[start..], "(?>") or std.mem.startsWith(u8, pattern[start..], "(?=") or std.mem.startsWith(u8, pattern[start..], "(?!")) return start + 3;
    if (inlineFlagInnerStart(pattern, start)) |inner| return inner;
    if (namedCaptureName(pattern, start)) |name| return start + name.len + 4;
    if (start + 3 < pattern.len and pattern[start + 1] == '?' and pattern[start + 2] == '<') {
        return (std.mem.indexOfScalar(u8, pattern[start + 3 ..], '>') orelse 0) + start + 4;
    }
    return start + 1;
}

pub fn inlineFlagInnerStart(pattern: []const u8, start: usize) ?usize {
    if (start + 3 >= pattern.len or pattern[start + 1] != '?') return null;
    return if (regex_escape.flagRunEnd(pattern, start + 2, pattern.len, ':')) |i| i + 1 else null;
}

pub fn inlineGroupFlags(pattern: []const u8, start: usize, parent: Flags) Flags {
    if (start + 3 >= pattern.len or pattern[start + 1] != '?') return parent;
    var i = start + 2;
    while (i < pattern.len and pattern[i] != ':') : (i += 1) {}
    return if (i < pattern.len) applyFlagRun(pattern[start + 2 .. i], parent) else parent;
}

pub fn commentGroupEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    return regex_scan.commentGroupEnd(pattern, start, end);
}

pub fn skipIgnored(pattern: []const u8, index: *usize, end: usize, flags: *Flags) bool {
    if (regex_scan.ignoredEnd(pattern, index.*, end, flags.extended)) |next| {
        index.* = next - 1;
        return true;
    }
    if (regex_scan.isolatedFlagEnd(pattern, index.*, end)) |next| {
        flags.* = applyFlagRun(pattern[index.* + 2 .. next - 1], flags.*);
        index.* = next - 1;
        return true;
    }
    return false;
}

pub fn applyFlagRun(run: []const u8, parent: Flags) Flags {
    var flags = parent;
    var negated = false;
    var i: usize = 0;
    while (regex_escape.flagTokenEnd(run, i, run.len)) |next| {
        switch (run[i]) {
            '-' => negated = true,
            'i' => flags.ignore_case = !negated,
            'm' => flags.dot_matches_line_break = !negated,
            'x' => flags.extended = !negated,
            'D' => flags.ascii_digit = !negated,
            'W' => flags.ascii_word = !negated,
            'S' => flags.ascii_space = !negated,
            'P' => flags.ascii_posix = !negated,
            else => {},
        }
        i = next;
    }
    return flags;
}

pub fn skipExtended(pattern: []const u8, start: usize, end: usize) usize {
    var i = start;
    while (i < end) {
        if (std.ascii.isWhitespace(pattern[i])) {
            i += 1;
        } else if (pattern[i] == '#') {
            while (i < end and pattern[i] != '\n') : (i += 1) {}
        } else break;
    }
    return i;
}

pub fn topLevelSplit(pattern: []const u8, start: usize, end: usize, flags: Flags) ?usize {
    return regex_scan.topLevelPipe(pattern, start, end, flags.extended);
}

pub fn findGroupEnd(pattern: []const u8, start: usize, flags: Flags) ?usize {
    return regex_scan.findGroupEnd(pattern, start, flags.extended);
}

pub fn findClassEnd(pattern: []const u8, start: usize) ?usize {
    return regex_class_parse.findEnd(pattern, start);
}

pub fn captureSlot(pattern: []const u8, group_start: usize) usize {
    var slot: usize = 0;
    var scan_flags = Flags{};
    var i: usize = 0;
    while (i < group_start) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) continue else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return slot + 1 else if (pattern[i] == '(' and isCapturingGroup(pattern, i)) slot += 1;
    }
    return slot + 1;
}

pub fn isCapturingGroup(pattern: []const u8, start: usize) bool {
    if (start >= 2 and pattern[start - 2] == '(' and pattern[start - 1] == '?') return false;
    return pattern[start] == '(' and (start + 1 >= pattern.len or pattern[start + 1] != '?' or namedCaptureName(pattern, start) != null);
}

pub fn namedCaptureName(pattern: []const u8, start: usize) ?[]const u8 {
    return regex_refs.captureName(pattern, start);
}

pub fn groupStart(pattern: []const u8, target_slot: usize, target_name: []const u8) ?usize {
    var slot: usize = 0;
    var scan_flags = Flags{};
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) continue else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return null else if (pattern[i] == '(' and isCapturingGroup(pattern, i)) {
            slot += 1;
            if (slot == target_slot or (target_name.len != 0 and std.mem.eql(u8, target_name, namedCaptureName(pattern, i) orelse ""))) return i;
        }
    }
    return null;
}

pub fn effectiveGroupFlags(pattern: []const u8, group_start: usize, parent: Flags) Flags {
    var flags = parent;
    var i: usize = 0;
    while (i < group_start) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &flags)) continue else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return flags else if (pattern[i] == '(') {
            const close = findGroupEnd(pattern, i, flags) orelse return flags;
            if (close < group_start) i = close else if (inlineFlagInnerStart(pattern, i) != null) flags = inlineGroupFlags(pattern, i, flags);
        }
    }
    return inlineGroupFlags(pattern, group_start, flags);
}

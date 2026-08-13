const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_scan = @import("scan.zig");

pub fn name(pattern: []const u8, index: usize, end: usize) ?[]const u8 {
    if (index + 2 >= end) return null;
    const close_byte: u8 = switch (pattern[index + 1]) {
        '<' => '>',
        '\'' => '\'',
        else => return null,
    };
    const start = index + 2;
    const close = std.mem.indexOfScalar(u8, pattern[start..end], close_byte) orelse return null;
    return if (close == 0) null else pattern[start .. start + close];
}

pub fn captureName(pattern: []const u8, start: usize) ?[]const u8 {
    if (start + 3 >= pattern.len or pattern[start] != '(' or pattern[start + 1] != '?') return null;
    if (pattern[start + 2] == '<') {
        if (pattern[start + 3] == '=' or pattern[start + 3] == '!') return null;
        const close = std.mem.indexOfScalar(u8, pattern[start + 3 ..], '>') orelse return null;
        const value = pattern[start + 3 .. start + 3 + close];
        return if (validCaptureName(value)) value else null;
    }
    if (pattern[start + 2] == '\'') {
        const close = std.mem.indexOfScalar(u8, pattern[start + 3 ..], '\'') orelse return null;
        const value = pattern[start + 3 .. start + 3 + close];
        return if (validCaptureName(value)) value else null;
    }
    return null;
}

pub fn validName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn validCaptureName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    return true;
}

pub fn sameLevel(value: []const u8) []const u8 {
    var level = value.len;
    for (value[1..], 1..) |byte, i| {
        if (byte == '+' or byte == '-') level = i;
    }
    if (level + 1 >= value.len) return value;
    for (value[level + 1 ..]) |byte| if (byte != '0') return value;
    return value[0..level];
}

pub fn positiveInteger(value: []const u8) ?usize {
    const out = nonnegativeInteger(value) orelse return null;
    return if (out == 0) null else out;
}

pub fn nonnegativeInteger(value: []const u8) ?usize {
    var out: usize = 0;
    if (value.len == 0) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        out = out * 10 + byte - '0';
    }
    return out;
}

pub fn relativeInteger(value: []const u8) ?isize {
    if (value.len < 2 or (value[0] != '-' and value[0] != '+')) return null;
    const magnitude = positiveInteger(value[1..]) orelse return null;
    return if (value[0] == '-') -@as(isize, @intCast(magnitude)) else @intCast(magnitude);
}

pub fn referencesSupported(pattern: []const u8) bool {
    const total = countCapturesUntil(pattern, pattern.len) orelse return false;
    if (!leftmostCallsSupported(pattern, total)) return false;
    var extended = false;
    var i: usize = 0;
    while (i + 1 < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return false;
        } else if (pattern[i] == '\\') {
            i += 1;
            switch (pattern[i]) {
                '1'...'9' => if (pattern[i] - '0' > total) return false,
                'k', 'g' => {
                    if (name(pattern, i, pattern.len)) |raw| {
                        if (!referenceSupported(pattern, raw, i, total, pattern[i] == 'g')) return false;
                    }
                },
                else => {},
            }
        }
    }
    return true;
}

fn referenceSupported(pattern: []const u8, raw: []const u8, index: usize, total: usize, call: bool) bool {
    const value = sameLevel(raw);
    if (if (call) nonnegativeInteger(value) else positiveInteger(value)) |slot| return slot <= total;
    if (relativeInteger(value)) |offset| return relativeSlot(pattern, index, offset, total) != null;
    if (!call and !validName(value)) return false;
    const count = namedCount(pattern, value) orelse return false;
    return if (call) count == 1 else count != 0;
}

fn leftmostCallsSupported(pattern: []const u8, total: usize) bool {
    if (leftmostCallTargets(pattern, 0, pattern.len, 0, "", total)) return false;
    var slot: usize = 0;
    var extended = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return false;
        } else if (isCapturingGroup(pattern, i)) {
            slot += 1;
            const end = findGroupEnd(pattern, i) orelse return false;
            const capture_name = namedCaptureName(pattern, i) orelse "";
            if (leftmostCallTargets(pattern, groupInnerStart(pattern, i), end, slot, capture_name, total)) return false;
        }
    }
    return true;
}

fn leftmostCallTargets(pattern: []const u8, start: usize, end: usize, target_slot: usize, target_name: []const u8, total: usize) bool {
    var branch = start;
    while (branch < end) {
        if (leftmostCallIndex(pattern, branch, end)) |call| {
            const raw = name(pattern, call, end) orelse return false;
            const value = sameLevel(raw);
            if (nonnegativeInteger(value)) |slot| {
                if (slot == target_slot) return true;
            } else if (relativeInteger(value)) |offset| {
                if (relativeSlot(pattern, call, offset, total) == target_slot) return true;
            } else if (target_name.len != 0 and std.mem.eql(u8, value, target_name)) return true;
        }
        branch = (topLevelPipe(pattern, branch, end) orelse return false) + 1;
    }
    return false;
}

fn leftmostCallIndex(pattern: []const u8, start: usize, end: usize) ?usize {
    var i = start;
    var extended = regex_scan.extendedAt(pattern, start);
    while (i < end) {
        if (regex_scan.ignoredEnd(pattern, i, end, extended)) |next| {
            i = next;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next;
        } else break;
    }
    return if (i + 1 < end and pattern[i] == '\\' and pattern[i + 1] == 'g' and name(pattern, i + 1, end) != null) i + 1 else null;
}

fn topLevelPipe(pattern: []const u8, start: usize, end: usize) ?usize {
    var i = start;
    var extended = regex_scan.extendedAt(pattern, start);
    while (i < end) : (i += 1) {
        if (pattern[i] == '|') return i;
        if (regex_scan.ignoredEnd(pattern, i, end, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
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

fn relativeSlot(pattern: []const u8, index: usize, offset: isize, total: usize) ?usize {
    const before = countCapturesUntil(pattern, index) orelse return null;
    const slot = if (offset >= 0) before + @as(usize, @intCast(offset)) else blk: {
        const back: usize = @intCast(-offset);
        break :blk if (back <= before) before - back + 1 else return null;
    };
    return if (slot != 0 and slot <= total) slot else null;
}

fn namedCount(pattern: []const u8, target: []const u8) ?usize {
    var count: usize = 0;
    var extended = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| i = next - 1 else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = regex_class_parse.findEnd(pattern, i) orelse return null else if (namedCaptureName(pattern, i)) |capture| {
            if (std.mem.eql(u8, target, capture)) count += 1;
        }
    }
    return count;
}

pub fn hasNamedCapture(pattern: []const u8) ?bool {
    var extended = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return null;
        } else if (namedCaptureName(pattern, i) != null) {
            return true;
        }
    }
    return false;
}

fn countCapturesUntil(pattern: []const u8, end: usize) ?usize {
    var count: usize = 0;
    var extended = false;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, end, extended)) |next| i = @min(next - 1, end) else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = regex_class_parse.findEnd(pattern, i) orelse return null else if (isCapturingGroup(pattern, i)) count += 1;
    }
    return count;
}

fn isCapturingGroup(pattern: []const u8, start: usize) bool {
    if (start >= 2 and pattern[start - 2] == '(' and pattern[start - 1] == '?') return false;
    return pattern[start] == '(' and (start + 1 >= pattern.len or pattern[start + 1] != '?' or namedCaptureName(pattern, start) != null);
}

fn namedCaptureName(pattern: []const u8, start: usize) ?[]const u8 {
    return captureName(pattern, start);
}

fn groupInnerStart(pattern: []const u8, start: usize) usize {
    if (namedCaptureName(pattern, start)) |capture| return start + capture.len + 4;
    return start + 1;
}

fn findGroupEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var extended = regex_scan.extendedAt(pattern, start);
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            if (i == start) return next - 1;
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = regex_class_parse.findEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(') {
            depth += 1;
        } else if (pattern[i] == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "regex refs ignore active extended comments" {
    try std.testing.expect(referencesSupported("(?x)(a) # fake \\2 and (capture)\n\\1"));
    try std.testing.expect(!referencesSupported("(a) # literal \\2\n\\2"));
    try std.testing.expect(!referencesSupported("(?x)(a)(?-x)# literal \\2\n\\1"));
}

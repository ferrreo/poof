const std = @import("std");

pub const FenceLine = struct {
    slot: u8,
    negate: bool = false,
};

pub fn parseFenceLine(pattern: []const u8) ?FenceLine {
    const positive_prefix = "^(?: {0,3}\\";
    const positive_suffix = "-*[\\t ]*|[\\t ]*\\.{3})$";
    if (std.mem.startsWith(u8, pattern, positive_prefix) and std.mem.endsWith(u8, pattern, positive_suffix)) {
        const slot = pattern[positive_prefix.len];
        if (pattern.len == positive_prefix.len + 1 + positive_suffix.len and slot >= '1' and slot <= '9') return .{ .slot = slot - '0' };
    }
    const alternate_positive_prefix = "^ {,3}\\";
    const alternate_positive_suffix = "-*[\\t ]*$|^[\\t ]*\\.{3}$";
    if (std.mem.startsWith(u8, pattern, alternate_positive_prefix) and std.mem.endsWith(u8, pattern, alternate_positive_suffix)) {
        const slot = pattern[alternate_positive_prefix.len];
        if (pattern.len == alternate_positive_prefix.len + 1 + alternate_positive_suffix.len and slot >= '1' and slot <= '9') return .{ .slot = slot - '0' };
    }
    const alternate_positive_space_first_suffix = "-*[ \\t]*$|^[ \\t]*\\.{3}$";
    if (std.mem.startsWith(u8, pattern, alternate_positive_prefix) and std.mem.endsWith(u8, pattern, alternate_positive_space_first_suffix)) {
        const slot = pattern[alternate_positive_prefix.len];
        if (pattern.len == alternate_positive_prefix.len + 1 + alternate_positive_space_first_suffix.len and slot >= '1' and slot <= '9') return .{ .slot = slot - '0' };
    }
    const negative_prefix = "^(?!(?: {0,3}\\";
    const negative_suffix = "-*[\\t ]*|[\\t ]*\\.{3})$)";
    if (parseFenceLineSlot(pattern, negative_prefix, negative_suffix)) |slot| return .{ .slot = slot, .negate = true };
    const alternate_negative_prefix = "^(?! {,3}\\";
    const alternate_negative_suffix = "-*[ \\t]*$|[ \\t]*\\.{3}$)";
    if (parseFenceLineSlot(pattern, alternate_negative_prefix, alternate_negative_suffix)) |slot| return .{ .slot = slot, .negate = true };
    return null;
}

pub fn matchFenceLine(marker: []const u8, negate: bool, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    const matched = matchesFenceLine(marker, line);
    return if (matched != negate) line.len else null;
}

pub fn parseGNegativeSuffixSlot(pattern: []const u8) ?u8 {
    const prefix = "\\G((?<!\\";
    const suffix = "[^-\\w]))|}|$";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    const slot_index = prefix.len;
    if (pattern.len != prefix.len + 1 + suffix.len or pattern[slot_index] < '1' or pattern[slot_index] > '9') return null;
    return pattern[slot_index] - '0';
}

pub fn matchGNegativeSuffix(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index < line.len and line[index] == '}') return index + 1;
    if (index == line.len) return index;
    return if (hasMarkerAndNonNameBefore(marker, line[0..index])) null else index;
}

fn hasMarkerAndNonNameBefore(marker: []const u8, line: []const u8) bool {
    if (line.len == 0) return false;
    const last = line[line.len - 1];
    if (last == '-' or std.ascii.isAlphanumeric(last) or last == '_') return false;
    const before = line[0 .. line.len - 1];
    return marker.len == 0 or std.mem.endsWith(u8, before, marker);
}

fn matchesFenceLine(marker: []const u8, line: []const u8) bool {
    var cursor: usize = 0;
    var spaces: usize = 0;
    while (spaces < 3 and cursor < line.len and line[cursor] == ' ') {
        spaces += 1;
        cursor += 1;
    }
    if (std.mem.startsWith(u8, line[cursor..], marker)) {
        cursor += marker.len;
        while (cursor < line.len and line[cursor] == '-') : (cursor += 1) {}
        return horizontalBlank(line[cursor..]);
    }
    cursor = 0;
    while (cursor < line.len and (line[cursor] == '\t' or line[cursor] == ' ')) : (cursor += 1) {}
    if (!std.mem.startsWith(u8, line[cursor..], "...")) return false;
    return horizontalBlank(line[cursor + 3 ..]);
}

fn horizontalBlank(line: []const u8) bool {
    for (line) |byte| if (byte != '\t' and byte != ' ') return false;
    return true;
}

fn parseFenceLineSlot(pattern: []const u8, prefix: []const u8, suffix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    const slot = pattern[prefix.len];
    if (pattern.len != prefix.len + 1 + suffix.len or slot < '1' or slot > '9') return null;
    return slot - '0';
}

test "dynamic anchor parses fence line spellings" {
    try std.testing.expectEqual(FenceLine{ .slot = 1 }, parseFenceLine("^(?: {0,3}\\1-*[\\t ]*|[\\t ]*\\.{3})$").?);
    try std.testing.expectEqual(FenceLine{ .slot = 1 }, parseFenceLine("^ {,3}\\1-*[\\t ]*$|^[\\t ]*\\.{3}$").?);
    try std.testing.expectEqual(FenceLine{ .slot = 1 }, parseFenceLine("^ {,3}\\1-*[ \\t]*$|^[ \\t]*\\.{3}$").?);
    try std.testing.expectEqual(FenceLine{ .slot = 2, .negate = true }, parseFenceLine("^(?!(?: {0,3}\\2-*[\\t ]*|[\\t ]*\\.{3})$)").?);
    try std.testing.expectEqual(FenceLine{ .slot = 2, .negate = true }, parseFenceLine("^(?! {,3}\\2-*[ \\t]*$|[ \\t]*\\.{3}$)").?);
}

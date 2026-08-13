const std = @import("std");

pub const GuardedWhitespaceBackref = struct {
    guard_slot: u8,
    slot: u8,
};

pub const AnchoredBackrefTerminator = struct {
    slot: u8,
    allow_tab_prefix: bool = false,
};

pub fn anchoredBackrefTerminator(pattern: []const u8) ?AnchoredBackrefTerminator {
    const body = stripOuterNonCapturing(pattern);
    var index: usize = 0;
    var allow_tab_prefix = false;

    if (std.mem.startsWith(u8, body, "(?:^\\t*)")) {
        index = "(?:^\\t*)".len;
        allow_tab_prefix = true;
    } else if (std.mem.startsWith(u8, body, "^\\t*")) {
        index = "^\\t*".len;
        allow_tab_prefix = true;
    } else if (std.mem.startsWith(u8, body, "(?:^)")) {
        index = "(?:^)".len;
    } else if (std.mem.startsWith(u8, body, "^")) {
        index = 1;
    } else return null;

    const slot = wrappedBackrefSlot(body[index..]) orelse return null;
    index += slot.len;
    if (!isTerminatorLookahead(body[index..])) return null;
    return .{ .slot = slot.slot, .allow_tab_prefix = allow_tab_prefix };
}

pub fn whitespaceMarkerLookaheadSlot(pattern: []const u8) ?u8 {
    const prefix = "(?=^\\s*\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or pattern.len != prefix.len + 4) return null;
    const slot = pattern[prefix.len];
    return if (slot >= '1' and slot <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\b)")) slot - '0' else null;
}

pub fn semicolonMarkerLookaheadSlot(pattern: []const u8) ?u8 {
    const prefix = "(?i)(?:^|(?<=;))(?=\\s*\\b\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or pattern.len != prefix.len + 4) return null;
    const slot = pattern[prefix.len];
    return if (slot >= '1' and slot <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\b)")) slot - '0' else null;
}

pub fn groupedWhitespaceIdentifierBoundarySlot(pattern: []const u8) ?u8 {
    const prefix = "^\\s*(\\";
    const suffix = ")(?![0-9A-Z_a-z\\x7F-\\x{10FFFF}])";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    const slot_index = prefix.len;
    if (pattern.len != prefix.len + 1 + suffix.len or pattern[slot_index] < '1' or pattern[slot_index] > '9') return null;
    return pattern[slot_index] - '0';
}

pub fn optionalGuardedWhitespaceBackref(pattern: []const u8) ?GuardedWhitespaceBackref {
    const prefix = "^((?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    const guard_index = prefix.len;
    if (pattern.len <= guard_index or pattern[guard_index] < '1' or pattern[guard_index] > '9') return null;
    const mid = ")\\s+)?((\\";
    if (!std.mem.startsWith(u8, pattern[guard_index + 1 ..], mid)) return null;
    const slot_index = guard_index + 1 + mid.len;
    if (pattern.len != slot_index + 4 or pattern[slot_index] < '1' or pattern[slot_index] > '9') return null;
    if (!std.mem.eql(u8, pattern[slot_index + 1 ..], "))$")) return null;
    return .{ .guard_slot = pattern[guard_index] - '0', .slot = pattern[slot_index] - '0' };
}

pub fn negativeSlot(pattern: []const u8) ?u8 {
    if (pattern.len != 12 or !std.mem.startsWith(u8, pattern, "^(?!\\")) return null;
    return if (pattern[5] >= '1' and pattern[5] <= '9' and std.mem.eql(u8, pattern[6..], "|\\s*$)")) pattern[5] - '0' else null;
}

pub fn negativeSpaceTextSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], " +\\S|\\s*$)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeIndentOrBlankSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "[\\t ]|[\\t ]*$)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeBlankOrIndentTextSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\s*$|\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s{4,}\\S)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeMarkerTextSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "(?=\\S))")) pattern[prefix.len] - '0' else null;
}

pub fn negativeMarkerSpaceTextSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s+)(?=\\s*\\S+)")) pattern[prefix.len] - '0' else null;
}

pub fn markerSpaceOrEmptyLookaheadSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?=\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s+|$\\n*)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeMarkerSpaceOrEmptySlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (std.mem.startsWith(u8, pattern, prefix)) {
        return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s+|$\\n*)")) pattern[prefix.len] - '0' else null;
    }
    const multi_prefix = "(?m:(?<=\\n)(?!\\";
    if (!std.mem.startsWith(u8, pattern, multi_prefix)) return null;
    return if (pattern.len > multi_prefix.len and pattern[multi_prefix.len] >= '1' and pattern[multi_prefix.len] <= '9' and std.mem.eql(u8, pattern[multi_prefix.len + 1 ..], "\\s+|$\\n*))")) pattern[multi_prefix.len] - '0' else null;
}

pub fn negativeMarkerSpaceOrNewlineSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s+|\\n)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeCommentMarkerTwoSpaceOrBlankSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\s*#\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s{2,}|\\s*#\\s*$)")) pattern[prefix.len] - '0' else null;
}

pub fn markerWhitespaceOrBlankSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?:\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "(?=\\s)|\\s*$)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeMarkerHorizontalSpaceOrEmptySlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "[\\t ]|$)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeMarkerWhitespaceOrBlankSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "\\s|\\s*$)")) pattern[prefix.len] - '0' else null;
}

pub fn negativeFourSpaceSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!(?:\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "[ ]{4}|\\s*$))")) pattern[prefix.len] - '0' else null;
}

pub fn negativeBlockQuoteFourSpaceSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!(?:[ \\t]*>)+(?:[ ]\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len > prefix.len and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], "[ ]{4}|\\s*$))")) pattern[prefix.len] - '0' else null;
}

pub fn negativeEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    return if (std.mem.startsWith(u8, line, marker)) null else index;
}

pub fn negativeSpaceTextEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    var cursor = marker.len;
    var spaces: usize = 0;
    while (cursor < line.len and line[cursor] == ' ') : (cursor += 1) spaces += 1;
    return if (spaces != 0 and cursor < line.len and !std.ascii.isWhitespace(line[cursor])) null else index;
}

pub fn negativeIndentOrBlankEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isHorizontalBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    return if (marker.len < line.len and (line[marker.len] == ' ' or line[marker.len] == '\t')) null else index;
}

pub fn negativeBlankOrIndentTextEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    var cursor = marker.len;
    var spaces: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) spaces += 1;
    return if (spaces >= 4 and cursor < line.len and !std.ascii.isWhitespace(line[cursor])) null else index;
}

pub fn negativeMarkerTextEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    const cursor = marker.len;
    return if (cursor < line.len and !std.ascii.isWhitespace(line[cursor])) null else index;
}

pub fn negativeMarkerSpaceTextEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    const cursor = marker.len;
    return if (cursor < line.len and std.ascii.isWhitespace(line[cursor])) null else index;
}

pub fn markerSpaceOrEmptyLookaheadEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    return if (line.len == 0 or startsMarkerWhitespace(marker, line)) index else null;
}

pub fn negativeMarkerSpaceOrEmptyEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or line.len == 0) return null;
    return if (startsMarkerWhitespace(marker, line)) null else index;
}

pub fn negativeMarkerSpaceOrNewlineEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    return if (startsMarkerWhitespace(marker, line)) null else index;
}

pub fn negativeCommentMarkerTwoSpaceOrBlankEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor >= line.len or line[cursor] != '#') return index;
    cursor += 1;
    if (isBlank(line[cursor..])) return null;
    if (!std.mem.startsWith(u8, line[cursor..], marker)) return index;
    cursor += marker.len;
    var spaces: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) spaces += 1;
    return if (spaces >= 2) null else index;
}

pub fn markerWhitespaceOrBlankEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    if (isBlank(line)) return line.len;
    if (!std.mem.startsWith(u8, line, marker)) return null;
    const cursor = marker.len;
    return if (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor else null;
}

pub fn negativeMarkerHorizontalSpaceOrEmptyEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or line.len == 0) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    const cursor = marker.len;
    return if (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) null else index;
}

pub fn negativeMarkerWhitespaceOrBlankEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    const cursor = marker.len;
    return if (cursor < line.len and std.ascii.isWhitespace(line[cursor])) null else index;
}

pub fn negativeBlankCommentOrMarkerSpaceEnd(marker: []const u8, comment: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor == line.len or std.mem.startsWith(u8, line[cursor..], comment)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    return if (marker.len < line.len and std.ascii.isWhitespace(line[marker.len])) null else index;
}

pub fn negativeFourSpaceEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    return if (line.len >= marker.len + 4 and std.mem.eql(u8, line[marker.len..][0..4], "    ")) null else index;
}

pub fn negativeBlockQuoteFourSpaceEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0 or isBlank(line)) return null;
    var cursor: usize = 0;
    var quote_count: usize = 0;
    while (true) {
        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
        if (cursor >= line.len or line[cursor] != '>') break;
        cursor += 1;
        quote_count += 1;
    }
    if (quote_count == 0) return index;
    if (cursor < line.len and line[cursor] == ' ') cursor += 1;
    if (!std.mem.startsWith(u8, line[cursor..], marker)) return index;
    cursor += marker.len;
    return if (line.len >= cursor + 4 and std.mem.eql(u8, line[cursor..][0..4], "    ")) null else index;
}

pub fn whitespaceMarkerEnd(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (!std.mem.startsWith(u8, line[cursor..], marker)) return null;
    cursor += marker.len;
    return if (wordBoundary(line, cursor)) index else null;
}

pub fn semicolonMarkerEnd(marker: []const u8, case_insensitive: bool, line: []const u8, index: usize) ?usize {
    if (index != 0 and line[index - 1] != ';') return null;
    var cursor = index;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (!wordBoundary(line, cursor)) return null;
    if (!startsWith(line[cursor..], marker, case_insensitive)) return null;
    cursor += marker.len;
    return if (wordBoundary(line, cursor)) index else null;
}

pub fn guardedWhitespaceMarkerEnd(guard: []const u8, marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    var cursor: usize = 0;
    if (guard.len == 0 or !std.mem.startsWith(u8, line, guard)) {
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    }
    if (!std.mem.startsWith(u8, line[cursor..], marker)) return null;
    cursor += marker.len;
    return if (cursor == line.len) cursor else null;
}

fn isBlank(line: []const u8) bool {
    for (line) |byte| if (!std.ascii.isWhitespace(byte)) return false;
    return true;
}

fn stripOuterNonCapturing(pattern: []const u8) []const u8 {
    if (std.mem.startsWith(u8, pattern, "(?:") and pattern.len > 4 and pattern[pattern.len - 1] == ')') {
        return pattern[3 .. pattern.len - 1];
    }
    return pattern;
}

fn wrappedBackrefSlot(pattern: []const u8) ?struct { slot: u8, len: usize } {
    if (pattern.len >= 2 and pattern[0] == '\\' and pattern[1] >= '1' and pattern[1] <= '9') {
        return .{ .slot = pattern[1] - '0', .len = 2 };
    }
    if (pattern.len >= 6 and std.mem.startsWith(u8, pattern, "(?:\\") and pattern[4] >= '1' and pattern[4] <= '9' and pattern[5] == ')') {
        return .{ .slot = pattern[4] - '0', .len = 6 };
    }
    return null;
}

fn isTerminatorLookahead(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "(?=[\\&;\\s]|$)") or
        std.mem.eql(u8, pattern, "(?=\\s|;|&|$)");
}

fn startsMarkerWhitespace(marker: []const u8, line: []const u8) bool {
    return std.mem.startsWith(u8, line, marker) and marker.len < line.len and std.ascii.isWhitespace(line[marker.len]);
}

fn isHorizontalBlank(line: []const u8) bool {
    for (line) |byte| if (byte != ' ' and byte != '\t') return false;
    return true;
}

fn startsWith(line: []const u8, marker: []const u8, case_insensitive: bool) bool {
    if (!case_insensitive) return std.mem.startsWith(u8, line, marker);
    return line.len >= marker.len and std.ascii.eqlIgnoreCase(line[0..marker.len], marker);
}

fn wordBoundary(line: []const u8, index: usize) bool {
    const before = index != 0 and isWordByte(line[index - 1]);
    return before != (index < line.len and isWordByte(line[index]));
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

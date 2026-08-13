const std = @import("std");
const regex_unicode = @import("../../regex/unicode.zig");

pub const Continuation = struct {
    slot: u8,
    keyword: []const u8 = "",
};

pub fn parseContinuation(pattern: []const u8) ?Continuation {
    var rest = pattern;
    var keyword_name: []const u8 = "";
    if (keywordPrefix(rest)) |keyword| {
        keyword_name = keyword.name;
        rest = rest[keyword.consumed..];
    }
    const semi_alt = "(?=[;}])|";
    if (!std.mem.startsWith(u8, rest, semi_alt)) return null;
    rest = rest[semi_alt.len..];
    return .{ .slot = continuationSlot(rest) orelse return null, .keyword = keyword_name };
}

pub fn parseCommentGuard(pattern: []const u8) ?u8 {
    const prefix = "(?=^(?!\\";
    const suffix = "--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]])))";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    const slot_index = prefix.len;
    if (pattern.len != prefix.len + 1 + suffix.len or pattern[slot_index] < '1' or pattern[slot_index] > '9') return null;
    return pattern[slot_index] - '0';
}

pub fn matchContinuation(marker: []const u8, keyword: []const u8, line: []const u8, index: usize) ?usize {
    if (index < line.len and (line[index] == ';' or line[index] == '}')) return index;
    if (keyword.len != 0 and keywordAt(line, index, keyword)) return index;
    if (index != 0) return null;
    return if (lineContinues(marker, line)) null else index;
}

pub fn matchCommentGuard(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (index != 0) return null;
    if (!std.mem.startsWith(u8, line, marker)) return index;
    var cursor = marker.len;
    return if (lineCommentContinues(line, &cursor)) null else index;
}

fn keywordPrefix(pattern: []const u8) ?struct { name: []const u8, consumed: usize } {
    const before_word = "(?=(?<!')\\b";
    const after_word = "\\b(?!'))|";
    if (std.mem.startsWith(u8, pattern, before_word)) {
        if (std.mem.indexOf(u8, pattern[before_word.len..], after_word)) |end| {
            const name = pattern[before_word.len..][0..end];
            return if (isAsciiWord(name)) .{ .name = name, .consumed = before_word.len + end + after_word.len } else null;
        }
    }
    const before_deriving = "(?=\\b(?<!'')";
    if (std.mem.startsWith(u8, pattern, before_deriving)) {
        if (std.mem.indexOf(u8, pattern[before_deriving.len..], after_word)) |end| {
            const name = pattern[before_deriving.len..][0..end];
            return if (isAsciiWord(name)) .{ .name = name, .consumed = before_deriving.len + end + after_word.len } else null;
        }
    }
    return null;
}

fn continuationSlot(pattern: []const u8) ?u8 {
    const prefix = "^(?!\\";
    const suffix = "\\s+\\S|\\s*(?:$|\\{-[^@]|--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]]).*$))";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    const slot_index = prefix.len;
    if (pattern.len != prefix.len + 1 + suffix.len or pattern[slot_index] < '1' or pattern[slot_index] > '9') return null;
    return pattern[slot_index] - '0';
}

fn keywordAt(line: []const u8, index: usize, keyword: []const u8) bool {
    if (index != 0 and (isWordByte(line[index - 1]) or line[index - 1] == '\'')) return false;
    if (!std.mem.startsWith(u8, line[index..], keyword)) return false;
    const end = index + keyword.len;
    return end == line.len or (!isWordByte(line[end]) and line[end] != '\'');
}

fn lineContinues(marker: []const u8, line: []const u8) bool {
    if (std.mem.startsWith(u8, line, marker)) {
        var cursor = marker.len;
        if (cursor < line.len and std.ascii.isWhitespace(line[cursor])) {
            while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
            if (cursor < line.len) return true;
        }
    }
    var cursor: usize = 0;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor == line.len) return true;
    if (std.mem.startsWith(u8, line[cursor..], "{-") and (cursor + 2 == line.len or line[cursor + 2] != '@')) return true;
    return lineCommentContinues(line, &cursor);
}

fn lineCommentContinues(line: []const u8, cursor: *usize) bool {
    if (!std.mem.startsWith(u8, line[cursor.*..], "--")) return false;
    cursor.* += 2;
    while (cursor.* < line.len and line[cursor.*] == '-') : (cursor.* += 1) {}
    return !operatorByte(line, cursor.*);
}

fn operatorByte(line: []const u8, index: usize) bool {
    if (index >= line.len) return false;
    const byte = line[index];
    if (byte < 0x80) return isAsciiOperator(byte);
    if (regex_unicode.scalarRangesForProperty("Sm")) |ranges| if (regex_unicode.matchScalarRanges(line, index, ranges) == true) return true;
    if (regex_unicode.scalarRangesForProperty("So")) |ranges| if (regex_unicode.matchScalarRanges(line, index, ranges) == true) return true;
    return false;
}

fn isAsciiOperator(byte: u8) bool {
    if (std.mem.indexOfScalar(u8, "]\"'(),;\\[_`{}", byte) != null) return false;
    return std.ascii.isPunctuation(byte);
}

fn isAsciiWord(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

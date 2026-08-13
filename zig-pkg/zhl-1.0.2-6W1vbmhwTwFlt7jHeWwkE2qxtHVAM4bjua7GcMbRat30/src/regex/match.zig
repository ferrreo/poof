const std = @import("std");
const regex_escape = @import("escape.zig");

pub const CaptureMatch = struct {
    start: usize = 0,
    end: usize = 0,
    set: bool = false,
};

pub const Match = struct {
    end: usize,
    capture1_start: usize = 0,
    capture1_end: usize = 0,
    capture1: bool = false,
    capture2_start: usize = 0,
    capture2_end: usize = 0,
    capture2: bool = false,
    capture3_start: usize = 0,
    capture3_end: usize = 0,
    capture3: bool = false,
    capture4_start: usize = 0,
    capture4_end: usize = 0,
    capture4: bool = false,
    capture5_start: usize = 0,
    capture5_end: usize = 0,
    capture5: bool = false,
    capture6_start: usize = 0,
    capture6_end: usize = 0,
    capture6: bool = false,
    capture7_start: usize = 0,
    capture7_end: usize = 0,
    capture7: bool = false,
};

pub fn generalNewline(text: []const u8, pos: usize) ?usize {
    return lineBreakAt(text, pos);
}

pub fn lineBreakAt(text: []const u8, pos: usize) ?usize {
    if (pos >= text.len) return null;
    if (text[pos] == '\r' and pos + 1 < text.len and text[pos + 1] == '\n') return pos + 2;
    if (regex_escape.isLineBreak(text[pos])) return pos + 1;
    if (std.mem.startsWith(u8, text[pos..], "\xe2\x80\xa8") or std.mem.startsWith(u8, text[pos..], "\xe2\x80\xa9")) return pos + 3;
    return null;
}

pub fn dotExcludedAt(text: []const u8, pos: usize) bool {
    return pos < text.len and text[pos] == '\n';
}

pub fn textSegment(text: []const u8, pos: usize) ?usize {
    if (pos >= text.len) return null;
    if (text[pos] == '\r' and pos + 1 < text.len and text[pos + 1] == '\n') return pos + 2;
    const first = scalarAt(text, pos) orelse return pos + 1;
    var end = scalarEnd(text, pos);
    var saw_pictographic = isExtendedPictographic(first.value);
    while (isPrepend(first.value)) {
        const next = scalarAt(text, end) orelse return end;
        end = next.end;
        saw_pictographic = saw_pictographic or isExtendedPictographic(next.value);
        if (!isPrepend(next.value)) break;
    }
    if (isRegionalIndicator(first.value)) {
        if (scalarAt(text, end)) |next| {
            if (isRegionalIndicator(next.value)) return next.end;
        }
    }
    while (scalarAt(text, end)) |next| {
        const previous = scalarBefore(text, end) orelse return end;
        if (hangulJoins(previous.value, next.value) or isExtendingSegmentScalar(next.value)) {
            end = next.end;
            saw_pictographic = saw_pictographic or isExtendedPictographic(next.value);
        } else if (next.value == 0x200d) {
            const joined = scalarAt(text, next.end) orelse return next.end;
            if (!saw_pictographic or !isExtendedPictographic(joined.value)) return next.end;
            end = joined.end;
            saw_pictographic = true;
        } else {
            break;
        }
    }
    return end;
}

pub fn textSegmentBoundary(text: []const u8, pos: usize) bool {
    if (pos == 0 or pos == text.len) return true;
    if (pos > text.len) return false;
    var scan: usize = 0;
    while (scan < pos) {
        const end = textSegment(text, scan) orelse return true;
        if (end > pos) return false;
        scan = @max(end, scan + 1);
    }
    return true;
}

pub fn wordBoundary(text: []const u8, pos: usize) bool {
    const prev_word = wordBefore(text, pos);
    const next_word = wordAt(text, pos) != null;
    return prev_word != next_word;
}

pub fn wordStart(text: []const u8, pos: usize) bool {
    return wordAt(text, pos) != null and !wordBefore(text, pos);
}

pub fn wordEnd(text: []const u8, pos: usize) bool {
    return wordBefore(text, pos) and wordAt(text, pos) == null;
}

pub fn wordByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '_';
}

pub fn wordAt(text: []const u8, pos: usize) ?usize {
    if (pos >= text.len) return null;
    if (wordByte(text[pos])) return pos + 1;
    if (text[pos] < 0x80) return null;
    return scalarEndIfStart(text, pos);
}

fn wordBefore(text: []const u8, pos: usize) bool {
    if (pos == 0 or pos > text.len) return false;
    if (text[pos - 1] < 0x80) return wordByte(text[pos - 1]);
    var start = pos - 1;
    while (start > 0 and start + 4 > pos and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
    return text[start] >= 0x80 and scalarEndIfStart(text, start) == pos;
}

pub fn spaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c or
        byte == '\r' or byte == '\n' or byte == 0x85;
}

pub fn asciiSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c or
        byte == '\r' or byte == '\n';
}

pub fn spaceAt(text: []const u8, pos: usize) ?usize {
    if (pos >= text.len) return null;
    if (spaceByte(text[pos])) return pos + 1;
    if (std.mem.startsWith(u8, text[pos..], "\xe2\x80\xa8") or std.mem.startsWith(u8, text[pos..], "\xe2\x80\xa9")) return pos + 3;
    return null;
}

pub fn asciiSpaceAt(text: []const u8, pos: usize) ?usize {
    return if (pos < text.len and asciiSpaceByte(text[pos])) pos + 1 else null;
}

pub fn scalarEnd(text: []const u8, pos: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return pos + 1;
    return if (pos + len <= text.len) pos + len else pos + 1;
}

pub fn scalarEndIfStart(text: []const u8, pos: usize) ?usize {
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + len > text.len) return null;
    _ = std.unicode.utf8Decode(text[pos..][0..len]) catch return null;
    return pos + len;
}

const Scalar = struct { value: u21, end: usize };

fn scalarAt(text: []const u8, pos: usize) ?Scalar {
    if (pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + len > text.len) return null;
    return .{ .value = std.unicode.utf8Decode(text[pos..][0..len]) catch return null, .end = pos + len };
}

fn scalarBefore(text: []const u8, pos: usize) ?Scalar {
    if (pos == 0 or pos > text.len) return null;
    var start = pos - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
    const scalar = scalarAt(text, start) orelse return null;
    return if (scalar.end == pos) scalar else null;
}

fn isExtendingSegmentScalar(value: u21) bool {
    return isCombiningMark(value) or isSpacingMark(value) or isVariationSelector(value) or
        (value >= 0x1f3fb and value <= 0x1f3ff) or (value >= 0xe0020 and value <= 0xe007f);
}

fn isCombiningMark(value: u21) bool {
    return (value >= 0x0300 and value <= 0x036f) or
        (value >= 0x0900 and value <= 0x0902) or (value >= 0x0941 and value <= 0x0948) or value == 0x094d or (value >= 0x0951 and value <= 0x0957) or (value >= 0x0962 and value <= 0x0963) or
        (value >= 0x0981 and value <= 0x0981) or (value >= 0x09c1 and value <= 0x09c4) or value == 0x09cd or (value >= 0x09e2 and value <= 0x09e3) or
        (value >= 0x0d00 and value <= 0x0d01) or (value >= 0x0d41 and value <= 0x0d44) or value == 0x0d4d or (value >= 0x0d62 and value <= 0x0d63) or
        value == 0x0e31 or (value >= 0x0e34 and value <= 0x0e3a) or (value >= 0x0e47 and value <= 0x0e4e) or
        (value >= 0x1ab0 and value <= 0x1aff) or
        (value >= 0x1dc0 and value <= 0x1dff) or
        (value >= 0x20d0 and value <= 0x20ff) or
        (value >= 0xfe20 and value <= 0xfe2f);
}

fn isVariationSelector(value: u21) bool {
    return (value >= 0xfe00 and value <= 0xfe0f) or (value >= 0xe0100 and value <= 0xe01ef);
}

fn isSpacingMark(value: u21) bool {
    return inRanges(value, &.{
        .{ 0x0903, 0x0903 }, .{ 0x093b, 0x093b }, .{ 0x093e, 0x0940 }, .{ 0x0949, 0x094c },
        .{ 0x0982, 0x0983 }, .{ 0x09be, 0x09c0 }, .{ 0x09c7, 0x09c8 }, .{ 0x09cb, 0x09cc },
        .{ 0x0bbe, 0x0bbf }, .{ 0x0bc1, 0x0bc2 }, .{ 0x0bc6, 0x0bc8 }, .{ 0x0bca, 0x0bcc },
        .{ 0x0c01, 0x0c03 }, .{ 0x0c41, 0x0c44 }, .{ 0x0d02, 0x0d03 }, .{ 0x0d3e, 0x0d40 },
        .{ 0x0d46, 0x0d48 }, .{ 0x0d4a, 0x0d4c }, .{ 0x0f3e, 0x0f3f }, .{ 0x102b, 0x102c },
        .{ 0x1031, 0x1031 }, .{ 0x1038, 0x1038 }, .{ 0x17b6, 0x17b6 }, .{ 0x17be, 0x17c5 },
    });
}

fn isPrepend(value: u21) bool {
    return inRanges(value, &.{
        .{ 0x0600, 0x0605 }, .{ 0x06dd, 0x06dd },   .{ 0x070f, 0x070f },   .{ 0x0890, 0x0891 },
        .{ 0x08e2, 0x08e2 }, .{ 0x110bd, 0x110bd }, .{ 0x110cd, 0x110cd },
    });
}

fn isRegionalIndicator(value: u21) bool {
    return value >= 0x1f1e6 and value <= 0x1f1ff;
}

fn isExtendedPictographic(value: u21) bool {
    return inRanges(value, &.{
        .{ 0x00a9, 0x00a9 }, .{ 0x00ae, 0x00ae }, .{ 0x203c, 0x2049 }, .{ 0x2122, 0x2122 },
        .{ 0x2139, 0x2139 }, .{ 0x2194, 0x21aa }, .{ 0x231a, 0x231b }, .{ 0x2328, 0x2328 },
        .{ 0x23cf, 0x23cf }, .{ 0x23e9, 0x23f3 }, .{ 0x23f8, 0x23fa }, .{ 0x24c2, 0x24c2 },
        .{ 0x25aa, 0x25ab }, .{ 0x25b6, 0x25b6 }, .{ 0x25c0, 0x25c0 }, .{ 0x25fb, 0x25fe },
        .{ 0x2600, 0x27bf }, .{ 0x2934, 0x2935 }, .{ 0x2b05, 0x2b55 }, .{ 0x3030, 0x3030 },
        .{ 0x303d, 0x303d }, .{ 0x3297, 0x3297 }, .{ 0x3299, 0x3299 }, .{ 0x1f000, 0x1faff },
    });
}

fn hangulJoins(left: u21, right: u21) bool {
    return switch (hangulClass(left)) {
        .l => hangulClass(right) == .l or hangulClass(right) == .v or hangulClass(right) == .lv or hangulClass(right) == .lvt,
        .v, .lv => hangulClass(right) == .v or hangulClass(right) == .t,
        .t, .lvt => hangulClass(right) == .t,
        .other => false,
    };
}

const HangulClass = enum { other, l, v, t, lv, lvt };

fn hangulClass(value: u21) HangulClass {
    if (inRanges(value, &.{ .{ 0x1100, 0x115f }, .{ 0xa960, 0xa97c } })) return .l;
    if (inRanges(value, &.{ .{ 0x1160, 0x11a7 }, .{ 0xd7b0, 0xd7c6 } })) return .v;
    if (inRanges(value, &.{ .{ 0x11a8, 0x11ff }, .{ 0xd7cb, 0xd7fb } })) return .t;
    if (value >= 0xac00 and value <= 0xd7a3) return if ((value - 0xac00) % 28 == 0) .lv else .lvt;
    return .other;
}

fn inRanges(value: u21, ranges: []const struct { u21, u21 }) bool {
    for (ranges) |range| if (value >= range[0] and value <= range[1]) return true;
    return false;
}

test "regex match treats valid utf8 scalars as word characters" {
    const scalar = "\xc3\xa9";
    try std.testing.expectEqual(@as(?usize, 2), wordAt(scalar, 0));
    try std.testing.expect(wordBoundary(scalar, 0));
    try std.testing.expect(!wordBoundary(scalar, 1));
    try std.testing.expect(wordBoundary(scalar, 2));
    try std.testing.expect(wordStart(scalar, 0));
    try std.testing.expect(wordEnd(scalar, 2));
}

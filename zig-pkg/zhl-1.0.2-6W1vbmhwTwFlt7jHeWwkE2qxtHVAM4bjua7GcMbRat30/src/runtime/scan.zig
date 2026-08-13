const std = @import("std");
const ByteMask256 = @import("../ByteMask256.zig");

pub fn indexOfAnyByte(comptime needles: []const u8, haystack: []const u8, start: usize) usize {
    if (needles.len == 0) return haystack.len;
    if (start >= haystack.len) return haystack.len;
    if (needles.len == 1) return scanUntilByte(needles[0], haystack, start);

    const vec_len = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(vec_len, u8);

    var i = start;
    if (haystack.len - start >= vec_len * 2) {
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const chunk: Vec = haystack[i..][0..vec_len].*;
            var matches = chunk == @as(Vec, @splat(needles[0]));
            inline for (needles[1..]) |needle| {
                matches = matches | (chunk == @as(Vec, @splat(needle)));
            }
            if (@reduce(.Or, matches)) {
                inline for (0..vec_len) |lane| {
                    if (matches[lane]) return i + lane;
                }
            }
        }
    }
    while (i < haystack.len) : (i += 1) {
        inline for (needles) |needle| {
            if (haystack[i] == needle) return i;
        }
    }
    return haystack.len;
}

pub fn scanUntilByte(comptime byte: u8, haystack: []const u8, start: usize) usize {
    const vec_len = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(vec_len, u8);
    const splat: Vec = @splat(byte);

    var i = start;
    while (i + vec_len <= haystack.len) : (i += vec_len) {
        const chunk: Vec = haystack[i..][0..vec_len].*;
        const matches = chunk == splat;
        if (@reduce(.Or, matches)) {
            inline for (0..vec_len) |lane| {
                if (matches[lane]) return i + lane;
            }
        }
    }
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == byte) return i;
    }
    return haystack.len;
}

pub fn findNextInteresting(mask: ByteMask256, haystack: []const u8, start: usize) usize {
    var i = start;
    while (i < haystack.len) : (i += 1) {
        if (mask.contains(haystack[i])) return i;
    }
    return haystack.len;
}

pub fn scanAsciiWhitespace(haystack: []const u8, start: usize) usize {
    var i = start;
    while (i < haystack.len and (haystack[i] == ' ' or haystack[i] == '\t')) : (i += 1) {}
    return i;
}

pub fn scanAsciiIdentifier(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len or !isIdentStart(haystack[start])) return start;
    var i = start + 1;
    while (i < haystack.len and isIdentContinue(haystack[i])) : (i += 1) {}
    return i;
}

pub fn isIdentStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

pub fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or (byte >= '0' and byte <= '9');
}

pub fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn isHexDigit(byte: u8) bool {
    return isDigit(byte) or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F');
}

pub fn scanGenericNumber(haystack: []const u8, start: usize) usize {
    if (start >= haystack.len or !isDigit(haystack[start])) return start;

    if (start + 1 < haystack.len and haystack[start] == '0' and isAnyOf(haystack[start + 1], "xXbBoO")) {
        const marker = haystack[start + 1];
        var digits = scanNumberDigits(haystack, start + 2, marker);
        if (!digits.has_digit) return start + 1;
        var i = digits.end;
        if (i < haystack.len and haystack[i] == '.' and i + 1 < haystack.len and isNumberDigitForBase(haystack[i + 1], marker)) {
            digits = scanNumberDigits(haystack, i + 1, marker);
            i = digits.end;
        }
        i = scanNumberExponent(haystack, i, "pPeE") orelse i;
        return scanNumberSuffix(haystack, i);
    }

    var digits = scanNumberDigits(haystack, start, 'd');
    var i = digits.end;
    if (i < haystack.len and haystack[i] == '.' and i + 1 < haystack.len and haystack[i + 1] != '.' and isDigit(haystack[i + 1])) {
        digits = scanNumberDigits(haystack, i + 1, 'd');
        i = digits.end;
    }
    i = scanNumberExponent(haystack, i, "eE") orelse i;
    return scanNumberSuffix(haystack, i);
}

pub fn isAnyOf(byte: u8, comptime bytes: []const u8) bool {
    inline for (bytes) |candidate| {
        if (byte == candidate) return true;
    }
    return false;
}

const NumberDigits = struct {
    end: usize,
    has_digit: bool,
};

fn scanNumberDigits(haystack: []const u8, start: usize, marker: u8) NumberDigits {
    var i = start;
    var has_digit = false;
    while (i < haystack.len and (haystack[i] == '_' or isNumberDigitForBase(haystack[i], marker))) : (i += 1) {
        has_digit = has_digit or haystack[i] != '_';
    }
    return .{ .end = i, .has_digit = has_digit };
}

fn isNumberDigitForBase(byte: u8, marker: u8) bool {
    return switch (marker) {
        'x', 'X' => isHexDigit(byte),
        'b', 'B' => byte == '0' or byte == '1',
        'o', 'O' => byte >= '0' and byte <= '7',
        else => isDigit(byte),
    };
}

fn scanNumberExponent(haystack: []const u8, start: usize, comptime markers: []const u8) ?usize {
    if (start >= haystack.len or !isAnyOf(haystack[start], markers)) return null;
    var i = start + 1;
    if (i < haystack.len and isAnyOf(haystack[i], "+-")) i += 1;
    const digits = scanNumberDigits(haystack, i, 'd');
    return if (digits.has_digit) digits.end else null;
}

fn scanNumberSuffix(haystack: []const u8, start: usize) usize {
    if (start < haystack.len and isIdentStart(haystack[start])) return scanAsciiIdentifier(haystack, start);
    return start;
}

test "scanUntilByte finds SIMD target" {
    try std.testing.expectEqual(@as(usize, 5), scanUntilByte('x', "aaaaaxaaa", 0));
    try std.testing.expectEqual(@as(usize, 9), scanUntilByte('z', "aaaaaxaaa", 0));
}

test "indexOfAnyByte finds earliest SIMD target" {
    try std.testing.expectEqual(@as(usize, 2), indexOfAnyByte(&.{ 'x', 'y' }, "aayxx", 0));
    try std.testing.expectEqual(@as(usize, 3), indexOfAnyByte(&.{ 'x', 'y' }, "aayxx", 3));
    try std.testing.expectEqual(@as(usize, 5), indexOfAnyByte(&.{ 'x', 'y' }, "aaaaa", 0));
    try std.testing.expectEqual(@as(usize, 5), indexOfAnyByte(&.{ 'x', 'y' }, "aaaaa", 6));
    try std.testing.expectEqual(@as(usize, 40), indexOfAnyByte(&.{ '"', '\\' }, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"tail", 0));
}

test "scanAsciiIdentifier" {
    try std.testing.expectEqual(@as(usize, 6), scanAsciiIdentifier("hello1 +", 0));
    try std.testing.expectEqual(@as(usize, 0), scanAsciiIdentifier("1hello", 0));
    try std.testing.expectEqual(@as(usize, 64), scanAsciiIdentifier("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa+", 0));
}

test "scanAsciiWhitespace" {
    try std.testing.expectEqual(@as(usize, 5), scanAsciiWhitespace(" \t \t x", 0));
    try std.testing.expectEqual(@as(usize, 64), scanAsciiWhitespace("                                                                x", 0));
}

test "scanGenericNumber covers prefixes exponents suffixes and ranges" {
    try std.testing.expectEqual(@as(usize, 4), scanGenericNumber("0x2a ", 0));
    try std.testing.expectEqual(@as(usize, 6), scanGenericNumber("0b1010 ", 0));
    try std.testing.expectEqual(@as(usize, 5), scanGenericNumber("0o755 ", 0));
    try std.testing.expectEqual(@as(usize, 5), scanGenericNumber("1_000 ", 0));
    try std.testing.expectEqual(@as(usize, 7), scanGenericNumber("1.5e-10 ", 0));
    try std.testing.expectEqual(@as(usize, 5), scanGenericNumber("42u32 ", 0));
    try std.testing.expectEqual(@as(usize, 7), scanGenericNumber("0x1.fp3 ", 0));
    try std.testing.expectEqual(@as(usize, 1), scanGenericNumber("1..2", 0));
}

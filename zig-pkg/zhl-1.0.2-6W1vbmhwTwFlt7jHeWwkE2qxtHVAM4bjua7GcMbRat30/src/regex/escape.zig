const std = @import("std");

pub const HexEscape = struct { byte: u8, end: usize };
pub const max_codepoint_escape_bytes = 32;
pub const CodepointEscape = struct {
    bytes: [max_codepoint_escape_bytes]u8 = [_]u8{0} ** max_codepoint_escape_bytes,
    len: u8 = 0,
    end: usize = 0,
};

pub fn isMeta(value: u8) bool {
    return std.mem.indexOfScalar(u8, ".^$*+?[]()|\\", value) != null;
}

pub fn byte(value: u8) u8 {
    return switch (value) {
        'a' => 0x07,
        'b' => 0x08,
        'e' => 0x1b,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0b,
        else => value,
    };
}

pub fn parseHex(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 1 < end and pattern[index + 1] == '{') {
        var i = index + 2;
        var value: u16 = 0;
        if (i >= end or pattern[i] == '}') return null;
        while (i < end and pattern[i] != '}') : (i += 1) {
            const digit = hexValue(pattern[i]) orelse return null;
            value = value * 16 + digit;
            if (value > std.math.maxInt(u8)) return null;
        }
        if (i >= end or pattern[i] != '}') return null;
        return .{ .byte = @intCast(value), .end = i + 1 };
    }
    if (index + 2 >= end) return null;
    const hi = hexValue(pattern[index + 1]) orelse return null;
    const lo = hexValue(pattern[index + 2]) orelse return null;
    return .{ .byte = @intCast(hi * 16 + lo), .end = index + 3 };
}

pub fn parseOctal(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index >= end or pattern[index] != '0') return null;
    var i = index;
    var value: u16 = 0;
    var digits: usize = 0;
    while (i < end and digits < 3 and pattern[i] >= '0' and pattern[i] <= '7') : ({
        i += 1;
        digits += 1;
    }) {
        value = value * 8 + pattern[i] - '0';
    }
    if (value > std.math.maxInt(u8)) return null;
    return .{ .byte = @intCast(value), .end = i };
}

pub fn parseOctalCodepoint(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 2 >= end or pattern[index] != 'o' or pattern[index + 1] != '{') return null;
    var i = index + 2;
    var value: u16 = 0;
    var digits: usize = 0;
    while (i < end and pattern[i] != '}') : ({
        i += 1;
        digits += 1;
    }) {
        if (pattern[i] < '0' or pattern[i] > '7') return null;
        value = value * 8 + pattern[i] - '0';
        if (value > std.math.maxInt(u8)) return null;
    }
    if (digits == 0 or i >= end or pattern[i] != '}') return null;
    return .{ .byte = @intCast(value), .end = i + 1 };
}

pub fn parseUnicode4(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 4 >= end or pattern[index] != 'u') return null;
    var value: u16 = 0;
    for (pattern[index + 1 .. index + 5]) |digit| value = value * 16 + (hexValue(digit) orelse return null);
    if (value > std.math.maxInt(u8)) return null;
    return .{ .byte = @intCast(value), .end = index + 5 };
}

pub fn parseCodepointByte(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    return switch (if (index < end) pattern[index] else 0) {
        'o' => parseOctalCodepoint(pattern, index, end),
        'u' => parseUnicode4(pattern, index, end),
        else => null,
    };
}

pub fn parseByte(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    return switch (if (index < end) pattern[index] else 0) {
        'x' => parseHex(pattern, index, end),
        else => parseCodepointByte(pattern, index, end),
    };
}

pub fn parseEscapedByte(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (parseByte(pattern, index, end)) |parsed| return parsed;
    return switch (if (index < end) pattern[index] else 0) {
        'c' => parseControl(pattern, index, end),
        'C' => parseControlDash(pattern, index, end),
        'M' => parseMeta(pattern, index, end),
        else => null,
    };
}

pub fn parseCodepoint(pattern: []const u8, index: usize, end: usize) ?CodepointEscape {
    return switch (if (index < end) pattern[index] else 0) {
        'x' => parseHexCodepoint(pattern, index, end),
        'o' => parseOctalCodepointScalar(pattern, index, end),
        'u' => parseUnicode4Codepoint(pattern, index, end),
        else => null,
    };
}

pub fn matchCodepoint(parsed: ?CodepointEscape, text: []const u8, pos: usize, ignore_case: bool) ?usize {
    const codepoint = parsed orelse return null;
    return matchLiteralBytes(codepoint.bytes[0..codepoint.len], text, pos, ignore_case);
}

pub fn matchLiteralBytes(literal: []const u8, text: []const u8, pos: usize, ignore_case: bool) ?usize {
    var pi: usize = 0;
    var ti: usize = pos;
    while (pi < literal.len) {
        if (ti >= text.len) return null;
        if (literal[pi] < 0x80 and text[ti] < 0x80) {
            if (literal[pi] != text[ti] and (!ignore_case or asciiLower(literal[pi]) != asciiLower(text[ti]))) return null;
            pi += 1;
            ti += 1;
            continue;
        }
        const plen = std.unicode.utf8ByteSequenceLength(literal[pi]) catch return null;
        const tlen = std.unicode.utf8ByteSequenceLength(text[ti]) catch return null;
        if (pi + plen > literal.len or ti + tlen > text.len) return null;
        const ps = std.unicode.utf8Decode(literal[pi..][0..plen]) catch return null;
        const ts = std.unicode.utf8Decode(text[ti..][0..tlen]) catch return null;
        if (!scalarsEqual(ps, ts, ignore_case)) return null;
        pi += plen;
        ti += tlen;
    }
    return ti;
}

pub fn scalarsEqual(a: u21, b: u21, ignore_case: bool) bool {
    return a == b or (ignore_case and scalarFold(a) == scalarFold(b));
}

pub fn scalarFold(value: u21) u21 {
    if (value == 0x2126) return 0x03c9;
    if (value == 0x212a) return 'k';
    if (value == 0x212b) return 0x00e5;
    if (value == 0x1e9e) return 0x00df;
    if (value == 0x00b5) return 0x03bc;
    if (value == 0x017f) return 's';
    switch (value) {
        0x0182, 0x0187, 0x018b, 0x0191, 0x0198, 0x01a0, 0x01a2, 0x01a4,
        0x01a7, 0x01ac, 0x01af, 0x01b3, 0x01b5, 0x01b8, 0x01bc,
        => return value + 1,
        0x0181 => return 0x0253,
        0x0186 => return 0x0254,
        0x018a => return 0x0257,
        0x018e => return 0x01dd,
        0x018f => return 0x0259,
        0x0190 => return 0x025b,
        0x0193 => return 0x0260,
        0x0194 => return 0x0263,
        0x0196 => return 0x0269,
        0x0197 => return 0x0268,
        0x019c => return 0x026f,
        0x019d => return 0x0272,
        0x019f => return 0x0275,
        0x01a9 => return 0x0283,
        0x01ae => return 0x0288,
        0x01b1 => return 0x028a,
        0x01b2 => return 0x028b,
        0x01b7 => return 0x0292,
        else => {},
    }
    if (value == 0x0184 or value == 0x023b or value == 0x0241) return value + 1;
    if (value == 0x0189) return 0x0256;
    if (value == 0x01a6) return 0x0280;
    if (value >= 'A' and value <= 'Z') return value + 32;
    if (value >= 0x00c0 and value <= 0x00d6) return value + 32;
    if (value >= 0x00d8 and value <= 0x00de) return value + 32;
    if (value >= 0x0100 and value <= 0x012e and value % 2 == 0) return value + 1;
    if (value >= 0x0132 and value <= 0x0136 and value % 2 == 0) return value + 1;
    if (value >= 0x0139 and value <= 0x0148 and value % 2 == 1) return value + 1;
    if (value >= 0x014a and value <= 0x0176 and value % 2 == 0) return value + 1;
    if (value == 0x0178) return 0x00ff;
    if (value >= 0x0179 and value <= 0x017d and value % 2 == 1) return value + 1;
    if (value >= 0x01c4 and value <= 0x01ca and value % 3 == 2) return value + 2;
    if (value >= 0x01c5 and value <= 0x01cb and value % 3 == 0) return value + 1;
    if (value >= 0x01cd and value <= 0x01dc and value % 2 == 1) return value + 1;
    if (value >= 0x01de and value <= 0x01ee and value % 2 == 0) return value + 1;
    if (value >= 0x01f1 and value <= 0x01f3 and value % 3 == 2) return value + 2;
    if (value == 0x01f2) return 0x01f3;
    if (value == 0x01f4) return 0x01f5;
    if (value == 0x01f6) return 0x0195;
    if (value == 0x01f7) return 0x01bf;
    if (value >= 0x01f8 and value <= 0x021e and value % 2 == 0) return value + 1;
    if (value >= 0x0222 and value <= 0x0232 and value % 2 == 0) return value + 1;
    switch (value) {
        0x023a => return 0x2c65,
        0x023d => return 0x019a,
        0x023e => return 0x2c66,
        0x0243 => return 0x0180,
        0x0244 => return 0x0289,
        0x0245 => return 0x028c,
        else => {},
    }
    if (value >= 0x0246 and value <= 0x024e and value % 2 == 0) return value + 1;
    if (value >= 0x0370 and value <= 0x0376 and value != 0x0374 and value % 2 == 0) return value + 1;
    if (value == 0x037f) return 0x03f3;
    switch (value) {
        0x0386 => return 0x03ac,
        0x0388 => return 0x03ad,
        0x0389 => return 0x03ae,
        0x038a => return 0x03af,
        0x038c => return 0x03cc,
        0x038e => return 0x03cd,
        0x038f => return 0x03ce,
        else => {},
    }
    if (value == 0x03cf) return 0x03d7;
    if (value >= 0x0391 and value <= 0x03a1) return value + 32;
    if (value >= 0x03a3 and value <= 0x03ab) return value + 32;
    if (value == 0x03c2) return 0x03c3;
    if (value >= 0x03d8 and value <= 0x03ee and value % 2 == 0) return value + 1;
    if (value == 0x03f4) return 0x03b8;
    if (value == 0x03f7) return 0x03f8;
    if (value == 0x03f9) return 0x03f2;
    if (value == 0x03fa) return 0x03fb;
    if (value >= 0x03fd and value <= 0x03ff) return value - 0x82;
    if (value >= 0x0400 and value <= 0x040f) return value + 80;
    if (value >= 0x0410 and value <= 0x042f) return value + 32;
    if (value >= 0x0460 and value <= 0x0480 and value % 2 == 0) return value + 1;
    if (value >= 0x048a and value <= 0x04be and value % 2 == 0) return value + 1;
    if (value == 0x04c0) return 0x04cf;
    if (value >= 0x04c1 and value <= 0x04cd and value % 2 == 1) return value + 1;
    if (value >= 0x04d0 and value <= 0x052e and value % 2 == 0) return value + 1;
    if (value >= 0x0531 and value <= 0x0556) return value + 0x30;
    if (value >= 0x1e00 and value <= 0x1e94 and value % 2 == 0) return value + 1;
    if (value == 0x1e9b) return 0x1e61;
    if (value >= 0x1ea0 and value <= 0x1efe and value % 2 == 0) return value + 1;
    if ((value >= 0x1f08 and value <= 0x1f0f) or
        (value >= 0x1f18 and value <= 0x1f1d) or
        (value >= 0x1f28 and value <= 0x1f2f) or
        (value >= 0x1f38 and value <= 0x1f3f) or
        (value >= 0x1f48 and value <= 0x1f4d) or
        (value >= 0x1f68 and value <= 0x1f6f) or
        (value >= 0x1f88 and value <= 0x1f8f) or
        (value >= 0x1f98 and value <= 0x1f9f) or
        (value >= 0x1fa8 and value <= 0x1faf) or
        (value >= 0x1fb8 and value <= 0x1fb9) or
        (value >= 0x1fd8 and value <= 0x1fd9) or
        (value >= 0x1fe8 and value <= 0x1fe9) or
        value == 0x1f59 or value == 0x1f5b or value == 0x1f5d or value == 0x1f5f)
        return value - 8;
    if (value >= 0x1fba and value <= 0x1fbb) return value - 0x4a;
    if (value == 0x1fbc or value == 0x1fcc or value == 0x1ffc) return value - 9;
    if (value >= 0x1fc8 and value <= 0x1fcb) return value - 0x56;
    if (value >= 0x1fda and value <= 0x1fdb) return value - 0x64;
    if (value >= 0x1fea and value <= 0x1feb) return value - 0x70;
    if (value == 0x1fec) return value - 7;
    if (value >= 0x1ff8 and value <= 0x1ff9) return value - 0x80;
    if (value >= 0x1ffa and value <= 0x1ffb) return value - 0x7e;
    if (value >= 0x2c00 and value <= 0x2c2f) return value + 0x30;
    if (value == 0x2c60 or value == 0x2c67 or value == 0x2c69 or
        value == 0x2c6b or value == 0x2c72 or value == 0x2c75)
        return value + 1;
    switch (value) {
        0x2c62 => return 0x026b,
        0x2c63 => return 0x1d7d,
        0x2c64 => return 0x027d,
        0x2c6d => return 0x0251,
        0x2c6e => return 0x0271,
        0x2c6f => return 0x0250,
        0x2c70 => return 0x0252,
        0x2c7e => return 0x023f,
        0x2c7f => return 0x0240,
        else => {},
    }
    if (value >= 0x2c80 and value <= 0x2ce2 and value % 2 == 0) return value + 1;
    if (value == 0x2ceb or value == 0x2ced or value == 0x2cf2) return value + 1;
    if (value >= 0x10a0 and value <= 0x10c5) return value + 0x1c60;
    if (value == 0x10c7) return 0x2d27;
    if (value == 0x10cd) return 0x2d2d;
    if (value >= 0x13a0 and value <= 0x13ef) return value + 0x97d0;
    if (value >= 0x13f0 and value <= 0x13f5) return value + 8;
    if (value >= 0x1c90 and value <= 0x1cba) return value - 0x0bc0;
    if (value >= 0x1cbd and value <= 0x1cbf) return value - 0x0bc0;
    if (value == 0x2132) return 0x214e;
    if (value >= 0x2160 and value <= 0x216f) return value + 0x10;
    if (value == 0x2183) return 0x2184;
    if (value >= 0x24b6 and value <= 0x24cf) return value + 0x1a;
    if (value >= 0xff21 and value <= 0xff3a) return value + 0x20;
    if (value >= 0x10400 and value <= 0x10427) return value + 0x28;
    if (value >= 0x104b0 and value <= 0x104d3) return value + 0x28;
    if ((value >= 0x10570 and value <= 0x1057a) or
        (value >= 0x1057c and value <= 0x1058a) or
        (value >= 0x1058c and value <= 0x10592) or
        (value >= 0x10594 and value <= 0x10595))
        return value + 0x27;
    if (value >= 0x10c80 and value <= 0x10cb2) return value + 0x40;
    if (value >= 0x118a0 and value <= 0x118bf) return value + 0x20;
    if (value >= 0x16e40 and value <= 0x16e5f) return value + 0x20;
    if (value >= 0x1e900 and value <= 0x1e921) return value + 0x22;
    if (value >= 0xa640 and value <= 0xa66c and value % 2 == 0) return value + 1;
    if (value >= 0xa680 and value <= 0xa69a and value % 2 == 0) return value + 1;
    if (value >= 0xa722 and value <= 0xa72e and value % 2 == 0) return value + 1;
    if (value >= 0xa732 and value <= 0xa76e and value % 2 == 0) return value + 1;
    if ((value >= 0xa779 and value <= 0xa77c and value % 2 == 1) or
        (value >= 0xa77e and value <= 0xa787 and value % 2 == 0) or
        value == 0xa78b or
        (value >= 0xa790 and value <= 0xa792 and value % 2 == 0) or
        (value >= 0xa796 and value <= 0xa7a8 and value % 2 == 0) or
        (value >= 0xa7b4 and value <= 0xa7c2 and value % 2 == 0) or
        value == 0xa7c7 or value == 0xa7c9 or value == 0xa7d0 or
        value == 0xa7d6 or value == 0xa7d8 or value == 0xa7f5)
        return value + 1;
    switch (value) {
        0xa77d => return 0x1d79,
        0xa78d => return 0x0265,
        0xa7aa => return 0x0266,
        0xa7ab => return 0x025c,
        0xa7ac => return 0x0261,
        0xa7ad => return 0x026c,
        0xa7ae => return 0x026a,
        0xa7b0 => return 0x029e,
        0xa7b1 => return 0x0287,
        0xa7b2 => return 0x029d,
        0xa7b3 => return 0xab53,
        0xa7c4 => return 0xa794,
        0xa7c5 => return 0x0282,
        0xa7c6 => return 0x1d8e,
        else => {},
    }
    return value;
}

pub fn parseControl(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 1 >= end or pattern[index] != 'c') return null;
    return .{ .byte = pattern[index + 1] & 0x1f, .end = index + 2 };
}

pub fn parseControlDash(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 2 >= end or pattern[index] != 'C' or pattern[index + 1] != '-') return null;
    return .{ .byte = pattern[index + 2] & 0x1f, .end = index + 3 };
}

pub fn parseMeta(pattern: []const u8, index: usize, end: usize) ?HexEscape {
    if (index + 2 >= end or pattern[index] != 'M' or pattern[index + 1] != '-') return null;
    if (pattern[index + 2] == '\\') {
        const parsed = parseControlDash(pattern, index + 3, end) orelse return null;
        return .{ .byte = parsed.byte | 0x80, .end = parsed.end };
    }
    return .{ .byte = pattern[index + 2] | 0x80, .end = index + 3 };
}

pub fn isClass(value: u8) bool {
    return value == 'd' or value == 'h' or value == 'w' or value == 's' or value == 'D' or value == 'H' or value == 'W' or value == 'S';
}

pub fn isNonLiteral(value: u8) bool {
    return value == 'A' or value == 'G' or value == 'K' or value == 'N' or value == 'O' or value == 'R' or value == 'X' or value == 'Y' or value == 'Z' or value == 'c' or value == 'C' or value == 'M' or value == 'm' or value == 'o' or value == 'u' or value == 'y' or value == 'z';
}

pub fn isFlag(value: u8) bool {
    return switch (value) {
        '-', 'i', 'm', 'x', 'W', 'D', 'S', 'P', 'y' => true,
        else => false,
    };
}

pub fn flagTokenEnd(pattern: []const u8, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    if (pattern[start] == 'y' and start + 3 < end and pattern[start + 1] == '{' and
        (pattern[start + 2] == 'g' or pattern[start + 2] == 'w') and pattern[start + 3] == '}')
        return start + 4;
    return if (isFlag(pattern[start])) start + 1 else null;
}

pub fn flagRunEnd(pattern: []const u8, start: usize, end: usize, terminator: u8) ?usize {
    var i = start;
    while (flagTokenEnd(pattern, i, end)) |next| i = next;
    return if (i > start and i < end and pattern[i] == terminator) i else null;
}

pub fn asciiLower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + 32 else value;
}

pub fn isLineBreak(value: u8) bool {
    return value == '\n' or value == '\r' or value == 0x0b or value == 0x0c or value == 0x85;
}

pub fn lineStartAnchorMatches(text: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    if (pos > text.len) return false;
    if (text[pos - 1] == '\r' and pos < text.len and text[pos] == '\n') return false;
    return isLineBreak(text[pos - 1]) or
        (pos >= 3 and (std.mem.eql(u8, text[pos - 3 .. pos], "\xe2\x80\xa8") or
            std.mem.eql(u8, text[pos - 3 .. pos], "\xe2\x80\xa9")));
}

pub fn lineEndAnchorMatches(text: []const u8, pos: usize) bool {
    if (pos == text.len) return true;
    if (pos >= text.len) return false;
    return text[pos] == '\n';
}

pub fn endAnchorMatches(text: []const u8, pos: usize, before_final_newline: bool) bool {
    if (pos == text.len) return true;
    if (!before_final_newline or pos >= text.len) return false;
    return pos + 1 == text.len and text[pos] == '\n';
}

fn hexValue(value: u8) ?u16 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    if (value >= 'A' and value <= 'F') return value - 'A' + 10;
    return null;
}

fn parseHexCodepoint(pattern: []const u8, index: usize, end: usize) ?CodepointEscape {
    if (index + 1 < end and pattern[index + 1] == '{') return parseBracedCodepoint(pattern, index, end, 16);
    return if (parseHex(pattern, index, end)) |parsed| encodeCodepoint(parsed.byte, parsed.end) else null;
}

fn parseOctalCodepointScalar(pattern: []const u8, index: usize, end: usize) ?CodepointEscape {
    if (index + 2 >= end or pattern[index] != 'o' or pattern[index + 1] != '{') return null;
    return parseBracedCodepoint(pattern, index, end, 8);
}

fn parseUnicode4Codepoint(pattern: []const u8, index: usize, end: usize) ?CodepointEscape {
    if (index + 4 >= end or pattern[index] != 'u') return null;
    var value: u32 = 0;
    for (pattern[index + 1 .. index + 5]) |digit| value = value * 16 + (hexValue(digit) orelse return null);
    return encodeCodepoint(value, index + 5);
}

fn parseBracedCodepoint(pattern: []const u8, index: usize, end: usize, base: u8) ?CodepointEscape {
    var i = index + 2;
    var out = CodepointEscape{};
    var saw = false;
    while (true) {
        while (i < end and std.ascii.isWhitespace(pattern[i])) : (i += 1) {}
        if (i >= end) return null;
        if (pattern[i] == '}') {
            if (!saw) return null;
            out.end = i + 1;
            return out;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (i < end and pattern[i] != '}' and !std.ascii.isWhitespace(pattern[i])) : ({
            i += 1;
            digits += 1;
        }) {
            const digit = if (base == 8)
                if (pattern[i] >= '0' and pattern[i] <= '7') pattern[i] - '0' else return null
            else
                hexValue(pattern[i]) orelse return null;
            value = value * base + digit;
            if (value > 0x10ffff) return null;
        }
        if (digits == 0 or !appendCodepoint(&out, value)) return null;
        saw = true;
    }
}

fn encodeCodepoint(value: u32, end: usize) ?CodepointEscape {
    if (value > std.math.maxInt(u21)) return null;
    var out = CodepointEscape{ .end = end };
    if (!appendCodepoint(&out, value)) return null;
    return out;
}

fn appendCodepoint(out: *CodepointEscape, value: u32) bool {
    if (value > std.math.maxInt(u21)) return false;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(value), &buf) catch return false;
    if (@as(usize, out.len) + len > out.bytes.len) return false;
    @memcpy(out.bytes[out.len..][0..len], buf[0..len]);
    out.len += @intCast(len);
    return true;
}

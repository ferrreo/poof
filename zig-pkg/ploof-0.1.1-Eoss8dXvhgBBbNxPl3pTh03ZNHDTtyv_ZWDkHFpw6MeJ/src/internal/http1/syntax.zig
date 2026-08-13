const std = @import("std");

const ByteClass = packed struct(u8) {
    token: bool,
    field_value: bool,
    ows: bool,
    decimal: bool,
    hexadecimal: bool,
    upper: bool,
    _: u2 = 0,
};

const byte_classes = makeByteClasses();

pub const ParseUnsignedError = error{
    Empty,
    InvalidDigit,
    Overflow,
};

pub fn isTokenByte(byte: u8) bool {
    return byte_classes[byte].token;
}

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (!isTokenByte(byte)) return false;
    }
    return true;
}

pub fn isFieldValueByte(byte: u8) bool {
    return byte_classes[byte].field_value;
}

pub fn isFieldValue(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!isFieldValueByte(byte)) return false;
    }
    return true;
}

pub fn isUriPchar(byte: u8) bool {
    return isUnreserved(byte) or isSubDelimiter(byte) or byte == ':' or byte == '@';
}

pub fn asciiLower(byte: u8) u8 {
    const lower_bit = @as(u8, @intFromBool(byte_classes[byte].upper)) << 5;
    return byte | lower_bit;
}

pub fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;

    var difference: u8 = 0;
    for (left, right) |left_byte, right_byte| {
        difference |= asciiLower(left_byte) ^ asciiLower(right_byte);
    }
    return difference == 0;
}

pub fn trimOws(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and byte_classes[bytes[start]].ows) : (start += 1) {}

    var end = bytes.len;
    while (end > start and byte_classes[bytes[end - 1]].ows) : (end -= 1) {}
    return bytes[start..end];
}

pub fn parseDecimal(bytes: []const u8) ParseUnsignedError!u64 {
    return parseUnsigned(bytes, 10);
}

pub fn parseHex(bytes: []const u8) ParseUnsignedError!u64 {
    return parseUnsigned(bytes, 16);
}

fn parseUnsigned(bytes: []const u8, comptime radix: u8) ParseUnsignedError!u64 {
    if (bytes.len == 0) return error.Empty;

    var value: u64 = 0;
    for (bytes) |byte| {
        const class = byte_classes[byte];
        const valid = if (radix == 10) class.decimal else class.hexadecimal;
        if (!valid) return error.InvalidDigit;
        const digit = digitValue(byte);
        const digit_wide: u64 = digit;
        const radix_wide: u64 = radix;
        if (value > (std.math.maxInt(u64) - digit_wide) / radix_wide) {
            return error.Overflow;
        }
        value = value * radix_wide + digit_wide;
    }
    return value;
}

fn digitValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => std.math.maxInt(u8),
    };
}

fn makeByteClasses() [256]ByteClass {
    @setEvalBranchQuota(5000);
    var classes: [256]ByteClass = undefined;
    for (0..classes.len) |index| {
        const byte: u8 = @intCast(index);
        classes[index] = .{
            .token = isTokenLiteral(byte),
            .field_value = byte == '\t' or (byte >= 0x20 and byte != 0x7f),
            .ows = byte == ' ' or byte == '\t',
            .decimal = byte >= '0' and byte <= '9',
            .hexadecimal = digitValue(byte) < 16,
            .upper = byte >= 'A' and byte <= 'Z',
        };
    }
    return classes;
}

fn isTokenLiteral(byte: u8) bool {
    return switch (byte) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => true,
        else => false,
    };
}

fn isUnreserved(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

fn isSubDelimiter(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", byte) != null;
}

test "classifies every byte" {
    const punctuation = "!#$%&'*+-.^_`|~";
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        const alphanumeric = (byte >= '0' and byte <= '9') or
            (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
        const punctuation_token = std.mem.indexOfScalar(u8, punctuation, byte) != null;
        const field_value = byte == '\t' or (byte >= 0x20 and byte != 0x7f);
        const expected_lower = if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;

        try std.testing.expectEqual(alphanumeric or punctuation_token, isTokenByte(byte));
        try std.testing.expectEqual(field_value, isFieldValueByte(byte));
        try std.testing.expectEqual(byte == ' ' or byte == '\t', byte_classes[byte].ows);
        try std.testing.expectEqual(byte >= '0' and byte <= '9', byte_classes[byte].decimal);
        try std.testing.expectEqual(digitValue(byte) < 16, byte_classes[byte].hexadecimal);
        try std.testing.expectEqual(expected_lower, asciiLower(byte));
    }
}

test "validates tokens and field values" {
    try std.testing.expect(!isToken(""));
    try std.testing.expect(isToken("Content-Type"));
    try std.testing.expect(isToken("!#$%&'*+-.^_`|~"));
    try std.testing.expect(!isToken("bad name"));
    try std.testing.expect(!isToken("bad:name"));
    try std.testing.expect(!isToken("\x80"));

    try std.testing.expect(isFieldValue(""));
    try std.testing.expect(isFieldValue("\t visible \x80\xff"));
    try std.testing.expect(!isFieldValue("nul\x00"));
    try std.testing.expect(!isFieldValue("line\r\nbreak"));
    try std.testing.expect(!isFieldValue("delete\x7f"));

    try std.testing.expect(isUriPchar('!'));
    try std.testing.expect(isUriPchar(':'));
    try std.testing.expect(!isUriPchar('['));
    try std.testing.expect(!isUriPchar('?'));
}

test "compares ASCII without case and trims OWS" {
    try std.testing.expect(eqlIgnoreCase("Content-Type", "content-type"));
    try std.testing.expect(eqlIgnoreCase("ETAG", "etag"));
    try std.testing.expect(!eqlIgnoreCase("etag", "etags"));
    try std.testing.expect(!eqlIgnoreCase("\xc0", "\xe0"));

    try std.testing.expectEqualStrings("value", trimOws(" \tvalue\t "));
    try std.testing.expectEqualStrings("", trimOws("\t  \t"));
    try std.testing.expectEqualStrings("value", trimOws("value"));
    try std.testing.expectEqualStrings("a b", trimOws(" a b "));
}

test "parses checked decimal integers" {
    try std.testing.expectEqual(@as(u64, 0), try parseDecimal("0"));
    try std.testing.expectEqual(@as(u64, 42), try parseDecimal("00042"));
    try std.testing.expectEqual(std.math.maxInt(u64), try parseDecimal("18446744073709551615"));
    try std.testing.expectError(error.Empty, parseDecimal(""));
    try std.testing.expectError(error.InvalidDigit, parseDecimal("+1"));
    try std.testing.expectError(error.InvalidDigit, parseDecimal("1 "));
    try std.testing.expectError(error.Overflow, parseDecimal("18446744073709551616"));
}

test "parses checked hexadecimal integers" {
    try std.testing.expectEqual(@as(u64, 0), try parseHex("0"));
    try std.testing.expectEqual(@as(u64, 0xabcdef), try parseHex("AbCdEf"));
    try std.testing.expectEqual(std.math.maxInt(u64), try parseHex("ffffffffffffffff"));
    try std.testing.expectError(error.Empty, parseHex(""));
    try std.testing.expectError(error.InvalidDigit, parseHex("0x10"));
    try std.testing.expectError(error.InvalidDigit, parseHex("g"));
    try std.testing.expectError(error.Overflow, parseHex("10000000000000000"));
}

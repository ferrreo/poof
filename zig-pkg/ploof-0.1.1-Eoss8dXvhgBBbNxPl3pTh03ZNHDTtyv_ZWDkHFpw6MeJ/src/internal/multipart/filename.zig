const std = @import("std");

pub const Error = error{
    Malformed,
    LimitExceeded,
};

pub fn decodeValue(
    bytes: []u8,
    quoted: bool,
    bytes_max: usize,
    require_nonempty: bool,
) Error![]const u8 {
    var source: usize = 0;
    var target: usize = 0;
    while (source < bytes.len) {
        if (quoted and bytes[source] == '\\') source += 1;
        if (source == bytes.len) return error.Malformed;
        if (target == bytes_max) return error.LimitExceeded;
        bytes[target] = bytes[source];
        source += 1;
        target += 1;
    }
    const decoded = bytes[0..target];
    if (require_nonempty and decoded.len == 0) return error.Malformed;
    try validateDecoded(decoded);
    return decoded;
}

pub fn decodeExtended(bytes: []u8, bytes_max: usize) Error![]const u8 {
    const charset_end = std.mem.indexOfScalar(u8, bytes, '\'') orelse {
        return error.Malformed;
    };
    const language_start = charset_end + 1;
    const relative_end = std.mem.indexOfScalar(u8, bytes[language_start..], '\'') orelse {
        return error.Malformed;
    };
    const language_end = language_start + relative_end;
    if (!std.ascii.eqlIgnoreCase(bytes[0..charset_end], "utf-8")) {
        return error.Malformed;
    }
    if (!validLanguage(bytes[language_start..language_end])) return error.Malformed;

    var source = language_end + 1;
    var target: usize = 0;
    while (source < bytes.len) {
        const byte = if (bytes[source] == '%') encoded: {
            if (source + 2 >= bytes.len) return error.Malformed;
            const high = hex(bytes[source + 1]) orelse return error.Malformed;
            const low = hex(bytes[source + 2]) orelse return error.Malformed;
            source += 3;
            break :encoded (high << 4) | low;
        } else plain: {
            const value = bytes[source];
            if (!isAttrChar(value)) return error.Malformed;
            source += 1;
            break :plain value;
        };
        if (target == bytes_max) return error.LimitExceeded;
        bytes[target] = byte;
        target += 1;
    }
    const decoded = bytes[0..target];
    try validateDecoded(decoded);
    return decoded;
}

fn validateDecoded(bytes: []const u8) Error!void {
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.Malformed;
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
}

fn validLanguage(language: []const u8) bool {
    if (language.len == 0) return true;
    if (!validTagBytes(language)) return false;
    if (isIrregularGrandfathered(language)) return true;

    var cursor = SubtagCursor{ .bytes = language };
    const primary = cursor.next() orelse return false;
    if (std.ascii.eqlIgnoreCase(primary.bytes, "x")) return validPrivate(&cursor);
    if (!isAlphaLength(primary.bytes, 2, 8)) return false;

    var current = cursor.next();
    if (primary.bytes.len <= 3) {
        for (0..3) |_| {
            const part = current orelse break;
            if (!isAlphaLength(part.bytes, 3, 3)) break;
            current = cursor.next();
        }
    }
    if (current) |part| {
        if (isAlphaLength(part.bytes, 4, 4)) current = cursor.next();
    }
    if (current) |part| {
        if (isRegion(part.bytes)) current = cursor.next();
    }

    var variants_start: ?usize = null;
    while (current) |part| {
        if (!isVariant(part.bytes)) break;
        if (variants_start) |start| {
            if (containsSubtag(language[start .. part.start - 1], part.bytes)) return false;
        } else variants_start = part.start;
        current = cursor.next();
    }
    return validExtensionsAndPrivate(current, &cursor);
}

const Subtag = struct {
    bytes: []const u8,
    start: usize,
};

const SubtagCursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn next(cursor: *SubtagCursor) ?Subtag {
        if (cursor.index == cursor.bytes.len) return null;
        const start = cursor.index;
        const relative_end = std.mem.indexOfScalar(u8, cursor.bytes[start..], '-');
        const end = if (relative_end) |value| start + value else cursor.bytes.len;
        cursor.index = if (end == cursor.bytes.len) end else end + 1;
        return .{ .bytes = cursor.bytes[start..end], .start = start };
    }
};

fn validExtensionsAndPrivate(current: ?Subtag, cursor: *SubtagCursor) bool {
    var part = current;
    var singleton_mask: u64 = 0;
    while (part) |singleton| {
        if (std.ascii.eqlIgnoreCase(singleton.bytes, "x")) return validPrivate(cursor);
        if (singleton.bytes.len != 1 or
            !std.ascii.isAlphanumeric(singleton.bytes[0])) return false;
        const bit = singletonBit(singleton.bytes[0]);
        if (singleton_mask & bit != 0) return false;
        singleton_mask |= bit;

        part = cursor.next();
        var values: usize = 0;
        while (part) |value| {
            if (value.bytes.len == 1) break;
            if (!isAlphanumericLength(value.bytes, 2, 8)) return false;
            values += 1;
            part = cursor.next();
        }
        if (values == 0) return false;
    }
    return true;
}

fn validPrivate(cursor: *SubtagCursor) bool {
    var count: usize = 0;
    while (cursor.next()) |part| {
        if (!isAlphanumericLength(part.bytes, 1, 8)) return false;
        count += 1;
    }
    return count != 0;
}

fn isIrregularGrandfathered(language: []const u8) bool {
    const tags = [_][]const u8{
        "en-GB-oed", "i-ami",     "i-bnn", "i-default", "i-enochian",
        "i-hak",     "i-klingon", "i-lux", "i-mingo",   "i-navajo",
        "i-pwn",     "i-tao",     "i-tay", "i-tsu",     "sgn-BE-FR",
        "sgn-BE-NL", "sgn-CH-DE",
    };
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(language, tag)) return true;
    return false;
}

fn validTagBytes(language: []const u8) bool {
    if (language[0] == '-' or language[language.len - 1] == '-') return false;
    var previous_hyphen = false;
    for (language) |byte| {
        const hyphen = byte == '-';
        if (!hyphen and !std.ascii.isAlphanumeric(byte)) return false;
        if (hyphen and previous_hyphen) return false;
        previous_hyphen = hyphen;
    }
    return true;
}

fn containsSubtag(region: []const u8, candidate: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, region, '-');
    while (iterator.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, candidate)) return true;
    }
    return false;
}

fn isVariant(part: []const u8) bool {
    if (!isAlphanumericLength(part, 4, 8)) return false;
    return part.len >= 5 or std.ascii.isDigit(part[0]);
}

fn isRegion(part: []const u8) bool {
    return isAlphaLength(part, 2, 2) or isDigitLength(part, 3, 3);
}

fn isAlphaLength(part: []const u8, min: usize, max: usize) bool {
    if (part.len < min or part.len > max) return false;
    for (part) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return true;
}

fn isDigitLength(part: []const u8, min: usize, max: usize) bool {
    if (part.len < min or part.len > max) return false;
    for (part) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isAlphanumericLength(part: []const u8, min: usize, max: usize) bool {
    if (part.len < min or part.len > max) return false;
    for (part) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

fn singletonBit(byte: u8) u64 {
    const lower = if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;
    const index = if (lower >= '0' and lower <= '9') lower - '0' else lower - 'a' + 10;
    return @as(u64, 1) << @intCast(index);
}

fn isAttrChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        std.mem.indexOfScalar(u8, "!#$&+-.^_`|~", byte) != null;
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

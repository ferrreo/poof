const syntax = @import("syntax.zig");

pub const Mode = enum(u8) {
    bytes,
    text,
};

pub const Charset = enum(u8) {
    implicit_utf8,
    explicit_utf8,
};

pub const Media = struct {
    raw: []const u8,
    type: []const u8,
    subtype: []const u8,
};

pub const ParameterValue = struct {
    bytes: []const u8,
    quoted: bool,
};

pub const Parsed = struct {
    media: Media,
    charset: ?ParameterValue,
    charset_count: usize,
};

pub fn parse(value_raw: []const u8) error{MalformedContentType}!Parsed {
    const value = syntax.trimOws(value_raw);
    var cursor: usize = 0;
    const media_type = consumeToken(value, &cursor) orelse {
        return error.MalformedContentType;
    };
    if (!consumeByte(value, &cursor, '/')) return error.MalformedContentType;
    const media_subtype = consumeToken(value, &cursor) orelse {
        return error.MalformedContentType;
    };
    var parsed = Parsed{
        .media = .{
            .raw = value,
            .type = media_type,
            .subtype = media_subtype,
        },
        .charset = null,
        .charset_count = 0,
    };

    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!consumeByte(value, &cursor, ';')) return error.MalformedContentType;
        skipOws(value, &cursor);
        if (cursor == value.len or value[cursor] == ';') continue;
        const name = consumeToken(value, &cursor) orelse {
            return error.MalformedContentType;
        };
        if (!consumeByte(value, &cursor, '=')) return error.MalformedContentType;
        const parameter = try consumeParameterValue(value, &cursor);
        if (!syntax.eqlIgnoreCase(name, "charset")) continue;
        parsed.charset_count += 1;
        if (parsed.charset == null) parsed.charset = parameter;
    }
    return parsed;
}

pub fn validateCharset(
    mode: Mode,
    parsed: Parsed,
) error{ DuplicateCharset, UnsupportedCharset }!?Charset {
    if (mode == .bytes) return null;
    if (parsed.charset_count > 1) return error.DuplicateCharset;
    const parameter = parsed.charset orelse return .implicit_utf8;
    if (!parameterEquals(parameter, "utf-8")) return error.UnsupportedCharset;
    return .explicit_utf8;
}

fn consumeToken(value: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < value.len and syntax.isTokenByte(value[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == start) return null;
    return value[start..cursor.*];
}

fn consumeByte(value: []const u8, cursor: *usize, expected: u8) bool {
    if (cursor.* == value.len or value[cursor.*] != expected) return false;
    cursor.* += 1;
    return true;
}

fn consumeParameterValue(
    value: []const u8,
    cursor: *usize,
) error{MalformedContentType}!ParameterValue {
    if (cursor.* == value.len) return error.MalformedContentType;
    if (value[cursor.*] != '"') {
        const token = consumeToken(value, cursor) orelse return error.MalformedContentType;
        return .{ .bytes = token, .quoted = false };
    }
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < value.len) {
        const byte = value[cursor.*];
        cursor.* += 1;
        if (byte == '"') {
            return .{ .bytes = value[start .. cursor.* - 1], .quoted = true };
        }
        if (byte == '\\') {
            if (cursor.* == value.len or !validQuotedPairByte(value[cursor.*])) {
                return error.MalformedContentType;
            }
            cursor.* += 1;
        } else if (!validQuotedTextByte(byte)) {
            return error.MalformedContentType;
        }
    }
    return error.MalformedContentType;
}

fn validQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == 0x21 or
        (byte >= 0x23 and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e) or byte >= 0x80;
}

fn validQuotedPairByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn parameterEquals(parameter: ParameterValue, expected: []const u8) bool {
    if (!parameter.quoted) return syntax.eqlIgnoreCase(parameter.bytes, expected);
    var source: usize = 0;
    var target: usize = 0;
    while (source < parameter.bytes.len and target < expected.len) {
        if (parameter.bytes[source] == '\\') {
            source += 1;
            if (source == parameter.bytes.len) return false;
        }
        const different = syntax.asciiLower(parameter.bytes[source]) !=
            syntax.asciiLower(expected[target]);
        if (different) return false;
        source += 1;
        target += 1;
    }
    return source == parameter.bytes.len and target == expected.len;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

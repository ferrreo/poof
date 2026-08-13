const std = @import("std");
const syntax = @import("syntax.zig");

pub const ParseError = error{InvalidMediaType};

pub const MediaType = struct {
    value: []const u8,

    pub fn bytes(self: MediaType) []const u8 {
        return self.value;
    }
};

pub const json = parseComptime("application/json; charset=utf-8");
pub const html = parseComptime("text/html; charset=utf-8");
pub const text = parseComptime("text/plain; charset=utf-8");
pub const octet_stream = parseComptime("application/octet-stream");

pub fn parse(value: []const u8) ParseError!MediaType {
    var cursor: usize = 0;
    if (!consumeToken(value, &cursor)) return error.InvalidMediaType;
    if (!consumeByte(value, &cursor, '/')) return error.InvalidMediaType;
    if (!consumeToken(value, &cursor)) return error.InvalidMediaType;

    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!consumeByte(value, &cursor, ';')) return error.InvalidMediaType;
        skipOws(value, &cursor);
        if (cursor == value.len or value[cursor] == ';') continue;
        if (!consumeToken(value, &cursor)) return error.InvalidMediaType;
        if (!consumeByte(value, &cursor, '=')) return error.InvalidMediaType;
        if (cursor == value.len) return error.InvalidMediaType;
        if (value[cursor] == '"') {
            try consumeQuoted(value, &cursor);
        } else if (!consumeToken(value, &cursor)) {
            return error.InvalidMediaType;
        }
    }
    return .{ .value = value };
}

pub fn parseComptime(comptime value: []const u8) MediaType {
    return parse(value) catch @compileError("invalid HTTP media type");
}

fn consumeToken(value: []const u8, cursor: *usize) bool {
    const start = cursor.*;
    while (cursor.* < value.len and syntax.isTokenByte(value[cursor.*])) {
        cursor.* += 1;
    }
    return cursor.* != start;
}

fn consumeByte(value: []const u8, cursor: *usize, expected: u8) bool {
    if (cursor.* == value.len or value[cursor.*] != expected) return false;
    cursor.* += 1;
    return true;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len) : (cursor.* += 1) {
        const byte = value[cursor.*];
        if (byte != ' ' and byte != '\t') break;
    }
}

fn consumeQuoted(value: []const u8, cursor: *usize) ParseError!void {
    std.debug.assert(value[cursor.*] == '"');
    cursor.* += 1;
    while (cursor.* < value.len) {
        const byte = value[cursor.*];
        cursor.* += 1;
        if (byte == '"') return;
        if (byte == '\\') {
            if (cursor.* == value.len or !isQuotedPairByte(value[cursor.*])) {
                return error.InvalidMediaType;
            }
            cursor.* += 1;
        } else if (!isQuotedTextByte(byte)) {
            return error.InvalidMediaType;
        }
    }
    return error.InvalidMediaType;
}

fn isQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or
        byte >= 0x80;
}

fn isQuotedPairByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or (byte >= '!' and byte <= '~') or
        byte >= 0x80;
}

test "defaults have exact stable wire values" {
    try std.testing.expectEqualStrings("application/json; charset=utf-8", json.bytes());
    try std.testing.expectEqualStrings("text/html; charset=utf-8", html.bytes());
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", text.bytes());
    try std.testing.expectEqualStrings("application/octet-stream", octet_stream.bytes());
}

test "parses tokens parameters quoted strings and structured suffixes" {
    const valid = [_][]const u8{
        "Text/HTML;Charset=\"utf-8\"",
        "application/problem+json",
        "image/svg+xml",
        "application/example; title=\"a \\\"quoted\\\" value\"; empty=\"\"",
        "text/plain \t; charset=utf-8",
        "text/plain;",
        "text/plain; ; charset=utf-8;;",
        "text/plain; note=\"obs\x80text\"",
        "text/plain; note=\"escaped\\\x80text\"",
    };
    for (valid) |value| {
        const media = try parse(value);
        try std.testing.expectEqualStrings(value, media.bytes());
        try std.testing.expectEqual(@intFromPtr(value.ptr), @intFromPtr(media.bytes().ptr));
    }
}

test "rejects malformed and injected media types" {
    const invalid = [_][]const u8{
        "",
        "text",
        "/plain",
        "text/",
        "text /plain",
        "text/ plain",
        "text/plain ",
        "text/plain; charset",
        "text/plain; charset=",
        "text/plain; charset =utf-8",
        "text/plain; charset= utf-8",
        "text/plain; charset=\"unterminated",
        "text/plain; charset=\"bad\rvalue\"",
        "text/plain; charset=\"bad\\\nvalue\"",
        "text/plain, text/html",
        "text/plain\r\nx-injected: yes",
        "text/plain\x00",
        "text/plain\x7f",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidMediaType, parse(value));
    }
}

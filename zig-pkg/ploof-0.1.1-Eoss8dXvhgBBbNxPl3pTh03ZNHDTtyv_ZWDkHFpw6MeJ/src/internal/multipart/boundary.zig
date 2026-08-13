const std = @import("std");
const syntax = @import("../http1/syntax.zig");

pub const protocol_bytes_max: usize = 70;

pub const Error = error{
    Malformed,
    LimitExceeded,
};

const Value = struct {
    bytes: []const u8,
    quoted: bool,
};

pub fn parse(
    value_raw: []const u8,
    configured_bytes_max: usize,
    storage: *[protocol_bytes_max]u8,
) Error![]const u8 {
    std.debug.assert(configured_bytes_max > 0);
    std.debug.assert(configured_bytes_max <= protocol_bytes_max);

    const value = syntax.trimOws(value_raw);
    var cursor: usize = 0;
    const media_type = consumeToken(value, &cursor) orelse return error.Malformed;
    if (!consumeByte(value, &cursor, '/')) return error.Malformed;
    const subtype = consumeToken(value, &cursor) orelse return error.Malformed;
    if (!syntax.eqlIgnoreCase(media_type, "multipart") or
        !syntax.eqlIgnoreCase(subtype, "form-data"))
    {
        return error.Malformed;
    }

    var boundary: ?Value = null;
    var boundary_count: u8 = 0;
    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!consumeByte(value, &cursor, ';')) return error.Malformed;
        skipOws(value, &cursor);
        if (cursor == value.len or value[cursor] == ';') continue;
        const name = consumeToken(value, &cursor) orelse return error.Malformed;
        if (!consumeByte(value, &cursor, '=')) return error.Malformed;
        const parameter = try consumeValue(value, &cursor);
        if (!syntax.eqlIgnoreCase(name, "boundary")) continue;
        boundary_count = std.math.add(u8, boundary_count, 1) catch {
            return error.Malformed;
        };
        if (boundary == null) boundary = parameter;
    }
    if (boundary_count != 1) return error.Malformed;
    return decode(boundary.?, configured_bytes_max, storage);
}

fn decode(
    value: Value,
    configured_bytes_max: usize,
    storage: *[protocol_bytes_max]u8,
) Error![]const u8 {
    var source: usize = 0;
    var target: usize = 0;
    while (source < value.bytes.len) {
        if (value.quoted and value.bytes[source] == '\\') source += 1;
        if (source == value.bytes.len) return error.Malformed;
        if (target == protocol_bytes_max) return error.Malformed;
        const byte = value.bytes[source];
        if (!isBoundaryByte(byte)) return error.Malformed;
        storage[target] = byte;
        source += 1;
        target += 1;
    }
    if (target == 0 or storage[target - 1] == ' ') return error.Malformed;
    if (target > configured_bytes_max) return error.LimitExceeded;
    return storage[0..target];
}

fn consumeToken(value: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < value.len and syntax.isTokenByte(value[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == start) return null;
    return value[start..cursor.*];
}

fn consumeValue(value: []const u8, cursor: *usize) Error!Value {
    if (cursor.* == value.len) return error.Malformed;
    if (value[cursor.*] != '"') {
        const token = consumeToken(value, cursor) orelse return error.Malformed;
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
            if (cursor.* == value.len or !validQuotedPair(value[cursor.*])) {
                return error.Malformed;
            }
            cursor.* += 1;
        } else if (!validQuotedText(byte)) {
            return error.Malformed;
        }
    }
    return error.Malformed;
}

fn consumeByte(value: []const u8, cursor: *usize, expected: u8) bool {
    if (cursor.* == value.len or value[cursor.*] != expected) return false;
    cursor.* += 1;
    return true;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len) : (cursor.* += 1) {
        if (value[cursor.*] != ' ' and value[cursor.*] != '\t') break;
    }
}

fn validQuotedText(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or
        byte >= 0x80;
}

fn validQuotedPair(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn isBoundaryByte(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "'()+_,-./:=? ", byte) != null;
}

test "extracts strict form-data boundaries without allocation" {
    var storage: [protocol_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "AaB03x",
        try parse("multipart/form-data; boundary=AaB03x", 70, &storage),
    );
    try std.testing.expectEqualStrings(
        "a:b c",
        try parse("Multipart/Form-Data; note=x; boundary=\"a:b c\"", 70, &storage),
    );
    try std.testing.expectEqualStrings(
        "a'b",
        try parse("multipart/form-data; boundary=\"a\\'b\"", 70, &storage),
    );
}

test "distinguishes protocol syntax from route limits" {
    var storage: [protocol_bytes_max]u8 = undefined;
    const seventy = "0123456789012345678901234567890123456789012345678901234567890123456789";
    try std.testing.expectEqualStrings(seventy, try parse(
        "multipart/form-data; boundary=" ++ seventy,
        70,
        &storage,
    ));
    try std.testing.expectError(
        error.LimitExceeded,
        parse("multipart/form-data; boundary=12345", 4, &storage),
    );
    try std.testing.expectError(
        error.Malformed,
        parse("multipart/form-data; boundary=" ++ seventy ++ "x", 70, &storage),
    );
}

test "rejects missing duplicate malformed and invalid boundaries" {
    var storage: [protocol_bytes_max]u8 = undefined;
    const invalid = [_][]const u8{
        "multipart/form-data",
        "multipart/form-data; boundary=a; boundary=b",
        "text/plain; boundary=a",
        "multipart/form-data; boundary=",
        "multipart/form-data; boundary=\"\"",
        "multipart/form-data; boundary=\"a \"",
        "multipart/form-data; boundary=\"a[b\"",
        "multipart/form-data; boundary=\"a\rb\"",
        "multipart/form-data; boundary=\"unterminated",
        "multipart/form-data; boundary =a",
        "multipart/form-data, boundary=a",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.Malformed, parse(value, 70, &storage));
    }
}

test {
    std.testing.refAllDecls(@This());
}

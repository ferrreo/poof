const std = @import("std");
const filename = @import("filename.zig");
const syntax = @import("wire_syntax.zig");
const types = @import("types.zig");

pub const Parsed = struct {
    name: []const u8,
    filename: ?types.ClientFilename,
};

const Value = struct {
    bytes: []u8,
    quoted: bool,
};

const Parameter = struct {
    name: []const u8,
};

pub fn parse(comptime limits: types.Limits, raw: []u8) types.Error!Parsed {
    comptime limits.validate();
    const value = trimOws(raw);
    var cursor: usize = 0;
    const disposition = consumeToken(value, &cursor) orelse return error.Malformed;
    if (!syntax.eqlIgnoreCase(disposition, "form-data")) return error.Malformed;

    var parameters: [limits.disposition_parameters_max]Parameter = undefined;
    var used: usize = 0;
    var name_value: ?Value = null;
    var filename_value: ?Value = null;
    var filename_star_value: ?Value = null;
    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!consumeByte(value, &cursor, ';')) return error.Malformed;
        skipOws(value, &cursor);
        const name = consumeToken(value, &cursor) orelse return error.Malformed;
        if (!consumeByte(value, &cursor, '=')) return error.Malformed;
        const parameter = try consumeValue(value, &cursor);
        if (used == parameters.len) return error.LimitExceeded;
        parameters[used] = .{ .name = name };
        used += 1;
        if (syntax.eqlIgnoreCase(name, "name") and name_value == null) {
            name_value = parameter;
        } else if (syntax.eqlIgnoreCase(name, "filename") and filename_value == null) {
            filename_value = parameter;
        } else if (syntax.eqlIgnoreCase(name, "filename*") and
            filename_star_value == null)
        {
            filename_star_value = parameter;
        }
        skipOws(value, &cursor);
    }
    try rejectDuplicates(parameters[0..used]);
    const encoded_name = name_value orelse return error.Malformed;
    const decoded_name = try filename.decodeValue(
        encoded_name.bytes,
        encoded_name.quoted,
        limits.name_bytes_max,
        true,
    );
    const client_filename = try decodeFilename(
        limits,
        filename_value,
        filename_star_value,
    );
    return .{ .name = decoded_name, .filename = client_filename };
}

fn decodeFilename(
    comptime limits: types.Limits,
    regular: ?Value,
    extended: ?Value,
) types.Error!?types.ClientFilename {
    if (regular != null and extended != null) return error.Malformed;
    if (regular) |value| return .{
        .bytes = try filename.decodeValue(
            value.bytes,
            value.quoted,
            limits.filename_bytes_max,
            false,
        ),
        .source = .filename,
    };
    if (extended) |value| {
        if (value.quoted) return error.Malformed;
        return .{
            .bytes = try filename.decodeExtended(
                value.bytes,
                limits.filename_bytes_max,
            ),
            .source = .filename_star,
        };
    }
    return null;
}

fn consumeValue(value: []u8, cursor: *usize) types.Error!Value {
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
        } else if (!validQuotedText(byte)) return error.Malformed;
    }
    return error.Malformed;
}

fn rejectDuplicates(parameters: []Parameter) types.Error!void {
    if (parameters.len < 2) return;
    heapSort(parameters);
    for (parameters[1..], parameters[0 .. parameters.len - 1]) |current, previous| {
        if (syntax.eqlIgnoreCase(current.name, previous.name)) return error.Malformed;
    }
}

fn heapSort(values: []Parameter) void {
    if (values.len < 2) return;
    var root = values.len / 2;
    while (root != 0) {
        root -= 1;
        siftDown(values, root, values.len);
    }
    var end = values.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Parameter, &values[0], &values[end]);
        siftDown(values, 0, end);
    }
}

fn siftDown(values: []Parameter, start: usize, end: usize) void {
    var root = start;
    while (true) {
        var child = root * 2 + 1;
        if (child >= end) return;
        if (child + 1 < end and less(values[child], values[child + 1])) child += 1;
        if (!less(values[root], values[child])) return;
        std.mem.swap(Parameter, &values[root], &values[child]);
        root = child;
    }
}

fn less(left: Parameter, right: Parameter) bool {
    const count = @min(left.name.len, right.name.len);
    for (left.name[0..count], right.name[0..count]) |left_byte, right_byte| {
        const a = std.ascii.toLower(left_byte);
        const b = std.ascii.toLower(right_byte);
        if (a != b) return a < b;
    }
    return left.name.len < right.name.len;
}

fn consumeToken(value: []u8, cursor: *usize) ?[]u8 {
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

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len) : (cursor.* += 1) {
        if (value[cursor.*] != ' ' and value[cursor.*] != '\t') break;
    }
}

fn trimOws(value: []u8) []u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    var end = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn validQuotedText(byte: u8) bool {
    return byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or byte >= 0x80;
}

fn validQuotedPair(byte: u8) bool {
    return byte >= 0x20 and byte != 0x7f;
}

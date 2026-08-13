const std = @import("std");
const types = @import("types.zig");

pub const Sink = struct {
    bytes: []u8,
    used: usize = 0,

    pub fn writeByte(sink: *Sink, byte: u8) types.Error!void {
        if (sink.used == sink.bytes.len) return error.ResponseBodyTooLarge;
        sink.bytes[sink.used] = byte;
        sink.used += 1;
    }

    pub fn writeAll(sink: *Sink, input: []const u8) types.Error!void {
        if (input.len > sink.bytes.len - sink.used) return error.ResponseBodyTooLarge;
        @memcpy(sink.bytes[sink.used..][0..input.len], input);
        sink.used += input.len;
    }

    pub fn reserve(sink: *Sink, count: usize) types.Error![]u8 {
        if (count > sink.bytes.len - sink.used) return error.ResponseBodyTooLarge;
        const start = sink.used;
        sink.used += count;
        return sink.bytes[start..sink.used];
    }
};

pub fn writeString(
    sink: *Sink,
    input: []const u8,
    comptime html_safe: bool,
) types.Error!void {
    const remaining = sink.bytes.len - sink.used;
    if (remaining < 2 or input.len > remaining - 2) return error.ResponseBodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    try sink.writeByte('"');
    var clean_start: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const escape = escapeFor(input, index, html_safe) orelse continue;
        try sink.writeAll(input[clean_start..index]);
        try sink.writeAll(escape.bytes);
        index += escape.consumed - 1;
        clean_start = index + 1;
    }
    try sink.writeAll(input[clean_start..]);
    try sink.writeByte('"');
}

pub fn writeInteger(sink: *Sink, value: anytype) types.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    const U = std.meta.Int(.unsigned, info.bits);
    const negative = info.signedness == .signed and value < 0;
    const magnitude: U = if (negative)
        (~@as(U, @bitCast(value))) +% 1
    else
        @intCast(value);
    const sign_bytes = @intFromBool(negative);
    const remaining_capacity = sink.bytes.len - sink.used;
    if (remaining_capacity <= sign_bytes) return error.ResponseBodyTooLarge;
    var probe = magnitude;
    var digits: usize = 1;
    while (probe >= 10) : (digits += 1) {
        if (digits + sign_bytes == remaining_capacity) {
            return error.ResponseBodyTooLarge;
        }
        probe /= 10;
    }
    const output = try sink.reserve(digits + sign_bytes);
    var remaining = magnitude;
    var index = output.len;
    while (index > sign_bytes) {
        index -= 1;
        output[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    if (negative) output[0] = '-';
}

pub fn writeFloat(sink: *Sink, value: anytype) types.Error!void {
    if (!std.math.isFinite(value)) return error.NonFiniteFloat;
    var storage: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&storage, "{}", .{value}) catch {
        return error.InvalidNumber;
    };
    if (!types.validNumber(formatted)) return error.InvalidNumber;
    try sink.writeAll(formatted);
}

pub fn writeNumber(sink: *Sink, number: types.Number) types.Error!void {
    if (!types.validNumber(number.lexeme)) return error.InvalidNumber;
    try sink.writeAll(number.lexeme);
}

const Escape = struct {
    bytes: []const u8,
    consumed: usize = 1,
};

fn escapeFor(input: []const u8, index: usize, comptime html_safe: bool) ?Escape {
    const byte = input[index];
    return switch (byte) {
        '"' => .{ .bytes = "\\\"" },
        '\\' => .{ .bytes = "\\\\" },
        0x08 => .{ .bytes = "\\b" },
        0x0c => .{ .bytes = "\\f" },
        '\n' => .{ .bytes = "\\n" },
        '\r' => .{ .bytes = "\\r" },
        '\t' => .{ .bytes = "\\t" },
        0x00...0x07, 0x0b, 0x0e...0x1f => controlEscape(byte),
        '<' => if (html_safe) .{ .bytes = "\\u003c" } else null,
        '>' => if (html_safe) .{ .bytes = "\\u003e" } else null,
        '&' => if (html_safe) .{ .bytes = "\\u0026" } else null,
        '\'' => if (html_safe) .{ .bytes = "\\u0027" } else null,
        0xe2 => if (html_safe and index + 2 < input.len and input[index + 1] == 0x80)
            switch (input[index + 2]) {
                0xa8 => .{ .bytes = "\\u2028", .consumed = 3 },
                0xa9 => .{ .bytes = "\\u2029", .consumed = 3 },
                else => null,
            }
        else
            null,
        else => null,
    };
}

fn controlEscape(byte: u8) Escape {
    return .{ .bytes = &control_escapes[byte] };
}

const control_escapes = makeControlEscapes();

fn makeControlEscapes() [32][6]u8 {
    const alphabet = "0123456789abcdef";
    var result: [32][6]u8 = undefined;
    for (&result, 0..) |*escape, value| {
        escape.* = .{
            '\\',
            'u',
            '0',
            '0',
            alphabet[value >> 4],
            alphabet[value & 0x0f],
        };
    }
    return result;
}

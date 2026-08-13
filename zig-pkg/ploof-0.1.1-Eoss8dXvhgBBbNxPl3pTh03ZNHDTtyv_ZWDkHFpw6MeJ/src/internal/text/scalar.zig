const std = @import("std");

pub const TextDecodeError = error{
    InvalidSyntax,
    InvalidRepresentation,
    OutOfRange,
};

pub const Error = error{
    InvalidText,
    InvalidValue,
};

pub const HookIssue = enum(u8) {
    not_function,
    wrong_signature,
};

pub fn parse(comptime T: type, input: []const u8) Error!T {
    if (T == []const u8) {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidText;
        return input;
    }
    if (std.meta.hasFn(T, "parseText")) {
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidText;
        return T.parseText(input) catch return error.InvalidValue;
    }
    return switch (@typeInfo(T)) {
        .optional => |optional| try parse(optional.child, input),
        .int => parseInteger(T, input),
        .float => parseFloat(T, input),
        .bool => parseBoolean(input),
        .@"enum" => std.meta.stringToEnum(T, input) orelse error.InvalidValue,
        else => unreachable,
    };
}

pub fn hookIssue(comptime T: type) ?HookIssue {
    if (!hasHook(T)) return null;
    if (!std.meta.hasFn(T, "parseText")) return .not_function;
    const expected = fn ([]const u8) TextDecodeError!T;
    if (@TypeOf(T.parseText) != expected) return .wrong_signature;
    return null;
}

pub fn hasHook(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "parseText"),
        else => false,
    };
}

fn parseInteger(comptime T: type, input: []const u8) Error!T {
    if (input.len == 0) return error.InvalidValue;
    const integer = @typeInfo(T).int;
    var index: usize = 0;
    if (input[0] == '-') {
        if (integer.signedness != .signed or input.len == 1) return error.InvalidValue;
        index = 1;
    }
    for (input[index..]) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidValue;
    }
    return std.fmt.parseInt(T, input, 10) catch error.InvalidValue;
}

fn parseFloat(comptime T: type, input: []const u8) Error!T {
    if (!validFloatSyntax(input)) return error.InvalidValue;
    const value = std.fmt.parseFloat(T, input) catch return error.InvalidValue;
    if (!std.math.isFinite(value)) return error.InvalidValue;
    return value;
}

fn validFloatSyntax(input: []const u8) bool {
    if (input.len == 0) return false;
    var index: usize = @intFromBool(input[0] == '-');
    if (index == input.len) return false;
    var digits: usize = 0;
    while (index < input.len and isDigit(input[index])) : (index += 1) digits += 1;
    if (index < input.len and input[index] == '.') {
        index += 1;
        while (index < input.len and isDigit(input[index])) : (index += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (index < input.len and (input[index] == 'e' or input[index] == 'E')) {
        index += 1;
        if (index < input.len and (input[index] == '+' or input[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < input.len and isDigit(input[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == input.len;
}

fn parseBoolean(input: []const u8) Error!bool {
    if (std.mem.eql(u8, input, "true") or std.mem.eql(u8, input, "1")) return true;
    if (std.mem.eql(u8, input, "false") or std.mem.eql(u8, input, "0")) return false;
    return error.InvalidValue;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

test "strict scalar spellings remain shared and allocation-free" {
    const Choice = enum { alpha, beta };
    try std.testing.expectEqual(@as(i16, -12), try parse(i16, "-12"));
    try std.testing.expectEqual(@as(?u8, 7), try parse(?u8, "7"));
    try std.testing.expectEqual(@as(f32, 125), try parse(f32, "1.25e2"));
    try std.testing.expectEqual(true, try parse(bool, "1"));
    try std.testing.expectEqual(Choice.beta, try parse(Choice, "beta"));
    try std.testing.expectError(error.InvalidValue, parse(u8, "+1"));
    try std.testing.expectError(error.InvalidValue, parse(f32, "nan"));
    try std.testing.expectError(error.InvalidValue, parse(bool, "yes"));
    try std.testing.expectError(error.InvalidText, parse([]const u8, "\xff"));
}

test {
    std.testing.refAllDecls(@This());
}

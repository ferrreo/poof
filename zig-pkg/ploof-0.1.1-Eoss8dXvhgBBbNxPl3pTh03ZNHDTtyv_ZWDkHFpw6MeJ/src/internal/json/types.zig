const std = @import("std");

pub const depth_hard_max: u16 = 256;
pub const hook_depth_hard_max: u16 = 64;
pub const standard_encoded_bytes_max: usize = 1024 * 1024;

pub const Whitespace = enum(u8) {
    minified,
    indent_2,
};

pub const Options = struct {
    encoded_bytes_max: usize = standard_encoded_bytes_max,
    max_depth: u16 = 64,
    whitespace: Whitespace = .minified,
    html_safe: bool = false,

    pub fn validate(comptime options: Options) Options {
        if (options.encoded_bytes_max == 0) {
            @compileError("PLOOF-E3201 JSON encoded byte limit must be nonzero");
        }
        if (options.max_depth == 0) {
            @compileError("PLOOF-E3202 JSON depth limit must be nonzero");
        }
        if (options.max_depth > depth_hard_max) {
            @compileError("PLOOF-E3203 JSON depth limit exceeds 256");
        }
        return options;
    }
};

pub const standard_options = Options.validate(.{});

pub const Error = error{
    CircularReference,
    DuplicateField,
    InvalidNumber,
    InvalidUtf8,
    MalformedCustomJson,
    MaxDepthExceeded,
    NonFiniteFloat,
    ResponseBodyTooLarge,
    UnknownEnumTag,
};

pub const UnknownFields = enum(u8) {
    ignore,
    reject,
};

/// Closed error set available to custom `jsonParse` hooks.
pub const ParseError = error{
    CountOverflow,
    DepthLimitExceeded,
    DuplicateName,
    InvalidDepthLimit,
    InvalidNumber,
    InvalidValue,
    LengthMismatch,
    MalformedCustomJson,
    MissingField,
    Overflow,
    PlanMismatch,
    ScannerCapacity,
    Syntax,
    TypeMismatch,
    UnexpectedEnd,
    UnknownEnumTag,
    UnknownField,
    WorkspaceTooSmall,
};

pub const ValueKind = enum(u8) {
    null,
    boolean,
    number,
    string,
    array,
    object,
};

pub const NumberError = error{InvalidNumber};
pub const NumberConversionError = error{
    InvalidNumber,
    Overflow,
};

pub const Number = struct {
    lexeme: []const u8,

    pub fn init(lexeme: []const u8) NumberError!Number {
        if (!validNumber(lexeme)) return error.InvalidNumber;
        return .{ .lexeme = lexeme };
    }

    pub fn bytes(number: Number) []const u8 {
        return number.lexeme;
    }

    pub fn asInt(number: Number, comptime T: type) NumberConversionError!T {
        if (@typeInfo(T) != .int) @compileError("JSON integer accessor requires an integer type");
        if (!validNumber(number.lexeme)) return error.InvalidNumber;
        return convertInteger(number.lexeme, T);
    }

    pub fn asFloat(number: Number, comptime T: type) NumberConversionError!T {
        if (@typeInfo(T) != .float) @compileError("JSON float accessor requires a float type");
        if (!validNumber(number.lexeme)) return error.InvalidNumber;
        const value = std.fmt.parseFloat(T, number.lexeme) catch return error.InvalidNumber;
        if (!std.math.isFinite(value)) return error.Overflow;
        return value;
    }
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: Number,
    string: []const u8,
    array: []const Value,
    object: []const Member,

    pub fn get(value: *const Value, name: []const u8) error{
        WrongType,
        MissingField,
    }!*const Value {
        const members = switch (value.*) {
            .object => |members| members,
            else => return error.WrongType,
        };
        for (members) |*member| {
            if (std.mem.eql(u8, member.name, name)) return &member.value;
        }
        return error.MissingField;
    }
};

pub const Member = struct {
    name: []const u8,
    value: Value,
};

pub fn validNumber(input: []const u8) bool {
    if (input.len == 0) return false;
    var index: usize = 0;
    if (input[index] == '-') {
        index += 1;
        if (index == input.len) return false;
    }
    if (input[index] == '0') {
        index += 1;
        if (index < input.len and isDigit(input[index])) return false;
    } else {
        if (input[index] < '1' or input[index] > '9') return false;
        index += 1;
        while (index < input.len and isDigit(input[index])) index += 1;
    }
    if (index < input.len and input[index] == '.') {
        index += 1;
        const start = index;
        while (index < input.len and isDigit(input[index])) index += 1;
        if (index == start) return false;
    }
    if (index < input.len and (input[index] == 'e' or input[index] == 'E')) {
        index += 1;
        if (index < input.len and (input[index] == '+' or input[index] == '-')) index += 1;
        const start = index;
        while (index < input.len and isDigit(input[index])) index += 1;
        if (index == start) return false;
    }
    return index == input.len;
}

pub const FrameworkEncodeError = Error;

pub fn DeclaredEncodeError(comptime T: type) type {
    return selectedErrors(T, .{}, .declared);
}

pub fn CustomEncodeError(comptime T: type) type {
    return selectedErrors(T, .{}, .custom);
}

pub fn EncodeError(comptime T: type) type {
    return FrameworkEncodeError || CustomEncodeError(T);
}

pub fn validateHook(comptime T: type) void {
    const function = @TypeOf(@field(T, "jsonStringify"));
    const info = switch (@typeInfo(function)) {
        .@"fn" => |info| info,
        else => @compileError("PLOOF-E3210 jsonStringify must be a function"),
    };
    if (info.params.len != 2) {
        @compileError("PLOOF-E3211 jsonStringify requires self and an anytype writer");
    }
    const SelfParameter = info.params[0].type orelse {
        @compileError("PLOOF-E3212 jsonStringify self must be concrete");
    };
    if (!validHookSelf(T, SelfParameter) or info.params[1].type != null) {
        @compileError("PLOOF-E3213 invalid jsonStringify parameters");
    }
    const Return = info.return_type orelse {
        @compileError("PLOOF-E3214 jsonStringify requires an explicit finite error union");
    };
    const error_union = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union,
        else => @compileError("PLOOF-E3215 jsonStringify must return an error union"),
    };
    if (error_union.payload != void) {
        @compileError("PLOOF-E3216 jsonStringify must return void");
    }
    if (@typeInfo(error_union.error_set).error_set == null) {
        @compileError("PLOOF-E3217 jsonStringify error set must be finite");
    }
    const ApplicationError = jsonApplicationError(T);
    if (errorSetsOverlap(ApplicationError, FrameworkEncodeError)) {
        @compileError("PLOOF-E3227 JsonApplicationError collides with json.Error");
    }
    if (error_union.error_set != (FrameworkEncodeError || ApplicationError)) {
        @compileError(
            "PLOOF-E3228 jsonStringify must return exactly " ++
                "json.Error || JsonApplicationError",
        );
    }
}

const ErrorSelection = enum(u1) { declared, custom };

fn selectedErrors(
    comptime T: type,
    comptime seen: anytype,
    comptime selection: ErrorSelection,
) type {
    inline for (seen) |Seen| if (T == Seen) return error{};
    if (T == Value or T == Number) return error{};
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        .optional => |info| return selectedErrors(info.child, next, selection),
        .array => |info| return selectedErrors(info.child, next, selection),
        .vector => |info| return selectedErrors(info.child, next, selection),
        .pointer => |info| return selectedErrors(info.child, next, selection),
        .@"enum", .@"union", .@"struct" => {
            if (std.meta.hasFn(T, "jsonStringify")) {
                validateHook(T);
                return switch (selection) {
                    .declared => hookError(T),
                    .custom => jsonApplicationError(T),
                };
            }
        },
        else => return error{},
    }
    var result: type = error{};
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            result = result || selectedErrors(field.type, next, selection);
        },
        .@"union" => |info| inline for (info.fields) |field| {
            result = result || selectedErrors(field.type, next, selection);
        },
        else => {},
    }
    return result;
}

fn jsonApplicationError(comptime T: type) type {
    if (!@hasDecl(T, "JsonApplicationError")) return error{};
    const ApplicationError = @field(T, "JsonApplicationError");
    if (@TypeOf(ApplicationError) != type) {
        @compileError("PLOOF-E3229 JsonApplicationError must be a finite error set");
    }
    if (@typeInfo(ApplicationError) != .error_set or
        @typeInfo(ApplicationError).error_set == null)
    {
        @compileError("PLOOF-E3229 JsonApplicationError must be a finite error set");
    }
    return ApplicationError;
}

fn hookError(comptime T: type) type {
    const Return = @typeInfo(@TypeOf(@field(T, "jsonStringify"))).@"fn".return_type.?;
    return @typeInfo(Return).error_union.error_set;
}

fn errorSetsOverlap(comptime Left: type, comptime Right: type) bool {
    const left = @typeInfo(Left).error_set orelse unreachable;
    const right = @typeInfo(Right).error_set orelse unreachable;
    inline for (left) |candidate| {
        inline for (right) |reserved| {
            if (std.mem.eql(u8, candidate.name, reserved.name)) return true;
        }
    }
    return false;
}

fn validHookSelf(comptime T: type, comptime Parameter: type) bool {
    if (Parameter == T) return true;
    return switch (@typeInfo(Parameter)) {
        .pointer => |pointer| pointer.size == .one and pointer.child == T,
        else => false,
    };
}

const NumberParts = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
    exponent_negative: bool,
    exponent: []const u8,

    fn digits(parts: NumberParts) usize {
        return parts.integer.len + parts.fraction.len;
    }

    fn digit(parts: NumberParts, index: usize) u8 {
        if (index < parts.integer.len) return parts.integer[index] - '0';
        return parts.fraction[index - parts.integer.len] - '0';
    }
};

const IntegralScale = union(enum) {
    append: usize,
    remove: usize,
    positive_huge,
    negative_huge,
};

fn convertInteger(input: []const u8, comptime T: type) NumberConversionError!T {
    const parts = splitNumber(input);
    var nonzero = false;
    for (0..parts.digits()) |index| nonzero = nonzero or parts.digit(index) != 0;
    if (!nonzero) return 0;
    const scale = integralScale(parts);
    const remove = switch (scale) {
        .remove => |count| count,
        .negative_huge => return error.InvalidNumber,
        .positive_huge => return error.Overflow,
        .append => 0,
    };
    if (remove >= parts.digits()) return error.InvalidNumber;
    const kept = parts.digits() - remove;
    for (kept..parts.digits()) |index| {
        if (parts.digit(index) != 0) return error.InvalidNumber;
    }
    const append = switch (scale) {
        .append => |count| count,
        else => 0,
    };
    return accumulateInteger(parts, kept, append, T);
}

fn splitNumber(input: []const u8) NumberParts {
    const negative = input[0] == '-';
    const start: usize = @intFromBool(negative);
    const exponent_start = std.mem.indexOfAnyPos(u8, input, start, "eE") orelse input.len;
    const decimal = std.mem.indexOfScalarPos(u8, input, start, '.') orelse exponent_start;
    const fraction = if (decimal < exponent_start) input[decimal + 1 .. exponent_start] else "";
    var exponent_digits = input.len;
    var exponent_negative = false;
    if (exponent_start < input.len) {
        exponent_digits = exponent_start + 1;
        if (input[exponent_digits] == '+' or input[exponent_digits] == '-') {
            exponent_negative = input[exponent_digits] == '-';
            exponent_digits += 1;
        }
    }
    return .{
        .negative = negative,
        .integer = input[start..decimal],
        .fraction = fraction,
        .exponent_negative = exponent_negative,
        .exponent = input[exponent_digits..],
    };
}

fn integralScale(parts: NumberParts) IntegralScale {
    const magnitude = exponentMagnitude(parts.exponent) orelse {
        return if (parts.exponent_negative) .negative_huge else .positive_huge;
    };
    if (parts.exponent_negative) {
        if (magnitude > std.math.maxInt(usize) - parts.fraction.len) {
            return .negative_huge;
        }
        return .{ .remove = parts.fraction.len + magnitude };
    }
    if (magnitude >= parts.fraction.len) {
        return .{ .append = magnitude - parts.fraction.len };
    }
    return .{ .remove = parts.fraction.len - magnitude };
}

fn exponentMagnitude(input: []const u8) ?usize {
    var result: usize = 0;
    for (input) |byte| {
        const digit = byte - '0';
        const converted: usize = digit;
        if (result > (std.math.maxInt(usize) - converted) / 10) return null;
        result = result * 10 + converted;
    }
    return result;
}

fn accumulateInteger(
    parts: NumberParts,
    kept: usize,
    append: usize,
    comptime T: type,
) NumberConversionError!T {
    const info = @typeInfo(T).int;
    if (info.bits == 0) return error.Overflow;
    const U = std.meta.Int(.unsigned, info.bits);
    if (parts.negative and info.signedness == .unsigned) return error.Overflow;
    const positive_limit: U = @intCast(std.math.maxInt(T));
    const limit: U = switch (info.signedness) {
        .signed => if (parts.negative) positive_limit + 1 else positive_limit,
        .unsigned => positive_limit,
    };
    var result: U = 0;
    for (0..kept) |index| {
        result = try appendDigit(U, result, parts.digit(index), limit);
    }
    for (0..append) |_| result = try appendDigit(U, result, 0, limit);
    if (comptime info.signedness == .unsigned) return @intCast(result);
    if (!parts.negative) return @intCast(result);
    if (result == positive_limit + 1) return std.math.minInt(T);
    return -@as(T, @intCast(result));
}

fn appendDigit(comptime U: type, value: U, digit: u8, limit: U) error{Overflow}!U {
    if (@bitSizeOf(U) < 4 and digit > std.math.maxInt(U)) return error.Overflow;
    const converted: U = @intCast(digit);
    if (converted > limit or value > (limit - converted) / 10) return error.Overflow;
    return value * 10 + converted;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

test "number grammar is strict" {
    for ([_][]const u8{ "0", "-0", "17", "1.25", "3e8", "-2.5E-3" }) |input| {
        try std.testing.expect(validNumber(input));
    }
    for ([_][]const u8{ "", "+1", "01", "1.", ".1", "1e", "--1", "1 2" }) |input| {
        try std.testing.expect(!validNumber(input));
    }
}

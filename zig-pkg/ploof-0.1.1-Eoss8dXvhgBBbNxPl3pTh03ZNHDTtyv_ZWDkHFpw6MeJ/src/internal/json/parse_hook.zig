const std = @import("std");
const types = @import("types.zig");

pub fn has(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum", .@"struct", .@"union" => @hasDecl(T, "jsonParse"),
        else => false,
    };
}

pub fn validate(comptime T: type) void {
    const Function = @TypeOf(@field(T, "jsonParse"));
    const info = switch (@typeInfo(Function)) {
        .@"fn" => |info| info,
        else => @compileError("PLOOF-E3218 jsonParse must be fn (anytype) json.ParseError!Self"),
    };
    if (info.params.len != 1 or
        info.params[0].type != null or
        comptimeParameter(Function))
    {
        @compileError("PLOOF-E3218 jsonParse must be fn (anytype) json.ParseError!Self");
    }
    const Return = info.return_type orelse {
        @compileError("PLOOF-E3219 jsonParse must return exactly json.ParseError!Self");
    };
    const result = switch (@typeInfo(Return)) {
        .error_union => |result| result,
        else => @compileError("PLOOF-E3219 jsonParse must return exactly json.ParseError!Self"),
    };
    if (result.payload != T or result.error_set != types.ParseError) {
        @compileError("PLOOF-E3219 jsonParse must return exactly json.ParseError!Self");
    }
}

pub fn validateType(comptime T: type) void {
    validateTypeInner(T, .{});
}

fn validateTypeInner(comptime T: type, comptime seen: anytype) void {
    inline for (seen) |Seen| if (T == Seen) return;
    if (T == types.Value or T == types.Number) return;
    if (has(T)) {
        validate(T);
        return;
    }
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        .optional => |info| validateTypeInner(info.child, next),
        .array => |info| validateTypeInner(info.child, next),
        .vector => |info| validateTypeInner(info.child, next),
        .pointer => |info| validateTypeInner(info.child, next),
        .@"struct" => |info| inline for (info.fields) |field| {
            validateTypeInner(field.type, next);
        },
        .@"union" => |info| inline for (info.fields) |field| {
            validateTypeInner(field.type, next);
        },
        else => {},
    }
}

fn comptimeParameter(comptime Function: type) bool {
    // Zig 0.16 Fn.Param erases comptime; @typeName is the only exposed distinction.
    return std.mem.startsWith(u8, @typeName(Function), "fn (comptime ");
}

test {
    std.testing.refAllDecls(@This());
}

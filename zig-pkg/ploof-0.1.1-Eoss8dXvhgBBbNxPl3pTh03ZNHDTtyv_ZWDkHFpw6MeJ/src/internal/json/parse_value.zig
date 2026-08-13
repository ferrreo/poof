const std = @import("std");
const hook = @import("parse_hook.zig");
const schema = @import("schema.zig");
const storage = @import("decode_storage.zig");
const types = @import("types.zig");

pub const Error = types.ParseError;

const Context = struct {
    arena: *storage.Arena,
    unknown_fields: types.UnknownFields,
    depth_max: u16,
    hook_depth: u16 = 0,
    conversion_depth: u16 = 0,
    states: [types.hook_depth_hard_max]ParserState = undefined,
    parsers: [types.hook_depth_hard_max]Parser = undefined,
};

pub fn parseCustom(
    comptime T: type,
    value: *const types.Value,
    arena: *storage.Arena,
    unknown_fields: types.UnknownFields,
    depth_max: u16,
) Error!T {
    var context = Context{
        .arena = arena,
        .unknown_fields = unknown_fields,
        .depth_max = @min(depth_max, types.hook_depth_hard_max),
    };
    return invoke(T, value, &context);
}

fn invoke(comptime T: type, value: *const types.Value, context: *Context) Error!T {
    comptime hook.validate(T);
    if (context.hook_depth >= context.depth_max) return error.DepthLimitExceeded;
    const index = context.hook_depth;
    context.hook_depth += 1;
    defer context.hook_depth -= 1;

    const state = &context.states[index];
    state.* = .{};
    const parser = &context.parsers[index];
    parser.* = .{ .context = context, .value = value, .state = state };
    const result = T.jsonParse(parser) catch |problem| {
        return normalizeHookFailure(problem, state.parser_error);
    };
    try parser.finish();
    return result;
}

const ParserState = struct {
    consumed: bool = false,
    failed: bool = false,
    parser_error: ?Error = null,
};

pub const Parser = struct {
    context: *Context,
    value: *const types.Value,
    state: *ParserState,

    pub inline fn parse(self: *Parser, comptime T: type) Error!T {
        try self.consume();
        const result = if (comptime hook.has(T))
            invoke(T, self.value, self.context)
        else
            convert(T, self.value, self.context);
        return result catch |problem| {
            return self.fail(problem);
        };
    }

    pub fn cursor(self: *Parser) Error!Cursor {
        try self.consume();
        return .{ .parser = self, .value = self.value };
    }

    pub fn array(self: *Parser) Error!ArrayCursor {
        return (try self.cursor()).array();
    }

    pub fn object(self: *Parser) Error!ObjectCursor {
        return (try self.cursor()).object();
    }

    fn consume(self: *Parser) Error!void {
        if (self.state.consumed) return self.fail(error.MalformedCustomJson);
        self.state.consumed = true;
    }

    fn fail(self: *Parser, problem: Error) Error {
        self.state.failed = true;
        self.state.parser_error = problem;
        return problem;
    }

    fn finish(self: Parser) Error!void {
        if (!self.state.consumed or self.state.failed) return error.MalformedCustomJson;
    }
};

pub const Cursor = struct {
    parser: *Parser,
    value: *const types.Value,

    pub fn kind(self: Cursor) types.ValueKind {
        return switch (self.value.*) {
            .null => .null,
            .boolean => .boolean,
            .number => .number,
            .string => .string,
            .array => .array,
            .object => .object,
        };
    }

    pub inline fn parse(self: Cursor, comptime T: type) Error!T {
        const result = if (comptime hook.has(T))
            invoke(T, self.value, self.parser.context)
        else
            convert(T, self.value, self.parser.context);
        return result catch |problem| {
            return self.parser.fail(problem);
        };
    }

    pub fn boolean(self: Cursor) Error!bool {
        return switch (self.value.*) {
            .boolean => |value| value,
            else => self.fail(error.TypeMismatch),
        };
    }

    pub fn number(self: Cursor) Error!types.Number {
        return switch (self.value.*) {
            .number => |value| value,
            else => self.fail(error.TypeMismatch),
        };
    }

    pub fn string(self: Cursor) Error![]const u8 {
        return switch (self.value.*) {
            .string => |value| value,
            else => self.fail(error.TypeMismatch),
        };
    }

    pub fn array(self: Cursor) Error!ArrayCursor {
        const values = switch (self.value.*) {
            .array => |values| values,
            else => return self.fail(error.TypeMismatch),
        };
        return .{ .parser = self.parser, .values = values };
    }

    pub fn object(self: Cursor) Error!ObjectCursor {
        const members = switch (self.value.*) {
            .object => |members| members,
            else => return self.fail(error.TypeMismatch),
        };
        return .{ .parser = self.parser, .members = members };
    }

    fn fail(self: Cursor, problem: Error) Error {
        return self.parser.fail(problem);
    }
};

fn normalizeHookFailure(problem: Error, parser_error: ?Error) Error {
    if (parser_error) |origin| {
        if (origin == problem) return problem;
    }
    return switch (problem) {
        error.CountOverflow,
        error.InvalidDepthLimit,
        error.PlanMismatch,
        error.ScannerCapacity,
        error.WorkspaceTooSmall,
        => error.InvalidValue,
        else => problem,
    };
}

pub const ArrayCursor = struct {
    parser: *Parser,
    values: []const types.Value,
    index: usize = 0,

    pub fn len(self: ArrayCursor) usize {
        return self.values.len;
    }

    pub fn at(self: ArrayCursor, index: usize) ?Cursor {
        if (index >= self.values.len) return null;
        return .{ .parser = self.parser, .value = &self.values[index] };
    }

    pub fn next(self: *ArrayCursor) ?Cursor {
        const result = self.at(self.index) orelse return null;
        self.index += 1;
        return result;
    }
};

pub const ObjectCursor = struct {
    parser: *Parser,
    members: []const types.Member,
    index: usize = 0,

    pub fn len(self: ObjectCursor) usize {
        return self.members.len;
    }

    pub fn get(self: ObjectCursor, name: []const u8) ?Cursor {
        for (self.members) |*member| {
            if (std.mem.eql(u8, member.name, name)) {
                return .{ .parser = self.parser, .value = &member.value };
            }
        }
        return null;
    }

    pub fn next(self: *ObjectCursor) ?MemberCursor {
        if (self.index >= self.members.len) return null;
        defer self.index += 1;
        return .{ .parser = self.parser, .member = &self.members[self.index] };
    }
};

pub const MemberCursor = struct {
    parser: *Parser,
    member: *const types.Member,

    pub fn name(self: MemberCursor) []const u8 {
        return self.member.name;
    }

    pub fn value(self: MemberCursor) Cursor {
        return .{ .parser = self.parser, .value = &self.member.value };
    }
};

fn convert(comptime T: type, value: *const types.Value, context: *Context) Error!T {
    if (context.conversion_depth >= context.depth_max) return error.DepthLimitExceeded;
    context.conversion_depth += 1;
    defer context.conversion_depth -= 1;
    if (comptime hook.has(T)) return invoke(T, value, context);
    if (T == types.Value) return value.*;
    if (T == types.Number) return expectNumber(value);
    return switch (@typeInfo(T)) {
        .bool => expectBool(value),
        .int => convertInt(T, value),
        .float => convertFloat(T, value),
        .optional => |info| convertOptional(T, info.child, value, context),
        .array => |info| convertArray(T, info.child, info.len, value, context),
        .vector => |info| convertVector(T, info.child, info.len, value, context),
        .pointer => |info| convertPointer(T, info, value, context),
        .@"enum" => convertEnum(T, value),
        .@"struct" => |info| if (info.is_tuple)
            convertTuple(T, info.fields, value, context)
        else
            convertStruct(T, info.fields, value, context),
        .@"union" => |info| convertUnion(T, info, value, context),
        .void => convertVoid(value),
        else => @compileError("unsupported JSON decode type '" ++ @typeName(T) ++ "'"),
    };
}

fn expectBool(value: *const types.Value) Error!bool {
    return switch (value.*) {
        .boolean => |result| result,
        else => error.TypeMismatch,
    };
}

fn expectNumber(value: *const types.Value) Error!types.Number {
    return switch (value.*) {
        .number => |result| result,
        else => error.TypeMismatch,
    };
}

fn convertInt(comptime T: type, value: *const types.Value) Error!T {
    return (try expectNumber(value)).asInt(T) catch |problem| return problem;
}

fn convertFloat(comptime T: type, value: *const types.Value) Error!T {
    return (try expectNumber(value)).asFloat(T) catch |problem| return problem;
}

fn convertOptional(
    comptime T: type,
    comptime Child: type,
    value: *const types.Value,
    context: *Context,
) Error!T {
    if (value.* == .null) return null;
    return try convert(Child, value, context);
}

fn convertArray(
    comptime T: type,
    comptime Child: type,
    comptime length: usize,
    value: *const types.Value,
    context: *Context,
) Error!T {
    if (Child == u8) {
        const bytes = try expectString(value);
        if (bytes.len != length) return error.LengthMismatch;
        var result: T = undefined;
        @memcpy(&result, bytes);
        return result;
    }
    const values = try expectArray(value);
    if (values.len != length) return error.LengthMismatch;
    var result: T = undefined;
    inline for (0..length) |index| result[index] = try convert(Child, &values[index], context);
    return result;
}

fn convertVector(
    comptime T: type,
    comptime Child: type,
    comptime length: usize,
    value: *const types.Value,
    context: *Context,
) Error!T {
    const values = try expectArray(value);
    if (values.len != length) return error.LengthMismatch;
    var result: T = undefined;
    inline for (0..length) |index| result[index] = try convert(Child, &values[index], context);
    return result;
}

fn convertPointer(
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    value: *const types.Value,
    context: *Context,
) Error!T {
    if (info.sentinel_ptr != null) {
        @compileError("sentinel pointers are unsupported by JSON decode");
    }
    return switch (info.size) {
        .one => convertOnePointer(T, info.child, value, context),
        .slice => if (info.child == u8)
            convertByteSlice(T, info.is_const, value, context)
        else
            convertSlice(T, info.child, value, context),
        .many, .c => @compileError("many and C pointers are unsupported by JSON decode"),
    };
}

fn convertOnePointer(
    comptime T: type,
    comptime Child: type,
    value: *const types.Value,
    context: *Context,
) Error!T {
    const result = try context.arena.allocate(Child, 1);
    result[0] = try convert(Child, value, context);
    return &result[0];
}

fn convertByteSlice(
    comptime T: type,
    comptime is_const: bool,
    value: *const types.Value,
    context: *Context,
) Error!T {
    const bytes = try expectString(value);
    if (is_const) return bytes;
    const result = try context.arena.allocate(u8, bytes.len);
    @memcpy(result, bytes);
    return result;
}

fn convertSlice(
    comptime T: type,
    comptime Child: type,
    value: *const types.Value,
    context: *Context,
) Error!T {
    const values = try expectArray(value);
    const result = try context.arena.allocate(Child, values.len);
    for (result, values) |*item, *source| item.* = try convert(Child, source, context);
    return result;
}

fn convertEnum(comptime T: type, value: *const types.Value) Error!T {
    const name = try expectString(value);
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(T, field.name);
    }
    return error.UnknownEnumTag;
}

fn convertTuple(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    value: *const types.Value,
    context: *Context,
) Error!T {
    const values = try expectArray(value);
    if (values.len != fields.len) return error.LengthMismatch;
    var result: T = undefined;
    inline for (fields, 0..) |field, index| {
        @field(result, field.name) = try convert(field.type, &values[index], context);
    }
    return result;
}

fn convertStruct(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    value: *const types.Value,
    context: *Context,
) Error!T {
    comptime schema.validate(T);
    const members = try expectObject(value);
    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;
    inline for (fields, 0..) |field, index| if (field.type == void) {
        @field(result, field.name) = {};
        seen[index] = true;
    };
    for (members) |*member| {
        var matched = false;
        inline for (fields, 0..) |field, index| if (!matched and field.type != void and
            std.mem.eql(u8, member.name, comptime schema.wireName(T, field.name)))
        {
            if (seen[index]) return error.DuplicateName;
            @field(result, field.name) = try convert(field.type, &member.value, context);
            seen[index] = true;
            matched = true;
        };
        if (!matched and context.unknown_fields == .reject) return error.UnknownField;
    }
    inline for (fields, 0..) |field, index| if (!seen[index]) {
        if (field.default_value_ptr == null) return error.MissingField;
        @field(result, field.name) = field.defaultValue().?;
    };
    return result;
}

fn convertUnion(
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    value: *const types.Value,
    context: *Context,
) Error!T {
    if (info.tag_type == null) @compileError("untagged unions cannot be decoded from JSON");
    const members = try expectObject(value);
    if (members.len != 1) return error.LengthMismatch;
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, members[0].name, field.name)) {
            return @unionInit(T, field.name, try convert(field.type, &members[0].value, context));
        }
    }
    return error.UnknownEnumTag;
}

fn convertVoid(value: *const types.Value) Error!void {
    const members = try expectObject(value);
    if (members.len != 0) return error.LengthMismatch;
}

fn expectString(value: *const types.Value) Error![]const u8 {
    return switch (value.*) {
        .string => |result| result,
        else => error.TypeMismatch,
    };
}

fn expectArray(value: *const types.Value) Error![]const types.Value {
    return switch (value.*) {
        .array => |result| result,
        else => error.TypeMismatch,
    };
}

fn expectObject(value: *const types.Value) Error![]const types.Member {
    return switch (value.*) {
        .object => |result| result,
        else => error.TypeMismatch,
    };
}

test {
    std.testing.refAllDecls(@This());
}

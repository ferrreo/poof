const std = @import("std");
const body = @import("../../body.zig");
const dynamic_decode = @import("decode_dynamic.zig");
const error_map = @import("decode_errors.zig");
const decode_token = @import("decode_token.zig");
const hook = @import("parse_hook.zig");
const schema = @import("schema.zig");
const plan = @import("decode_plan.zig");
const parse_value = @import("parse_value.zig");
const storage = @import("decode_storage.zig");
const token_source = @import("token_source.zig");
const typed_decode = @import("decode_typed.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const UnknownFields = types.UnknownFields;

pub const Options = struct {
    hash_key: [16]u8,
    depth_max: u16 = token_source.depth_standard_max,
    unknown_fields: UnknownFields = .ignore,
};

pub const Error = types.ParseError;
const mapPlanError = error_map.decodePlan;
const mapSourceError = error_map.source;
const mapStorageError = error_map.arena;
const mapValidationError = error_map.validation;
const expectToken = decode_token.expect;
const isString = decode_token.isString;
const Dynamic = dynamic_decode.Traversal(Decoder, Error);
const Typed = typed_decode.Traversal(
    Decoder,
    Error,
    token_source.RawToken,
    token_source.depth_hard_max,
);

pub fn Result(comptime T: type) type {
    return struct {
        value: *T,
        workspace_used: usize,
        workspace_required: usize,
        validation: validate.Result,
    };
}

pub fn decode(
    comptime T: type,
    input: body.Bytes,
    workspace: []align(validate.scratch_alignment) u8,
    options: Options,
) Error!Result(T) {
    const checked = validate.validate(input, workspace, .{
        .hash_key = options.hash_key,
        .depth_max = options.depth_max,
    }) catch |problem| return mapValidationError(problem);
    var arena = storage.Arena.init(workspace);
    const plans = plan.build(
        T,
        input,
        options.depth_max,
        &arena,
    ) catch |problem| return mapPlanError(problem);
    var decoder: Decoder = undefined;
    try decoder.init(input, &arena, plans, options);
    defer decoder.deinit();
    const root = try arena.allocate(T, 1);
    if (comptime hook.has(T))
        root[0] = try decoder.readCustom(T, try decoder.nextRaw())
    else if (comptime typed_decode.usesDirectTraversal(T))
        try decoder.readDirect(T, &root[0], try decoder.nextRaw())
    else
        try Typed.run(T, &decoder, &root[0]);
    try decoder.finish();
    return .{
        .value = &root[0],
        .workspace_used = arena.used,
        .workspace_required = @max(checked.duplicate_scratch_bytes, arena.peak),
        .validation = checked,
    };
}

pub fn decodeValue(
    input: body.Bytes,
    workspace: []align(validate.scratch_alignment) u8,
    options: Options,
) Error!Result(types.Value) {
    return decode(types.Value, input, workspace, options);
}

const Decoder = struct {
    source: token_source.Source,
    arena: *storage.Arena,
    plans: storage.Cursor,
    unknown_fields: UnknownFields,
    depth_max: u16,

    fn init(
        self: *Decoder,
        input: body.Bytes,
        arena: *storage.Arena,
        plans: []const storage.Plan,
        options: Options,
    ) Error!void {
        self.* = .{
            .source = undefined,
            .arena = arena,
            .plans = .{ .plans = plans },
            .unknown_fields = options.unknown_fields,
            .depth_max = options.depth_max,
        };
        self.source.init(input, options.depth_max) catch |problem| {
            return mapSourceError(problem);
        };
    }

    fn deinit(self: *Decoder) void {
        self.source.deinit();
    }

    fn finish(self: *Decoder) Error!void {
        switch (try self.nextRaw()) {
            .end_of_document => {},
            else => return error.Syntax,
        }
        try self.plans.finish();
    }

    pub fn typedDepthMax(self: *const Decoder) u16 {
        return self.depth_max;
    }

    pub fn typedNextRaw(self: *Decoder) Error!token_source.RawToken {
        return self.nextRaw();
    }

    pub fn typedString(self: *Decoder, token: token_source.RawToken) Error![]const u8 {
        return (try self.stringText(token)).bytes;
    }

    pub fn typedUnknown(self: *Decoder) Error!void {
        return self.unknownValue();
    }

    pub fn typedDecodeInto(
        self: *Decoder,
        comptime T: type,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        if (comptime hook.has(T)) {
            destination.* = try self.readCustom(T, token);
            return null;
        }
        if (T == types.Value) {
            destination.* = try Dynamic.read(self, token);
            return null;
        }
        if (T == types.Number) {
            destination.* = try self.readNumberValue(token, true);
            return null;
        }
        switch (@typeInfo(T)) {
            .bool => destination.* = try self.readBool(token),
            .int => destination.* = try self.readInt(T, token),
            .float => destination.* = try self.readFloat(T, token),
            .optional => |info| return self.beginOptional(info.child, destination, token),
            .array => |info| return self.beginArray(T, info, destination, token, machine),
            .vector => |info| return self.beginVector(T, info, destination, token, machine),
            .pointer => |info| return self.beginPointer(T, info, destination, token, machine),
            .@"enum" => destination.* = try self.readEnum(T, token),
            .@"struct" => |info| return if (info.is_tuple)
                self.beginTuple(T, info.fields, destination, token, machine)
            else
                self.beginStruct(T, info.fields, destination, token, machine),
            .@"union" => |info| return self.beginUnion(T, info, destination, token, machine),
            .void => try self.readVoid(token),
            else => @compileError("unsupported JSON decode type '" ++ @typeName(T) ++ "'"),
        }
        return null;
    }

    inline fn readDirect(
        self: *Decoder,
        comptime T: type,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        if (comptime hook.has(T)) {
            destination.* = try self.readCustom(T, token);
            return;
        }
        if (T == types.Value) {
            destination.* = try Dynamic.read(self, token);
            return;
        }
        if (T == types.Number) {
            destination.* = try self.readNumberValue(token, true);
            return;
        }
        switch (@typeInfo(T)) {
            .bool => destination.* = try self.readBool(token),
            .int => destination.* = try self.readInt(T, token),
            .float => destination.* = try self.readFloat(T, token),
            .optional => |info| try self.readOptionalDirect(info.child, destination, token),
            .array => |info| try self.readArrayDirect(T, info, destination, token),
            .vector => |info| try self.readVectorDirect(T, info, destination, token),
            .pointer => |info| try self.readPointerDirect(T, info, destination, token),
            .@"enum" => destination.* = try self.readEnum(T, token),
            .@"struct" => |info| if (info.is_tuple)
                try self.readTupleDirect(T, info.fields, destination, token)
            else
                try self.readStructDirect(T, info.fields, destination, token),
            .@"union" => |info| try self.readUnionDirect(T, info, destination, token),
            .void => try self.readVoid(token),
            else => @compileError("unsupported JSON decode type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn readOptionalDirect(
        self: *Decoder,
        comptime Child: type,
        destination: *?Child,
        token: token_source.RawToken,
    ) Error!void {
        if (token == .null) {
            destination.* = null;
            return;
        }
        destination.* = @as(Child, undefined);
        try @call(.always_inline, readDirect, .{ self, Child, &destination.*.?, token });
    }

    fn readArrayDirect(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Array,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        if (info.child == u8) {
            const text = try self.stringText(token);
            if (text.bytes.len != info.len) return error.LengthMismatch;
            @memcpy(destination, text.bytes);
            return;
        }
        try expectToken(token, .array_begin);
        for (0..info.len) |index| {
            const item = try self.nextRaw();
            if (item == .array_end) return error.LengthMismatch;
            try @call(.always_inline, readDirect, .{
                self,
                info.child,
                &destination.*[index],
                item,
            });
        }
        if (try self.nextRaw() != .array_end) return error.LengthMismatch;
    }

    fn readVectorDirect(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Vector,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        try expectToken(token, .array_begin);
        const values = try self.arena.allocate(info.child, info.len);
        for (values) |*value| {
            const item = try self.nextRaw();
            if (item == .array_end) return error.LengthMismatch;
            try @call(.always_inline, readDirect, .{ self, info.child, value, item });
        }
        if (try self.nextRaw() != .array_end) return error.LengthMismatch;
        inline for (0..info.len) |index| destination.*[index] = values[index];
    }

    fn readPointerDirect(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Pointer,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        if (info.sentinel_ptr != null) {
            @compileError("sentinel pointers are unsupported by JSON decode");
        }
        switch (info.size) {
            .one => {
                const value = try self.arena.allocate(info.child, 1);
                destination.* = &value[0];
                try @call(.always_inline, readDirect, .{
                    self,
                    info.child,
                    &value[0],
                    token,
                });
            },
            .slice => if (info.child == u8) {
                destination.* = try self.readByteSlice(T, info.is_const, token);
            } else {
                try expectToken(token, .array_begin);
                const length = try self.plans.take(.array);
                const values = try self.arena.allocate(info.child, length);
                destination.* = values;
                for (values) |*value| try @call(.always_inline, readDirect, .{
                    self,
                    info.child,
                    value,
                    try self.nextRaw(),
                });
                try expectToken(try self.nextRaw(), .array_end);
            },
            .many, .c => @compileError("many and C pointers are unsupported by JSON decode"),
        }
    }

    fn readTupleDirect(
        self: *Decoder,
        comptime T: type,
        comptime fields: []const std.builtin.Type.StructField,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        try expectToken(token, .array_begin);
        destination.* = undefined;
        inline for (fields) |field| {
            const item = try self.nextRaw();
            if (item == .array_end) return error.LengthMismatch;
            try @call(.always_inline, readDirect, .{
                self,
                field.type,
                &@field(destination.*, field.name),
                item,
            });
        }
        if (try self.nextRaw() != .array_end) return error.LengthMismatch;
    }

    fn readStructDirect(
        self: *Decoder,
        comptime T: type,
        comptime fields: []const std.builtin.Type.StructField,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        comptime schema.validate(T);
        try expectToken(token, .object_begin);
        destination.* = undefined;
        var required_remaining: usize = 0;
        inline for (fields) |field| if (field.type == void) {
            @field(destination.*, field.name) = {};
        } else if (field.default_value_ptr) |_| {
            @field(destination.*, field.name) = field.defaultValue().?;
        } else {
            required_remaining += 1;
        };
        while (true) {
            const key = try self.nextRaw();
            if (key == .object_end) {
                if (required_remaining != 0) return error.MissingField;
                return;
            }
            const name = (try self.stringText(key)).bytes;
            var matched = false;
            inline for (fields) |field| if (!matched and field.type != void and
                std.mem.eql(u8, name, comptime schema.wireName(T, field.name)))
            {
                try @call(.always_inline, readDirect, .{
                    self,
                    field.type,
                    &@field(destination.*, field.name),
                    try self.nextRaw(),
                });
                if (field.default_value_ptr == null) required_remaining -= 1;
                matched = true;
            };
            if (!matched) try self.unknownValue();
        }
    }

    fn readUnionDirect(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Union,
        destination: *T,
        token: token_source.RawToken,
    ) Error!void {
        if (info.tag_type == null) @compileError("untagged unions cannot be decoded from JSON");
        try expectToken(token, .object_begin);
        const key = try self.nextRaw();
        if (key == .object_end) return error.LengthMismatch;
        const name = (try self.stringText(key)).bytes;
        inline for (info.fields) |field| if (std.mem.eql(u8, name, field.name)) {
            destination.* = @unionInit(T, field.name, undefined);
            try @call(.always_inline, readDirect, .{
                self,
                field.type,
                &@field(destination.*, field.name),
                try self.nextRaw(),
            });
            try expectToken(try self.nextRaw(), .object_end);
            return;
        };
        return error.UnknownEnumTag;
    }

    fn readCustom(self: *Decoder, comptime T: type, token: token_source.RawToken) Error!T {
        const value = try Dynamic.read(self, token);
        return parse_value.parseCustom(
            T,
            &value,
            self.arena,
            self.unknown_fields,
            self.depth_max,
        );
    }

    fn readBool(_: *Decoder, token: token_source.RawToken) Error!bool {
        return switch (token) {
            .true => true,
            .false => false,
            else => return error.TypeMismatch,
        };
    }

    fn readInt(
        self: *Decoder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!T {
        const number = try self.readNumberValue(token, false);
        return number.asInt(T) catch |problem| switch (problem) {
            error.InvalidNumber => error.InvalidNumber,
            error.Overflow => error.Overflow,
        };
    }

    fn readFloat(
        self: *Decoder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!T {
        const number = try self.readNumberValue(token, false);
        return number.asFloat(T) catch |problem| switch (problem) {
            error.InvalidNumber => error.InvalidNumber,
            error.Overflow => error.Overflow,
        };
    }

    fn beginOptional(
        _: *Decoder,
        comptime Child: type,
        destination: *?Child,
        token: token_source.RawToken,
    ) Error!?Typed.Pending {
        if (token == .null) {
            destination.* = null;
            return null;
        }
        destination.* = @as(Child, undefined);
        return Typed.pending(Child, &destination.*.?, token);
    }

    fn beginArray(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Array,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        if (info.child == u8) {
            const text = try self.stringText(token);
            if (text.bytes.len != info.len) return error.LengthMismatch;
            @memcpy(destination, text.bytes);
            return null;
        }
        try expectToken(token, .array_begin);
        try Typed.pushSequence(machine, info.child, destination.*[0..]);
        return null;
    }

    fn beginVector(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Vector,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        try expectToken(token, .array_begin);
        const values = try self.arena.allocate(info.child, info.len);
        const frame = try machine.push(destination, Typed.continueSequence);
        Typed.initSequence(frame, info.child, values);
        frame.finish = Typed.vectorFinish(T, info.child, info.len);
        return null;
    }

    fn beginPointer(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Pointer,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        if (info.sentinel_ptr != null) {
            @compileError("sentinel pointers are unsupported by JSON decode");
        }
        return switch (info.size) {
            .one => self.beginOnePointer(T, info.child, destination, token),
            .slice => self.beginSlice(T, info, destination, token, machine),
            .many, .c => @compileError("many and C pointers are unsupported by JSON decode"),
        };
    }

    fn beginOnePointer(
        self: *Decoder,
        comptime T: type,
        comptime Child: type,
        destination: *T,
        token: token_source.RawToken,
    ) Error!?Typed.Pending {
        const value = try self.arena.allocate(Child, 1);
        destination.* = &value[0];
        return Typed.pending(Child, &value[0], token);
    }

    fn beginSlice(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Pointer,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        if (info.child == u8) {
            destination.* = try self.readByteSlice(T, info.is_const, token);
            return null;
        }
        try expectToken(token, .array_begin);
        const length = try self.plans.take(.array);
        const values = try self.arena.allocate(info.child, length);
        destination.* = values;
        try Typed.pushSequence(machine, info.child, values);
        return null;
    }

    fn readByteSlice(
        self: *Decoder,
        comptime T: type,
        comptime is_const: bool,
        token: token_source.RawToken,
    ) Error!T {
        const text = try self.stringText(token);
        if (is_const) return try self.persist(text);
        if (text.copied) return @constCast(try self.persist(text));
        const owned = try self.arena.allocate(u8, text.bytes.len);
        @memcpy(owned, text.bytes);
        return owned;
    }

    fn readEnum(
        self: *Decoder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!T {
        const text = try self.stringText(token);
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, text.bytes, field.name)) return @field(T, field.name);
        }
        return error.UnknownEnumTag;
    }

    fn beginTuple(
        _: *Decoder,
        comptime T: type,
        comptime fields: []const std.builtin.Type.StructField,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        try expectToken(token, .array_begin);
        destination.* = undefined;
        const frame = try machine.push(destination, Typed.continueTuple);
        frame.fields = Typed.fields(T, fields, false);
        return null;
    }

    fn beginStruct(
        _: *Decoder,
        comptime T: type,
        comptime fields: []const std.builtin.Type.StructField,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        comptime schema.validate(T);
        try expectToken(token, .object_begin);
        destination.* = undefined;
        const frame = try machine.push(destination, Typed.continueStruct);
        frame.fields = Typed.fields(T, fields, true);
        inline for (fields) |field| if (field.type == void) {
            @field(destination.*, field.name) = {};
        } else if (field.default_value_ptr) |_| {
            @field(destination.*, field.name) = field.defaultValue().?;
        } else {
            frame.required_remaining += 1;
        };
        return null;
    }

    fn beginUnion(
        self: *Decoder,
        comptime T: type,
        comptime info: std.builtin.Type.Union,
        destination: *T,
        token: token_source.RawToken,
        machine: *Typed.Machine,
    ) Error!?Typed.Pending {
        if (info.tag_type == null) @compileError("untagged unions cannot be decoded from JSON");
        try expectToken(token, .object_begin);
        const key = try self.nextRaw();
        if (key == .object_end) return error.LengthMismatch;
        const name = (try self.stringText(key)).bytes;
        inline for (info.fields) |field| if (std.mem.eql(u8, name, field.name)) {
            destination.* = @unionInit(T, field.name, undefined);
            _ = try machine.push(destination, Typed.continueUnionEnd);
            return Typed.pending(
                field.type,
                &@field(destination.*, field.name),
                try self.nextRaw(),
            );
        };
        return error.UnknownEnumTag;
    }

    fn readVoid(self: *Decoder, token: token_source.RawToken) Error!void {
        try expectToken(token, .object_begin);
        if (try self.nextRaw() != .object_end) return error.LengthMismatch;
    }

    pub inline fn dynamicDepthMax(self: *const Decoder) u16 {
        return self.depth_max;
    }

    pub inline fn dynamicTakePlan(
        self: *Decoder,
        kind: storage.PlanKind,
    ) Error!usize {
        return self.plans.take(kind);
    }

    pub inline fn dynamicAllocate(
        self: *Decoder,
        comptime T: type,
        count: usize,
    ) Error![]T {
        return self.arena.allocate(T, count) catch |problem| {
            return mapStorageError(problem);
        };
    }

    pub fn readNumberValue(
        self: *Decoder,
        token: token_source.RawToken,
        retain: bool,
    ) Error!types.Number {
        const text = try self.numberText(token);
        const bytes = if (retain) try self.persist(text) else text.bytes;
        return types.Number.init(bytes) catch error.InvalidNumber;
    }

    fn unknownValue(self: *Decoder) Error!void {
        if (self.unknown_fields == .reject) return error.UnknownField;
        try Dynamic.skip(self, try self.nextRaw());
    }

    pub fn stringText(
        self: *Decoder,
        token: token_source.RawToken,
    ) Error!token_source.Text {
        if (!isString(token)) return error.TypeMismatch;
        const text = self.source.completeString(
            token,
            self.arena.remaining(),
        ) catch |problem| return mapSourceError(problem);
        if (text.copied) try self.arena.observe(text.bytes.len);
        return text;
    }

    fn numberText(
        self: *Decoder,
        token: token_source.RawToken,
    ) Error!token_source.Text {
        if (token != .number and token != .partial_number) return error.TypeMismatch;
        const text = self.source.completeNumber(
            token,
            self.arena.remaining(),
        ) catch |problem| return mapSourceError(problem);
        if (text.copied) try self.arena.observe(text.bytes.len);
        return text;
    }

    pub fn persist(
        self: *Decoder,
        text: token_source.Text,
    ) Error![]const u8 {
        if (!text.copied) return text.bytes;
        return self.arena.retain(text.bytes) catch |problem| {
            return mapStorageError(problem);
        };
    }

    pub fn nextRaw(self: *Decoder) Error!token_source.RawToken {
        return self.source.nextRaw() catch |problem| return mapSourceError(problem);
    }

    pub fn discardString(
        self: *Decoder,
        token: token_source.RawToken,
    ) Error!void {
        self.source.discardString(token) catch |problem| return mapSourceError(problem);
    }

    pub fn discardNumber(
        self: *Decoder,
        token: token_source.RawToken,
    ) Error!void {
        self.source.discardNumber(token) catch |problem| return mapSourceError(problem);
    }
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const body = @import("../../body.zig");
const hook = @import("parse_hook.zig");
const schema = @import("schema.zig");
const storage = @import("decode_storage.zig");
const token_source = @import("token_source.zig");
const typed_decode = @import("decode_typed.zig");
const types = @import("types.zig");

const Container = enum(u8) {
    array,
    object,
};

const DynamicFrame = struct {
    kind: Container,
    plan: *storage.Plan,
};

pub const Error = token_source.Error || storage.ArenaError || error{
    CountOverflow,
    LengthMismatch,
    TypeMismatch,
    UnknownEnumTag,
};

const TypedRun = *const fn (
    *Builder,
    token_source.RawToken,
    *TypedState,
) Error!void;

const TypedAdvance = *const fn (
    *Builder,
    *TypedFrame,
    *TypedState,
) Error!void;

const TypedTask = struct {
    run: TypedRun,
    token: token_source.RawToken,
};

const TypedFrame = struct {
    advance: TypedAdvance,
    cursor: usize = 0,
    plan: ?*storage.Plan = null,
};

const TypedState = struct {
    frames: [token_source.depth_hard_max]TypedFrame = undefined,
    frame_count: u16 = 0,
    pending: ?TypedTask = null,

    fn schedule(
        self: *TypedState,
        comptime T: type,
        token: token_source.RawToken,
    ) void {
        self.pending = .{ .run = typedTrampoline(T), .token = token };
    }

    fn push(self: *TypedState, frame: TypedFrame) Error!void {
        if (self.frame_count == self.frames.len) return error.DepthLimitExceeded;
        self.frames[self.frame_count] = frame;
        self.frame_count += 1;
    }
};

pub fn build(
    comptime T: type,
    input: body.Bytes,
    depth_max: u16,
    arena: *storage.Arena,
) Error![]const storage.Plan {
    var builder: Builder = undefined;
    try builder.init(input, depth_max, arena);
    defer builder.deinit();
    try builder.walk(T, try builder.nextRaw());
    switch (try builder.nextRaw()) {
        .end_of_document => {},
        else => return error.TypeMismatch,
    }
    return builder.plans();
}

const Builder = struct {
    source: token_source.Source,
    arena: *storage.Arena,
    first_plan: ?[*]storage.Plan = null,
    plan_count: usize = 0,

    fn init(
        self: *Builder,
        input: body.Bytes,
        depth_max: u16,
        arena: *storage.Arena,
    ) Error!void {
        self.* = .{ .source = undefined, .arena = arena };
        try self.source.init(input, depth_max);
    }

    fn deinit(self: *Builder) void {
        self.source.deinit();
    }

    fn plans(self: *Builder) []const storage.Plan {
        const first = self.first_plan orelse return &.{};
        return first[0..self.plan_count];
    }

    fn addPlan(self: *Builder, kind: storage.PlanKind) Error!*storage.Plan {
        const allocated = try self.arena.allocate(storage.Plan, 1);
        if (self.first_plan) |first| {
            if (allocated.ptr != first + self.plan_count) return error.PlanMismatch;
        } else {
            self.first_plan = allocated.ptr;
        }
        self.plan_count += 1;
        allocated[0] = .{ .kind = kind };
        return &allocated[0];
    }

    fn walk(
        self: *Builder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!void {
        if (comptime typed_decode.usesDirectTraversal(T)) return self.walkDirect(T, token);
        var state = TypedState{};
        state.schedule(T, token);
        while (true) {
            if (state.pending) |pending| {
                state.pending = null;
                try pending.run(self, pending.token, &state);
                if (state.pending != null) continue;
            }
            while (state.frame_count != 0) {
                const frame = &state.frames[state.frame_count - 1];
                try frame.advance(self, frame, &state);
                if (state.pending != null) break;
                state.frame_count -= 1;
            } else return;
        }
    }

    fn walkDirect(
        self: *Builder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!void {
        if (comptime hook.has(T)) {
            comptime hook.validate(T);
            return self.dynamic(token);
        }
        if (T == types.Value) return self.dynamic(token);
        if (T == types.Number) return self.number(token);
        switch (@typeInfo(T)) {
            .bool => try boolean(token),
            .int, .float => try self.number(token),
            .optional => |info| if (token != .null) try self.walkDirect(info.child, token),
            .array => |info| if (info.child == u8)
                try self.string(token)
            else
                try self.fixedDirect(info.child, info.len, token),
            .vector => |info| try self.fixedDirect(info.child, info.len, token),
            .pointer => |info| try self.pointerDirect(info, token),
            .@"enum" => try self.string(token),
            .@"struct" => |info| if (info.is_tuple)
                try self.tupleDirect(T, token)
            else
                try self.structureDirect(T, token),
            .@"union" => |info| try self.taggedUnionDirect(info, token),
            .void => try self.emptyObject(token),
            else => @compileError("unsupported JSON decode type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn pointerDirect(
        self: *Builder,
        comptime info: std.builtin.Type.Pointer,
        token: token_source.RawToken,
    ) Error!void {
        if (info.sentinel_ptr != null) {
            @compileError("sentinel pointers are unsupported by JSON decode");
        }
        switch (info.size) {
            .one => try self.walkDirect(info.child, token),
            .slice => if (info.child == u8)
                try self.string(token)
            else
                try self.sliceDirect(info.child, token),
            .many, .c => @compileError("many and C pointers are unsupported by JSON decode"),
        }
    }

    fn fixedDirect(
        self: *Builder,
        comptime Child: type,
        comptime length: usize,
        token: token_source.RawToken,
    ) Error!void {
        try expectToken(token, .array_begin);
        for (0..length) |_| {
            const item = try self.nextRaw();
            if (item == .array_end) return error.LengthMismatch;
            try self.walkDirect(Child, item);
        }
        if (try self.nextRaw() != .array_end) return error.LengthMismatch;
    }

    fn tupleDirect(
        self: *Builder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!void {
        try expectToken(token, .array_begin);
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const item = try self.nextRaw();
            if (item == .array_end) return error.LengthMismatch;
            try self.walkDirect(field.type, item);
        }
        if (try self.nextRaw() != .array_end) return error.LengthMismatch;
    }

    fn sliceDirect(
        self: *Builder,
        comptime Child: type,
        token: token_source.RawToken,
    ) Error!void {
        try expectToken(token, .array_begin);
        const array_plan = try self.addPlan(.array);
        while (true) {
            const item = try self.nextRaw();
            if (item == .array_end) return;
            try increment(&array_plan.count);
            try self.walkDirect(Child, item);
        }
    }

    fn structureDirect(
        self: *Builder,
        comptime T: type,
        token: token_source.RawToken,
    ) Error!void {
        comptime schema.validate(T);
        try expectToken(token, .object_begin);
        const fields = @typeInfo(T).@"struct".fields;
        while (true) {
            const key = try self.nextRaw();
            if (key == .object_end) return;
            const name = (try self.stringText(key)).bytes;
            const value = try self.nextRaw();
            var matched = false;
            inline for (fields) |field| if (!matched and field.type != void and
                std.mem.eql(u8, name, comptime schema.wireName(T, field.name)))
            {
                try self.walkDirect(field.type, value);
                matched = true;
            };
            if (!matched) try self.skip(value);
        }
    }

    fn taggedUnionDirect(
        self: *Builder,
        comptime info: std.builtin.Type.Union,
        token: token_source.RawToken,
    ) Error!void {
        if (info.tag_type == null) @compileError("untagged unions cannot be decoded from JSON");
        try expectToken(token, .object_begin);
        const key = try self.nextRaw();
        if (key == .object_end) return error.LengthMismatch;
        const name = (try self.stringText(key)).bytes;
        const value = try self.nextRaw();
        var matched = false;
        inline for (info.fields) |field| if (!matched and std.mem.eql(u8, name, field.name)) {
            try self.walkDirect(field.type, value);
            matched = true;
        };
        if (!matched) return error.UnknownEnumTag;
        if (try self.nextRaw() != .object_end) return error.LengthMismatch;
    }

    fn walkValue(
        self: *Builder,
        comptime T: type,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        if (comptime hook.has(T)) {
            comptime hook.validate(T);
            return self.dynamic(token);
        }
        if (T == types.Value) return self.dynamic(token);
        if (T == types.Number) return self.number(token);
        switch (@typeInfo(T)) {
            .bool => try boolean(token),
            .int, .float => try self.number(token),
            .optional => |info| {
                if (token != .null) state.schedule(info.child, token);
            },
            .array => |info| if (info.child == u8)
                try self.string(token)
            else
                try self.fixed(info.child, info.len, token, state),
            .vector => |info| try self.fixed(info.child, info.len, token, state),
            .pointer => |info| try self.pointer(info, token, state),
            .@"enum" => try self.string(token),
            .@"struct" => |info| if (info.is_tuple)
                try self.tuple(T, token, state)
            else
                try self.structure(T, token, state),
            .@"union" => |info| try self.taggedUnion(info, token, state),
            .void => try self.emptyObject(token),
            else => @compileError("unsupported JSON decode type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn pointer(
        self: *Builder,
        comptime info: std.builtin.Type.Pointer,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        if (info.sentinel_ptr != null) {
            @compileError("sentinel pointers are unsupported by JSON decode");
        }
        switch (info.size) {
            .one => state.schedule(info.child, token),
            .slice => if (info.child == u8)
                try self.string(token)
            else
                try self.slice(info.child, token, state),
            .many, .c => @compileError("many and C pointers are unsupported by JSON decode"),
        }
    }

    fn fixed(
        _: *Builder,
        comptime Child: type,
        comptime length: usize,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        try expectToken(token, .array_begin);
        try state.push(.{ .advance = fixedTrampoline(Child, length) });
    }

    fn tuple(
        _: *Builder,
        comptime T: type,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        try expectToken(token, .array_begin);
        try state.push(.{ .advance = tupleTrampoline(T) });
    }

    fn slice(
        self: *Builder,
        comptime Child: type,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        try expectToken(token, .array_begin);
        const plan = try self.addPlan(.array);
        try state.push(.{ .advance = sliceTrampoline(Child), .plan = plan });
    }

    fn structure(
        _: *Builder,
        comptime T: type,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        comptime schema.validate(T);
        try expectToken(token, .object_begin);
        try state.push(.{ .advance = structureTrampoline(T) });
    }

    fn advanceFixed(
        self: *Builder,
        comptime Child: type,
        comptime length: usize,
        frame: *TypedFrame,
        state: *TypedState,
    ) Error!void {
        if (frame.cursor == length) {
            if (try self.nextRaw() != .array_end) return error.LengthMismatch;
            return;
        }
        const item = try self.nextRaw();
        if (item == .array_end) return error.LengthMismatch;
        frame.cursor += 1;
        state.schedule(Child, item);
    }

    fn advanceTuple(
        self: *Builder,
        comptime T: type,
        frame: *TypedFrame,
        state: *TypedState,
    ) Error!void {
        const fields = @typeInfo(T).@"struct".fields;
        if (frame.cursor == fields.len) {
            if (try self.nextRaw() != .array_end) return error.LengthMismatch;
            return;
        }
        const item = try self.nextRaw();
        if (item == .array_end) return error.LengthMismatch;
        const cursor = frame.cursor;
        frame.cursor += 1;
        inline for (fields, 0..) |field, index| {
            if (cursor == index) state.schedule(field.type, item);
        }
    }

    fn advanceSlice(
        self: *Builder,
        comptime Child: type,
        frame: *TypedFrame,
        state: *TypedState,
    ) Error!void {
        const item = try self.nextRaw();
        if (item == .array_end) return;
        const plan = frame.plan orelse unreachable;
        try increment(&plan.count);
        state.schedule(Child, item);
    }

    fn advanceStructure(
        self: *Builder,
        comptime T: type,
        frame: *TypedFrame,
        state: *TypedState,
    ) Error!void {
        _ = frame;
        const fields = @typeInfo(T).@"struct".fields;
        while (true) {
            const key = try self.nextRaw();
            if (key == .object_end) break;
            const name = (try self.stringText(key)).bytes;
            const value = try self.nextRaw();
            var matched = false;
            inline for (fields) |field| if (!matched and field.type != void and
                std.mem.eql(u8, name, comptime schema.wireName(T, field.name)))
            {
                state.schedule(field.type, value);
                matched = true;
            };
            if (matched) return;
            try self.skip(value);
        }
    }

    fn taggedUnion(
        self: *Builder,
        comptime info: std.builtin.Type.Union,
        token: token_source.RawToken,
        state: *TypedState,
    ) Error!void {
        if (info.tag_type == null) @compileError("untagged unions cannot be decoded from JSON");
        try expectToken(token, .object_begin);
        const key = try self.nextRaw();
        if (key == .object_end) return error.LengthMismatch;
        const name = (try self.stringText(key)).bytes;
        const value = try self.nextRaw();
        var matched = false;
        inline for (info.fields) |field| if (!matched and
            std.mem.eql(u8, name, field.name))
        {
            try state.push(.{ .advance = endObject });
            state.schedule(field.type, value);
            matched = true;
        };
        if (!matched) return error.UnknownEnumTag;
    }

    fn emptyObject(self: *Builder, token: token_source.RawToken) Error!void {
        try expectToken(token, .object_begin);
        if (try self.nextRaw() != .object_end) return error.LengthMismatch;
    }

    fn dynamic(self: *Builder, token: token_source.RawToken) Error!void {
        if (self.source.depth_max <= 8) return self.dynamicCapacity(8, token);
        if (self.source.depth_max <= 16) return self.dynamicCapacity(16, token);
        if (self.source.depth_max <= 32) return self.dynamicCapacity(32, token);
        if (self.source.depth_max <= 64) return self.dynamicCapacity(64, token);
        if (self.source.depth_max <= 128) return self.dynamicCapacity(128, token);
        return self.dynamicCapacity(token_source.depth_hard_max, token);
    }

    fn dynamicCapacity(
        self: *Builder,
        comptime capacity: usize,
        token: token_source.RawToken,
    ) Error!void {
        var frames: [capacity]DynamicFrame = undefined;
        var frame_count: u16 = 0;
        var current = token;
        while (true) {
            try self.dynamicValue(capacity, current, &frames, &frame_count);
            while (frame_count != 0) {
                const frame = &frames[frame_count - 1];
                const next = try self.nextRaw();
                if (frame.kind == .array and next == .array_end or
                    frame.kind == .object and next == .object_end)
                {
                    frame_count -= 1;
                    continue;
                }
                if (frame.kind == .object) try self.discardString(next);
                try increment(&frame.plan.count);
                current = if (frame.kind == .object) try self.nextRaw() else next;
                break;
            } else return;
        }
    }

    fn dynamicValue(
        self: *Builder,
        comptime capacity: usize,
        token: token_source.RawToken,
        frames: *[capacity]DynamicFrame,
        frame_count: *u16,
    ) Error!void {
        const kind: ?Container = switch (token) {
            .object_begin => .object,
            .array_begin => .array,
            .number, .partial_number => return self.number(token),
            .string,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => return self.string(token),
            .true, .false, .null => return,
            else => return error.TypeMismatch,
        };
        if (frame_count.* == frames.len) return error.DepthLimitExceeded;
        const plan_kind: storage.PlanKind = if (kind.? == .array) .array else .object;
        frames[frame_count.*] = .{ .kind = kind.?, .plan = try self.addPlan(plan_kind) };
        frame_count.* += 1;
    }

    fn skip(self: *Builder, token: token_source.RawToken) Error!void {
        if (self.source.depth_max <= 8) return self.skipCapacity(8, token);
        if (self.source.depth_max <= 16) return self.skipCapacity(16, token);
        if (self.source.depth_max <= 32) return self.skipCapacity(32, token);
        if (self.source.depth_max <= 64) return self.skipCapacity(64, token);
        if (self.source.depth_max <= 128) return self.skipCapacity(128, token);
        return self.skipCapacity(token_source.depth_hard_max, token);
    }

    fn skipCapacity(
        self: *Builder,
        comptime capacity: usize,
        token: token_source.RawToken,
    ) Error!void {
        var frames: [capacity]Container = undefined;
        var frame_count: u16 = 0;
        var current = token;
        while (true) {
            try self.skipValue(capacity, current, &frames, &frame_count);
            while (frame_count != 0) {
                const kind = frames[frame_count - 1];
                const next = try self.nextRaw();
                if (kind == .array and next == .array_end or
                    kind == .object and next == .object_end)
                {
                    frame_count -= 1;
                    continue;
                }
                if (kind == .object) try self.discardString(next);
                current = if (kind == .object) try self.nextRaw() else next;
                break;
            } else return;
        }
    }

    fn skipValue(
        self: *Builder,
        comptime capacity: usize,
        token: token_source.RawToken,
        frames: *[capacity]Container,
        frame_count: *u16,
    ) Error!void {
        const kind: ?Container = switch (token) {
            .object_begin => .object,
            .array_begin => .array,
            .number, .partial_number => return self.number(token),
            .string,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => return self.string(token),
            .true, .false, .null => return,
            else => return error.TypeMismatch,
        };
        if (frame_count.* == frames.len) return error.DepthLimitExceeded;
        frames[frame_count.*] = kind.?;
        frame_count.* += 1;
    }

    fn string(self: *Builder, token: token_source.RawToken) Error!void {
        try self.discardString(token);
    }

    fn number(self: *Builder, token: token_source.RawToken) Error!void {
        if (token != .number and token != .partial_number) return error.TypeMismatch;
        try self.source.discardNumber(token);
    }

    fn stringText(
        self: *Builder,
        token: token_source.RawToken,
    ) Error!token_source.Text {
        if (!isString(token)) return error.TypeMismatch;
        const text = try self.source.completeString(token, self.arena.remaining());
        if (text.copied) try self.arena.observe(text.bytes.len);
        return text;
    }

    fn discardString(self: *Builder, token: token_source.RawToken) Error!void {
        if (!isString(token)) return error.TypeMismatch;
        try self.source.discardString(token);
    }

    fn nextRaw(self: *Builder) Error!token_source.RawToken {
        return self.source.nextRaw();
    }
};

fn typedTrampoline(comptime T: type) TypedRun {
    return struct {
        fn run(
            builder: *Builder,
            token: token_source.RawToken,
            state: *TypedState,
        ) Error!void {
            return builder.walkValue(T, token, state);
        }
    }.run;
}

fn fixedTrampoline(comptime Child: type, comptime length: usize) TypedAdvance {
    return struct {
        fn advance(
            builder: *Builder,
            frame: *TypedFrame,
            state: *TypedState,
        ) Error!void {
            return builder.advanceFixed(Child, length, frame, state);
        }
    }.advance;
}

fn tupleTrampoline(comptime T: type) TypedAdvance {
    return struct {
        fn advance(
            builder: *Builder,
            frame: *TypedFrame,
            state: *TypedState,
        ) Error!void {
            return builder.advanceTuple(T, frame, state);
        }
    }.advance;
}

fn sliceTrampoline(comptime Child: type) TypedAdvance {
    return struct {
        fn advance(
            builder: *Builder,
            frame: *TypedFrame,
            state: *TypedState,
        ) Error!void {
            return builder.advanceSlice(Child, frame, state);
        }
    }.advance;
}

fn structureTrampoline(comptime T: type) TypedAdvance {
    return struct {
        fn advance(
            builder: *Builder,
            frame: *TypedFrame,
            state: *TypedState,
        ) Error!void {
            return builder.advanceStructure(T, frame, state);
        }
    }.advance;
}

fn endObject(
    builder: *Builder,
    _: *TypedFrame,
    _: *TypedState,
) Error!void {
    if (try builder.nextRaw() != .object_end) return error.LengthMismatch;
}

fn boolean(token: token_source.RawToken) Error!void {
    if (token != .true and token != .false) return error.TypeMismatch;
}

fn isString(token: token_source.RawToken) bool {
    return switch (token) {
        .string,
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => true,
        else => false,
    };
}

fn expectToken(
    actual: token_source.RawToken,
    comptime expected: std.meta.Tag(token_source.RawToken),
) Error!void {
    if (std.meta.activeTag(actual) != expected) return error.TypeMismatch;
}

fn increment(value: *u32) Error!void {
    value.* = std.math.add(u32, value.*, 1) catch return error.CountOverflow;
}

test {
    std.testing.refAllDecls(@This());
}

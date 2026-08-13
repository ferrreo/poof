const std = @import("std");
const direct = @import("encode_direct.zig");
const scalar = @import("encode_scalar.zig");
const schema = @import("schema.zig");
const typed = @import("encode_typed.zig");
const types = @import("types.zig");

pub fn encode(
    comptime requested_options: types.Options,
    value: anytype,
    output: []u8,
) types.EncodeError(@TypeOf(value))![]const u8 {
    const options = comptime requested_options.validate();
    const limit = @min(output.len, options.encoded_bytes_max);
    var engine = Engine(@TypeOf(value), options){
        .sink = .{ .bytes = output[0..limit] },
    };
    try engine.writeValue(value);
    return output[0..engine.sink.used];
}

fn Engine(comptime Root: type, comptime options: types.Options) type {
    const FullError = types.EncodeError(Root);
    return struct {
        const Self = @This();
        const Direct = direct.Driver(Self, FullError);
        const Typed = typed.Driver(Self, options, FullError);

        const Reference = struct {
            address: usize,
            extent: usize,
            type_hash: u64,
        };

        const Container = enum(u8) {
            array,
            object,
        };

        const HookFrame = struct {
            kind: Container,
            count: u32 = 0,
            waiting_value: bool = false,
            content_start: usize,
        };

        const DynamicFrame = union(enum) {
            array: struct {
                values: []const types.Value,
                next_index: usize,
                tracked: bool,
            },
            object: struct {
                members: []const types.Member,
                next_index: usize,
                tracked: bool,
            },
        };

        sink: scalar.Sink,
        depth: u16 = 0,
        hook_depth: u16 = 0,
        hook_frame_count: u16 = 0,
        reference_count: u16 = 0,
        typed_frame_count: u16 = 0,
        references: [options.max_depth]Reference = undefined,
        hook_frames: [options.max_depth]HookFrame = undefined,
        typed_frames: ?*[Typed.frame_capacity]Typed.Frame = null,

        pub inline fn writeValue(self: *Self, value: anytype) FullError!void {
            const T = @TypeOf(value);
            if (T == types.Value) return self.writeDynamic(value);
            if (T == types.Number) return scalar.writeNumber(&self.sink, value);
            if (comptime directHookPath(T)) return self.writeHookPath(T, value);
            switch (@typeInfo(T)) {
                .int => return scalar.writeInteger(&self.sink, value),
                .comptime_int => {
                    const Fitting = std.math.IntFittingRange(value, value);
                    return scalar.writeInteger(&self.sink, @as(Fitting, value));
                },
                .float => return scalar.writeFloat(&self.sink, value),
                .comptime_float => {
                    return scalar.writeFloat(&self.sink, @as(f128, value));
                },
                .bool => return self.sink.writeAll(if (value) "true" else "false"),
                .null => return self.sink.writeAll("null"),
                .@"enum" => return self.writeEnum(value),
                .enum_literal => return self.writeString(@tagName(value)),
                .@"union", .@"struct" => {
                    if (std.meta.hasFn(T, "jsonStringify")) return self.writeHook(value);
                },
                .error_set => return self.writeString(@errorName(value)),
                .optional, .pointer, .array, .vector => {},
                else => @compileError("unable to encode JSON type '" ++ @typeName(T) ++ "'"),
            }
            if (comptime direct.eligible(T)) return Direct.write(self, value);
            return self.writeTyped(T, &value);
        }

        inline fn writeHookPath(self: *Self, comptime T: type, value: T) FullError!void {
            switch (@typeInfo(T)) {
                .optional => |info| {
                    if (value) |payload| return self.writeHookPath(info.child, payload);
                    return self.sink.writeAll("null");
                },
                .pointer => |info| {
                    const tracked = try self.pushPointerReference(T, value);
                    defer if (tracked) self.popReference();
                    return self.writeHookPath(info.child, value.*);
                },
                .@"enum", .@"struct", .@"union" => return self.writeHook(value),
                else => unreachable,
            }
        }

        pub fn writeDynamic(self: *Self, value: types.Value) FullError!void {
            const reference_start = self.reference_count;
            defer self.reference_count = reference_start;
            var frames: [options.max_depth]DynamicFrame = undefined;
            var frame_count: u16 = 0;
            var current = value;
            while (true) {
                if (try self.writeDynamicValue(current, &frames, &frame_count)) |child| {
                    current = child;
                    continue;
                }
                while (frame_count != 0) {
                    const next = try self.advanceDynamicFrame(&frames[frame_count - 1]);
                    if (next) |child| {
                        current = child;
                        break;
                    }
                    frame_count -= 1;
                } else return;
            }
        }

        fn writeDynamicValue(
            self: *Self,
            value: types.Value,
            frames: *[options.max_depth]DynamicFrame,
            frame_count: *u16,
        ) FullError!?types.Value {
            return switch (value) {
                .null => done: {
                    try self.sink.writeAll("null");
                    break :done null;
                },
                .boolean => |boolean| done: {
                    try self.sink.writeAll(if (boolean) "true" else "false");
                    break :done null;
                },
                .number => |number| done: {
                    try scalar.writeNumber(&self.sink, number);
                    break :done null;
                },
                .string => |string| done: {
                    try self.writeString(string);
                    break :done null;
                },
                .array => |values| self.beginDynamicArray(values, frames, frame_count),
                .object => |members| self.beginDynamicObject(members, frames, frame_count),
            };
        }

        fn beginDynamicArray(
            self: *Self,
            values: []const types.Value,
            frames: *[options.max_depth]DynamicFrame,
            frame_count: *u16,
        ) FullError!?types.Value {
            if (frame_count.* == frames.len) return error.MaxDepthExceeded;
            const tracked = try self.pushSliceReference(types.Value, values.ptr, values.len);
            errdefer if (tracked) self.popReference();
            try self.open('[');
            if (values.len == 0) {
                try self.close(']', false);
                if (tracked) self.popReference();
                return null;
            }
            try self.separator(0);
            frames[frame_count.*] = .{ .array = .{
                .values = values,
                .next_index = 1,
                .tracked = tracked,
            } };
            frame_count.* += 1;
            return values[0];
        }

        fn beginDynamicObject(
            self: *Self,
            members: []const types.Member,
            frames: *[options.max_depth]DynamicFrame,
            frame_count: *u16,
        ) FullError!?types.Value {
            try validateMembers(members);
            if (frame_count.* == frames.len) return error.MaxDepthExceeded;
            const tracked = try self.pushSliceReference(types.Member, members.ptr, members.len);
            errdefer if (tracked) self.popReference();
            try self.open('{');
            if (members.len == 0) {
                try self.close('}', false);
                if (tracked) self.popReference();
                return null;
            }
            try self.writeDynamicMember(members[0], 0);
            frames[frame_count.*] = .{ .object = .{
                .members = members,
                .next_index = 1,
                .tracked = tracked,
            } };
            frame_count.* += 1;
            return members[0].value;
        }

        fn advanceDynamicFrame(self: *Self, frame: *DynamicFrame) FullError!?types.Value {
            return switch (frame.*) {
                .array => |*array| if (array.next_index < array.values.len) next: {
                    const index = array.next_index;
                    array.next_index += 1;
                    try self.separator(index);
                    break :next array.values[index];
                } else done: {
                    try self.close(']', array.values.len != 0);
                    if (array.tracked) self.popReference();
                    break :done null;
                },
                .object => |*object| if (object.next_index < object.members.len) next: {
                    const index = object.next_index;
                    object.next_index += 1;
                    try self.writeDynamicMember(object.members[index], index);
                    break :next object.members[index].value;
                } else done: {
                    try self.close('}', object.members.len != 0);
                    if (object.tracked) self.popReference();
                    break :done null;
                },
            };
        }

        fn writeDynamicMember(self: *Self, member: types.Member, index: usize) FullError!void {
            try self.separator(index);
            try self.writeString(member.name);
            try self.colon();
        }

        pub fn writeEnum(self: *Self, value: anytype) FullError!void {
            const T = @TypeOf(value);
            if (std.meta.hasFn(T, "jsonStringify")) return self.writeHook(value);
            const info = @typeInfo(T).@"enum";
            if (!info.is_exhaustive) {
                inline for (info.fields) |field| {
                    if (value == @field(T, field.name)) return self.writeString(field.name);
                }
                return error.UnknownEnumTag;
            }
            return self.writeString(@tagName(value));
        }

        inline fn writeTyped(self: *Self, comptime T: type, source: *const T) FullError!void {
            if (self.typed_frames) |frames| {
                return Typed.write(self, T, source, frames, &self.typed_frame_count);
            }
            var frames: [Typed.frame_capacity]Typed.Frame = undefined;
            self.typed_frames = &frames;
            defer self.typed_frames = null;
            return Typed.write(
                self,
                T,
                source,
                &frames,
                &self.typed_frame_count,
            );
        }

        pub fn writeHook(self: *Self, value: anytype) FullError!void {
            const T = @TypeOf(value);
            comptime types.validateHook(T);
            const depth_max = @min(options.max_depth, types.hook_depth_hard_max);
            if (self.hook_depth == depth_max) return error.MaxDepthExceeded;
            self.hook_depth += 1;
            defer self.hook_depth -= 1;
            const frame_start = self.hook_frame_count;
            defer self.hook_frame_count = frame_start;
            var writer = HookWriter{ .context = self, .frame_start = frame_start };
            value.jsonStringify(&writer) catch |problem| {
                if (writer.failure) |failure| return failure;
                return problem;
            };
            try writer.finish();
        }

        pub fn writeString(self: *Self, value: []const u8) FullError!void {
            return scalar.writeString(&self.sink, value, options.html_safe);
        }

        pub fn open(self: *Self, byte: u8) FullError!void {
            if (self.depth == options.max_depth) return error.MaxDepthExceeded;
            try self.sink.writeByte(byte);
            self.depth += 1;
        }

        pub fn close(self: *Self, byte: u8, nonempty: bool) FullError!void {
            if (nonempty) try self.indent(self.depth - 1);
            try self.sink.writeByte(byte);
            self.depth -= 1;
        }

        pub fn separator(self: *Self, index: usize) FullError!void {
            if (index != 0) try self.sink.writeByte(',');
            try self.indent(self.depth);
        }

        pub fn colon(self: *Self) FullError!void {
            try self.sink.writeByte(':');
            if (options.whitespace != .minified) try self.sink.writeByte(' ');
        }

        fn indent(self: *Self, level: u16) FullError!void {
            if (options.whitespace == .minified) return;
            try self.sink.writeByte('\n');
            var remaining: usize = @as(usize, level) * 2;
            const spaces = "                                                                ";
            while (remaining != 0) {
                const count = @min(remaining, spaces.len);
                try self.sink.writeAll(spaces[0..count]);
                remaining -= count;
            }
        }

        pub fn pushPointerReference(self: *Self, comptime T: type, pointer: T) FullError!bool {
            return self.pushReference(.{
                .address = @intFromPtr(pointer),
                .extent = 0,
                .type_hash = comptime typeHash(T),
            });
        }

        pub fn pushSliceReference(
            self: *Self,
            comptime Child: type,
            pointer: [*]const Child,
            length: usize,
        ) FullError!bool {
            if (length == 0) return false;
            return self.pushReference(.{
                .address = @intFromPtr(pointer),
                .extent = length,
                .type_hash = comptime typeHash([]const Child),
            });
        }

        fn pushReference(self: *Self, reference: Reference) FullError!bool {
            for (self.references[0..self.reference_count]) |active| {
                if (active.address == reference.address and
                    active.extent == reference.extent and
                    active.type_hash == reference.type_hash)
                {
                    return error.CircularReference;
                }
            }
            if (self.reference_count == options.max_depth) return error.MaxDepthExceeded;
            self.references[self.reference_count] = reference;
            self.reference_count += 1;
            return true;
        }

        pub fn popReference(self: *Self) void {
            self.reference_count -= 1;
        }

        const HookWriter = struct {
            context: *anyopaque,
            root_started: bool = false,
            frame_start: u16,
            failure: ?FullError = null,

            pub inline fn write(
                writer: *HookWriter,
                value: anytype,
            ) types.EncodeError(@TypeOf(value))!void {
                return writer.writeInner(value) catch |problem| {
                    return writer.record(types.EncodeError(@TypeOf(value)), problem);
                };
            }

            inline fn writeInner(writer: *HookWriter, value: anytype) FullError!void {
                try writer.checkFailure();
                try writer.startValue();
                try writer.getEngine().writeValue(value);
            }

            pub fn beginArray(writer: *HookWriter) types.FrameworkEncodeError!void {
                return writer.begin(.array, '[') catch |problem| {
                    return writer.record(types.FrameworkEncodeError, problem);
                };
            }

            pub fn endArray(writer: *HookWriter) types.FrameworkEncodeError!void {
                return writer.end(.array, ']') catch |problem| {
                    return writer.record(types.FrameworkEncodeError, problem);
                };
            }

            pub fn beginObject(writer: *HookWriter) types.FrameworkEncodeError!void {
                return writer.begin(.object, '{') catch |problem| {
                    return writer.record(types.FrameworkEncodeError, problem);
                };
            }

            pub fn endObject(writer: *HookWriter) types.FrameworkEncodeError!void {
                return writer.end(.object, '}') catch |problem| {
                    return writer.record(types.FrameworkEncodeError, problem);
                };
            }

            pub fn objectField(
                writer: *HookWriter,
                name: []const u8,
            ) types.FrameworkEncodeError!void {
                return writer.objectFieldInner(name) catch |problem| {
                    return writer.record(types.FrameworkEncodeError, problem);
                };
            }

            fn objectFieldInner(writer: *HookWriter, name: []const u8) FullError!void {
                try writer.checkFailure();
                const engine = writer.getEngine();
                if (engine.hook_frame_count == writer.frame_start) {
                    return error.MalformedCustomJson;
                }
                const frame = &engine.hook_frames[engine.hook_frame_count - 1];
                if (frame.kind != .object or frame.waiting_value) {
                    return error.MalformedCustomJson;
                }
                if (frame.count != 0 and try writer.hasObjectField(frame.*, name)) {
                    return error.DuplicateField;
                }
                try writer.getEngine().separator(frame.count);
                try writer.getEngine().writeString(name);
                try writer.getEngine().colon();
                frame.count += 1;
                frame.waiting_value = true;
            }

            fn finish(writer: *HookWriter) FullError!void {
                if (writer.failure) |failure| return failure;
                if (!writer.root_started or
                    writer.getEngine().hook_frame_count != writer.frame_start)
                {
                    return error.MalformedCustomJson;
                }
            }

            fn begin(writer: *HookWriter, kind: Container, byte: u8) FullError!void {
                try writer.checkFailure();
                try writer.startValue();
                const engine = writer.getEngine();
                if (engine.hook_frame_count == options.max_depth) {
                    return error.MaxDepthExceeded;
                }
                try engine.open(byte);
                engine.hook_frames[engine.hook_frame_count] = .{
                    .kind = kind,
                    .content_start = engine.sink.used,
                };
                engine.hook_frame_count += 1;
            }

            fn end(writer: *HookWriter, expected: Container, byte: u8) FullError!void {
                try writer.checkFailure();
                const engine = writer.getEngine();
                if (engine.hook_frame_count == writer.frame_start) {
                    return error.MalformedCustomJson;
                }
                const frame = engine.hook_frames[engine.hook_frame_count - 1];
                if (frame.kind != expected or frame.waiting_value) {
                    return error.MalformedCustomJson;
                }
                try engine.close(byte, frame.count != 0);
                engine.hook_frame_count -= 1;
            }

            fn startValue(writer: *HookWriter) FullError!void {
                const engine = writer.getEngine();
                if (engine.hook_frame_count == writer.frame_start) {
                    if (writer.root_started) return error.MalformedCustomJson;
                    writer.root_started = true;
                    return;
                }
                const frame = &engine.hook_frames[engine.hook_frame_count - 1];
                switch (frame.kind) {
                    .array => {
                        try engine.separator(frame.count);
                        frame.count += 1;
                    },
                    .object => {
                        if (!frame.waiting_value) return error.MalformedCustomJson;
                        frame.waiting_value = false;
                    },
                }
            }

            fn checkFailure(writer: *const HookWriter) FullError!void {
                if (writer.failure != null) return error.MalformedCustomJson;
            }

            fn record(
                writer: *HookWriter,
                comptime Selected: type,
                problem: FullError,
            ) Selected {
                if (writer.failure == null) writer.failure = problem;
                return narrowError(Selected, problem);
            }

            fn getEngine(writer: *HookWriter) *Self {
                return @ptrCast(@alignCast(writer.context));
            }

            fn hasObjectField(
                writer: *HookWriter,
                frame: HookFrame,
                name: []const u8,
            ) FullError!bool {
                const engine = writer.getEngine();
                const checkpoint = engine.sink.used;
                try scalar.writeString(&engine.sink, name, options.html_safe);
                defer engine.sink.used = checkpoint;
                const probe = engine.sink.bytes[checkpoint..engine.sink.used];
                const source = engine.sink.bytes[0..checkpoint];
                var cursor = frame.content_start;
                for (0..frame.count) |index| {
                    skipHookWhitespace(source, &cursor);
                    if (index != 0) try consumeHookByte(source, &cursor, ',');
                    skipHookWhitespace(source, &cursor);
                    const key_start = cursor;
                    try skipHookString(source, &cursor);
                    if (std.mem.eql(u8, source[key_start..cursor], probe)) return true;
                    skipHookWhitespace(source, &cursor);
                    try consumeHookByte(source, &cursor, ':');
                    try skipHookValue(source, &cursor);
                }
                return false;
            }
        };

        fn narrowError(comptime Selected: type, problem: FullError) Selected {
            const selected = @typeInfo(Selected).error_set orelse unreachable;
            inline for (selected) |candidate| {
                const value = @field(Selected, candidate.name);
                if (problem == value) return value;
            }
            unreachable;
        }
    };
}

fn validateMembers(members: []const types.Member) types.Error!void {
    for (members, 0..) |member, index| {
        if (!std.unicode.utf8ValidateSlice(member.name)) return error.InvalidUtf8;
        for (members[0..index]) |previous| {
            if (std.mem.eql(u8, member.name, previous.name)) return error.DuplicateField;
        }
    }
}

fn typeHash(comptime T: type) u64 {
    var hash: u64 = 14695981039346656037;
    for (@typeName(T)) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}

fn directHookPath(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| directHookPath(info.child),
        .pointer => |info| info.size == .one and directHookPath(info.child),
        .@"enum", .@"struct", .@"union" => std.meta.hasFn(T, "jsonStringify"),
        else => false,
    };
}

fn skipHookValue(bytes: []const u8, cursor: *usize) types.Error!void {
    skipHookWhitespace(bytes, cursor);
    if (cursor.* == bytes.len) return error.MalformedCustomJson;
    if (bytes[cursor.*] == '"') return skipHookString(bytes, cursor);
    if (bytes[cursor.*] != '{' and bytes[cursor.*] != '[') {
        const start = cursor.*;
        while (cursor.* < bytes.len and !hookDelimiter(bytes[cursor.*])) cursor.* += 1;
        if (cursor.* == start) return error.MalformedCustomJson;
        return;
    }
    var nesting: u16 = 0;
    var in_string = false;
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (in_string) {
            if (byte == '\\') {
                if (cursor.* == bytes.len) return error.MalformedCustomJson;
                cursor.* += 1;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{' or byte == '[') {
            if (nesting == std.math.maxInt(u16)) return error.MaxDepthExceeded;
            nesting += 1;
        } else if (byte == '}' or byte == ']') {
            if (nesting == 0) return error.MalformedCustomJson;
            nesting -= 1;
            if (nesting == 0) return;
        }
    }
    return error.MalformedCustomJson;
}

fn skipHookString(bytes: []const u8, cursor: *usize) types.Error!void {
    try consumeHookByte(bytes, cursor, '"');
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (byte == '"') return;
        if (byte == '\\') {
            if (cursor.* == bytes.len) return error.MalformedCustomJson;
            cursor.* += 1;
        }
    }
    return error.MalformedCustomJson;
}

fn consumeHookByte(bytes: []const u8, cursor: *usize, expected: u8) types.Error!void {
    if (cursor.* == bytes.len or bytes[cursor.*] != expected) {
        return error.MalformedCustomJson;
    }
    cursor.* += 1;
}

fn skipHookWhitespace(bytes: []const u8, cursor: *usize) void {
    while (cursor.* < bytes.len) {
        switch (bytes[cursor.*]) {
            ' ', '\t', '\r', '\n' => cursor.* += 1,
            else => return,
        }
    }
}

fn hookDelimiter(byte: u8) bool {
    return byte == ',' or byte == ']' or byte == '}' or
        byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

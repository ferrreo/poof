const std = @import("std");
const scalar = @import("encode_scalar.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");

pub fn Driver(
    comptime Host: type,
    comptime options: types.Options,
    comptime FullError: type,
) type {
    return struct {
        const TypedPhase = enum(u8) {
            value,
            array,
            raw_slice,
            tuple,
            structure,
            union_end,
            vector,
        };

        pub const frame_capacity: usize = options.max_depth + 1;
        const TypedStep = *const fn (
            *Host,
            *[frame_capacity]Frame,
            *u16,
        ) FullError!void;

        pub const Frame = struct {
            step: TypedStep,
            source: *const anyopaque,
            index: usize = 0,
            limit: usize = 0,
            emitted: usize = 0,
            references_owned: u16 = 0,
            phase: TypedPhase = .value,
        };

        pub inline fn write(
            self: *Host,
            comptime T: type,
            source: *const T,
            frames: *[frame_capacity]Frame,
            frame_count: *u16,
        ) FullError!void {
            const reference_start = self.reference_count;
            const frame_start = frame_count.*;
            defer self.reference_count = reference_start;
            defer frame_count.* = frame_start;
            if (frame_count.* == frames.len) return error.MaxDepthExceeded;
            frames[frame_count.*] = typedFrame(T, source);
            frame_count.* += 1;
            while (frame_count.* != frame_start) {
                const step = frames[frame_count.* - 1].step;
                try step(self, frames, frame_count);
            }
        }

        fn typedFrame(comptime T: type, source: *const T) Frame {
            return .{ .step = typedStep(T), .source = @ptrCast(source) };
        }

        fn typedStep(comptime T: type) TypedStep {
            if (comptime hasHook(T)) return typedHookStep(T);
            return struct {
                fn run(
                    self: *Host,
                    frames: *[frame_capacity]Frame,
                    count: *u16,
                ) FullError!void {
                    return advanceTyped(self, T, frames, count);
                }
            }.run;
        }

        fn typedHookStep(comptime T: type) TypedStep {
            return struct {
                fn run(
                    self: *Host,
                    frames: *[frame_capacity]Frame,
                    count: *u16,
                ) FullError!void {
                    const frame = &frames[count.* - 1];
                    try self.writeHook(sourcePointer(T, frame).*);
                    finishTyped(self, frames, count);
                }
            }.run;
        }

        inline fn advanceTyped(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const frame = &frames[count.* - 1];
            switch (frame.phase) {
                .array => return advanceArray(self, T, frames, count),
                .raw_slice => return advanceRawSlice(self, T, frames, count),
                .tuple => return advanceTuple(self, T, frames, count),
                .structure => return advanceStruct(self, T, frames, count),
                .union_end => return finishUnion(self, frames, count),
                .vector => return advanceVector(self, T, frames, count),
                .value => {},
            }
            if (T == types.Value) {
                try self.writeDynamic(sourcePointer(T, frame).*);
                return finishTyped(self, frames, count);
            }
            if (T == types.Number) {
                try scalar.writeNumber(&self.sink, sourcePointer(T, frame).*);
                return finishTyped(self, frames, count);
            }
            return beginTypedValue(self, T, frames, count);
        }

        inline fn beginTypedValue(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const frame = &frames[count.* - 1];
            const value = sourcePointer(T, frame).*;
            switch (@typeInfo(T)) {
                .int => try scalar.writeInteger(&self.sink, value),
                .float => try scalar.writeFloat(&self.sink, value),
                .bool => try self.sink.writeAll(if (value) "true" else "false"),
                .@"enum" => try self.writeEnum(value),
                .error_set => try self.writeString(@errorName(value)),
                .optional => |info| return beginOptional(self, T, info.child, frames, count),
                .@"union" => return beginUnion(self, T, frames, count),
                .@"struct" => |info| return beginStruct(self, T, info.is_tuple, frames, count),
                .pointer => return beginPointer(self, T, frames, count),
                .array => return beginArray(self, T, frames, count),
                .vector => return beginVector(self, T, frames, count),
                else => @compileError("unable to encode JSON type '" ++ @typeName(T) ++ "'"),
            }
            finishTyped(self, frames, count);
        }

        fn beginOptional(
            self: *Host,
            comptime T: type,
            comptime Child: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const frame = &frames[count.* - 1];
            if (sourcePointer(T, frame).*) |*payload| {
                replaceTyped(frame, Child, payload);
                return;
            }
            try self.sink.writeAll("null");
            finishTyped(self, frames, count);
        }

        fn beginArray(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const info = @typeInfo(T).array;
            const frame = &frames[count.* - 1];
            if (info.child == u8) {
                try self.writeString(sourcePointer(T, frame).*[0..]);
                return finishTyped(self, frames, count);
            }
            try self.open('[');
            frame.phase = .array;
            frame.limit = info.len;
        }

        fn advanceArray(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (comptime @typeInfo(T) != .array) unreachable;
            const Child = @typeInfo(T).array.child;
            const frame = &frames[count.* - 1];
            if (frame.index == frame.limit) {
                try self.close(']', frame.limit != 0);
                return finishTyped(self, frames, count);
            }
            const index = frame.index;
            frame.index += 1;
            try self.separator(index);
            try pushTyped(frames, count, Child, &sourcePointer(T, frame).*[index], 0);
        }

        inline fn beginStruct(
            self: *Host,
            comptime T: type,
            comptime tuple: bool,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (std.meta.hasFn(T, "jsonStringify")) {
                try self.writeHook(sourcePointer(T, &frames[count.* - 1]).*);
                return finishTyped(self, frames, count);
            }
            if (!tuple) comptime schema.validate(T);
            try self.open(if (tuple) '[' else '{');
            frames[count.* - 1].phase = if (tuple) .tuple else .structure;
        }

        fn advanceTuple(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (comptime @typeInfo(T) != .@"struct") unreachable;
            const fields = @typeInfo(T).@"struct".fields;
            const frame = &frames[count.* - 1];
            if (frame.index == fields.len) {
                try self.close(']', fields.len != 0);
                return finishTyped(self, frames, count);
            }
            const index = frame.index;
            frame.index += 1;
            try self.separator(index);
            inline for (fields, 0..) |field, field_index| if (index == field_index) {
                return pushField(self, T, field, frames, count);
            };
            unreachable;
        }

        fn advanceStruct(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (comptime @typeInfo(T) != .@"struct") unreachable;
            const fields = @typeInfo(T).@"struct".fields;
            const frame = &frames[count.* - 1];
            field_loop: while (frame.index < fields.len) {
                const index = frame.index;
                frame.index += 1;
                inline for (fields, 0..) |field, field_index| if (index == field_index) {
                    if (field.type == void) continue :field_loop;
                    if (comptime schema.omitIfNull(T, field.name)) {
                        if (@field(sourcePointer(T, frame).*, field.name) == null) {
                            continue :field_loop;
                        }
                    }
                    try self.separator(frame.emitted);
                    try self.writeString(comptime schema.wireName(T, field.name));
                    try self.colon();
                    frame.emitted += 1;
                    return pushField(self, T, field, frames, count);
                };
                unreachable;
            }
            try self.close('}', frame.emitted != 0);
            finishTyped(self, frames, count);
        }

        fn pushField(
            self: *Host,
            comptime T: type,
            comptime field: std.builtin.Type.StructField,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (comptime field.is_comptime and comptimeOnly(field.type)) {
                return self.writeValue(field.defaultValue().?);
            }
            if (comptime @typeInfo(T).@"struct".layout == .@"packed") {
                const frame = &frames[count.* - 1];
                return self.writeValue(@field(sourcePointer(T, frame).*, field.name));
            }
            const source = if (field.is_comptime)
                comptimeFieldPointer(field)
            else
                &@field(sourcePointer(T, &frames[count.* - 1]).*, field.name);
            try pushTyped(frames, count, field.type, source, 0);
        }

        fn beginUnion(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (std.meta.hasFn(T, "jsonStringify")) {
                try self.writeHook(sourcePointer(T, &frames[count.* - 1]).*);
                return finishTyped(self, frames, count);
            }
            const info = @typeInfo(T).@"union";
            const Tag = info.tag_type orelse {
                @compileError("unable to encode untagged union '" ++ @typeName(T) ++ "'");
            };
            const frame = &frames[count.* - 1];
            const active = std.meta.activeTag(sourcePointer(T, frame).*);
            try self.open('{');
            inline for (info.fields) |field| if (active == @field(Tag, field.name)) {
                try self.separator(0);
                try self.writeString(field.name);
                try self.colon();
                if (field.type == void) {
                    try self.open('{');
                    try self.close('}', false);
                    try self.close('}', true);
                    return finishTyped(self, frames, count);
                }
                frame.phase = .union_end;
                return pushTyped(
                    frames,
                    count,
                    field.type,
                    &@field(sourcePointer(T, frame).*, field.name),
                    0,
                );
            };
            unreachable;
        }

        fn finishUnion(
            self: *Host,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            try self.close('}', true);
            finishTyped(self, frames, count);
        }

        fn beginPointer(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const info = @typeInfo(T).pointer;
            const frame = &frames[count.* - 1];
            const value = sourcePointer(T, frame).*;
            switch (info.size) {
                .one => {
                    if (@typeInfo(info.child) == .array and
                        @typeInfo(info.child).array.child == u8)
                    {
                        try self.writeString(value[0..]);
                        return finishTyped(self, frames, count);
                    }
                    const tracked = try self.pushPointerReference(T, value);
                    frame.references_owned += @intFromBool(tracked);
                    replaceTyped(frame, info.child, value);
                },
                .slice => {
                    if (info.child == u8) {
                        try self.writeString(value);
                        return finishTyped(self, frames, count);
                    }
                    const tracked = try self.pushSliceReference(info.child, value.ptr, value.len);
                    frame.references_owned += @intFromBool(tracked);
                    try beginRawSlice(self, frame, info.child, value.ptr, value.len);
                },
                .many => {
                    if (info.sentinel() == null) {
                        @compileError("JSON many pointer requires a sentinel");
                    }
                    const slice = std.mem.span(value);
                    if (info.child == u8) {
                        try self.writeString(slice);
                        return finishTyped(self, frames, count);
                    }
                    const tracked = try self.pushSliceReference(info.child, slice.ptr, slice.len);
                    frame.references_owned += @intFromBool(tracked);
                    try beginRawSlice(self, frame, info.child, slice.ptr, slice.len);
                },
                .c => @compileError("unable to encode C pointer '" ++ @typeName(T) ++ "'"),
            }
        }

        fn beginRawSlice(
            self: *Host,
            frame: *Frame,
            comptime Child: type,
            pointer: [*]const Child,
            length: usize,
        ) FullError!void {
            const references_owned = frame.references_owned;
            try self.open('[');
            frame.* = typedFrame(Child, @as(*const Child, @ptrCast(pointer)));
            frame.phase = .raw_slice;
            frame.limit = length;
            frame.references_owned = references_owned;
        }

        fn advanceRawSlice(
            self: *Host,
            comptime Child: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const frame = &frames[count.* - 1];
            if (frame.index == frame.limit) {
                try self.close(']', frame.limit != 0);
                return finishTyped(self, frames, count);
            }
            const values: [*]const Child = @ptrCast(@alignCast(frame.source));
            const index = frame.index;
            frame.index += 1;
            try self.separator(index);
            try pushTyped(frames, count, Child, &values[index], 0);
        }

        fn beginVector(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            try self.open('[');
            const frame = &frames[count.* - 1];
            frame.phase = .vector;
            frame.limit = @typeInfo(T).vector.len;
        }

        fn advanceVector(
            self: *Host,
            comptime T: type,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            if (comptime @typeInfo(T) != .vector) unreachable;
            const info = @typeInfo(T).vector;
            const frame = &frames[count.* - 1];
            if (frame.index == frame.limit) {
                try self.close(']', frame.limit != 0);
                return finishTyped(self, frames, count);
            }
            const index = frame.index;
            frame.index += 1;
            try self.separator(index);
            const values: [info.len]info.child = sourcePointer(T, frame).*;
            const item = values[index];
            switch (@typeInfo(info.child)) {
                .bool => try self.sink.writeAll(if (item) "true" else "false"),
                .int => try scalar.writeInteger(&self.sink, item),
                .float => try scalar.writeFloat(&self.sink, item),
                .pointer => try beginVectorPointer(self, item, frames, count),
                else => @compileError("unsupported JSON vector child type"),
            }
        }

        fn beginVectorPointer(
            self: *Host,
            value: anytype,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) FullError!void {
            const T = @TypeOf(value);
            const info = @typeInfo(T).pointer;
            switch (info.size) {
                .one => {
                    if (@typeInfo(info.child) == .array and
                        @typeInfo(info.child).array.child == u8)
                    {
                        return self.writeString(value[0..]);
                    }
                    const tracked = try self.pushPointerReference(T, value);
                    try pushTyped(frames, count, info.child, value, @intFromBool(tracked));
                },
                .slice => {
                    if (info.child == u8) return self.writeString(value);
                    const tracked = try self.pushSliceReference(info.child, value.ptr, value.len);
                    try pushRawSlice(
                        self,
                        frames,
                        count,
                        info.child,
                        value.ptr,
                        value.len,
                        @intFromBool(tracked),
                    );
                },
                .many => {
                    if (info.sentinel() == null) {
                        @compileError("JSON many pointer requires a sentinel");
                    }
                    const slice = std.mem.span(value);
                    if (info.child == u8) return self.writeString(slice);
                    const tracked = try self.pushSliceReference(info.child, slice.ptr, slice.len);
                    try pushRawSlice(
                        self,
                        frames,
                        count,
                        info.child,
                        slice.ptr,
                        slice.len,
                        @intFromBool(tracked),
                    );
                },
                .c => @compileError("unable to encode C pointer '" ++ @typeName(T) ++ "'"),
            }
        }

        fn pushRawSlice(
            self: *Host,
            frames: *[frame_capacity]Frame,
            count: *u16,
            comptime Child: type,
            pointer: [*]const Child,
            length: usize,
            references_owned: u16,
        ) FullError!void {
            if (count.* == frames.len) return error.MaxDepthExceeded;
            try self.open('[');
            const frame = &frames[count.*];
            frame.* = typedFrame(Child, @as(*const Child, @ptrCast(pointer)));
            frame.phase = .raw_slice;
            frame.limit = length;
            frame.references_owned = references_owned;
            count.* += 1;
        }

        fn finishTyped(
            self: *Host,
            frames: *[frame_capacity]Frame,
            count: *u16,
        ) void {
            var remaining = frames[count.* - 1].references_owned;
            while (remaining != 0) : (remaining -= 1) self.popReference();
            count.* -= 1;
        }

        fn sourcePointer(comptime T: type, frame: *const Frame) *const T {
            return @ptrCast(@alignCast(frame.source));
        }

        fn replaceTyped(frame: *Frame, comptime T: type, source: *const T) void {
            const references_owned = frame.references_owned;
            frame.* = typedFrame(T, source);
            frame.references_owned = references_owned;
        }

        fn pushTyped(
            frames: *[frame_capacity]Frame,
            count: *u16,
            comptime T: type,
            source: *const T,
            references_owned: u16,
        ) FullError!void {
            if (count.* == frames.len) return error.MaxDepthExceeded;
            frames[count.*] = typedFrame(T, source);
            frames[count.*].references_owned = references_owned;
            count.* += 1;
        }

        fn comptimeOnly(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .comptime_int, .comptime_float, .enum_literal, .null => true,
                else => false,
            };
        }

        fn hasHook(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"enum", .@"struct", .@"union" => std.meta.hasFn(T, "jsonStringify"),
                else => false,
            };
        }

        fn comptimeFieldPointer(
            comptime field: std.builtin.Type.StructField,
        ) *const field.type {
            const Static = struct {
                const value: field.type = field.defaultValue().?;
            };
            return &Static.value;
        }
    };
}

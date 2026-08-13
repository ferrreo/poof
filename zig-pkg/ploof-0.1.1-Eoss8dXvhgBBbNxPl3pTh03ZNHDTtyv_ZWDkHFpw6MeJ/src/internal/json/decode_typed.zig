const std = @import("std");
const hook = @import("parse_hook.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");

const FieldIssue = enum {
    packed_layout,
    comptime_field,
};

fn fieldIssue(comptime T: type) ?FieldIssue {
    const info = @typeInfo(T).@"struct";
    if (info.layout == .@"packed") return .packed_layout;
    inline for (info.fields) |field| if (field.is_comptime) return .comptime_field;
    return null;
}

fn fieldDiagnostic(issue: FieldIssue) []const u8 {
    return switch (issue) {
        .packed_layout => "PLOOF-E3272 packed structs are unsupported by JSON decode",
        .comptime_field => "PLOOF-E3273 comptime fields are unsupported by JSON decode",
    };
}

pub fn validateType(comptime T: type) void {
    validateTypeInner(T, .{});
}

pub const direct_depth_max: u8 = 16;

pub fn usesDirectTraversal(comptime T: type) bool {
    return directShape(T, .{}, direct_depth_max);
}

fn directShape(
    comptime T: type,
    comptime seen: anytype,
    comptime depth_remaining: u8,
) bool {
    if (T == types.Value or T == types.Number or hook.has(T)) return true;
    const info = @typeInfo(T);
    switch (info) {
        .optional, .array, .vector, .pointer, .@"struct", .@"union" => {},
        else => return true,
    }
    if (depth_remaining == 0) return false;
    inline for (seen) |Seen| if (T == Seen) return false;
    const next = seen ++ .{T};
    return switch (info) {
        .optional => |child| directShape(child.child, next, depth_remaining - 1),
        .array => |child| directShape(child.child, next, depth_remaining - 1),
        .vector => |child| directShape(child.child, next, depth_remaining - 1),
        .pointer => |child| directShape(child.child, next, depth_remaining - 1),
        .@"struct" => |structure| fields: {
            inline for (structure.fields) |field| {
                if (!directShape(field.type, next, depth_remaining - 1)) {
                    break :fields false;
                }
            }
            break :fields true;
        },
        .@"union" => |union_info| fields: {
            inline for (union_info.fields) |field| {
                if (!directShape(field.type, next, depth_remaining - 1)) {
                    break :fields false;
                }
            }
            break :fields true;
        },
        else => unreachable,
    };
}

fn validateTypeInner(comptime T: type, comptime seen: anytype) void {
    inline for (seen) |Seen| if (T == Seen) return;
    if (T == types.Value or T == types.Number or hook.has(T)) return;
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        .optional => |info| validateTypeInner(info.child, next),
        .array => |info| validateTypeInner(info.child, next),
        .vector => |info| validateTypeInner(info.child, next),
        .pointer => |info| validateTypeInner(info.child, next),
        .@"struct" => |info| {
            if (fieldIssue(T)) |issue| @compileError(fieldDiagnostic(issue));
            inline for (info.fields) |field| validateTypeInner(field.type, next);
        },
        .@"union" => |info| inline for (info.fields) |field| {
            validateTypeInner(field.type, next);
        },
        else => {},
    }
}

pub fn Traversal(
    comptime Adapter: type,
    comptime DecodeError: type,
    comptime RawToken: type,
    comptime depth_hard_max: u16,
) type {
    return struct {
        const Self = @This();

        pub const Pending = struct {
            destination: *anyopaque,
            token: RawToken,
            decode: *const fn (
                *Adapter,
                *Machine,
                *anyopaque,
                RawToken,
            ) DecodeError!?Pending,
        };

        const Field = struct {
            name: []const u8,
            offset: usize,
            decode: @FieldType(Pending, "decode"),
            accepted: bool,
            required: bool,
        };

        pub const Frame = struct {
            destination: *anyopaque,
            items: [*]u8 = undefined,
            index: usize = 0,
            length: usize = 0,
            stride: usize = 0,
            required_remaining: usize = 0,
            child_decode: @FieldType(Pending, "decode") = undefined,
            fields: []const Field = &.{},
            finish: *const fn (*Frame) void = finishSequence,
            continuation: *const fn (
                *Adapter,
                *Machine,
                *Frame,
            ) DecodeError!?Pending,
        };

        pub const Machine = struct {
            frames: []Frame,
            count: u16 = 0,
            limit: u16,

            pub fn push(
                self: *Machine,
                destination: anytype,
                continuation: @FieldType(Frame, "continuation"),
            ) DecodeError!*Frame {
                if (self.count == self.limit or self.count == self.frames.len) {
                    return error.DepthLimitExceeded;
                }
                const frame = &self.frames[self.count];
                self.count += 1;
                frame.* = .{
                    .destination = @ptrCast(destination),
                    .continuation = continuation,
                };
                return frame;
            }
        };

        pub fn run(
            comptime T: type,
            adapter: *Adapter,
            destination: *T,
        ) DecodeError!void {
            const token = try adapter.typedNextRaw();
            const depth_max = adapter.typedDepthMax();
            if (depth_max <= 64) return runCapacity(T, adapter, destination, token, 64);
            if (depth_max <= 128) return runCapacity(T, adapter, destination, token, 128);
            return runCapacity(T, adapter, destination, token, depth_hard_max);
        }

        fn runCapacity(
            comptime T: type,
            adapter: *Adapter,
            destination: *T,
            token: RawToken,
            comptime capacity: usize,
        ) DecodeError!void {
            var frames: [capacity]Frame = undefined;
            var machine = Machine{
                .frames = &frames,
                .limit = adapter.typedDepthMax(),
            };
            var current = pending(T, destination, token);
            while (true) {
                if (try current.decode(
                    adapter,
                    &machine,
                    current.destination,
                    current.token,
                )) |child| {
                    current = child;
                    continue;
                }
                while (machine.count != 0) {
                    const frame = &machine.frames[machine.count - 1];
                    if (try frame.continuation(adapter, &machine, frame)) |child| {
                        current = child;
                        break;
                    }
                    machine.count -= 1;
                } else return;
            }
        }

        pub fn pending(
            comptime T: type,
            destination: *T,
            token: RawToken,
        ) Pending {
            return .{
                .destination = @ptrCast(destination),
                .token = token,
                .decode = decodeFunction(T),
            };
        }

        fn decodeFunction(comptime T: type) @FieldType(Pending, "decode") {
            return struct {
                fn decode(
                    adapter: *Adapter,
                    machine: *Machine,
                    destination: *anyopaque,
                    token: RawToken,
                ) DecodeError!?Pending {
                    const typed: *T = @ptrCast(@alignCast(destination));
                    return adapter.typedDecodeInto(T, typed, token, machine);
                }
            }.decode;
        }

        pub fn pushSequence(
            machine: *Machine,
            comptime Child: type,
            values: []Child,
        ) DecodeError!void {
            const frame = try machine.push(values.ptr, continueSequence);
            initSequence(frame, Child, values);
        }

        pub fn initSequence(frame: *Frame, comptime Child: type, values: []Child) void {
            frame.items = @ptrCast(values.ptr);
            frame.length = values.len;
            frame.stride = @sizeOf(Child);
            frame.child_decode = decodeFunction(Child);
        }

        fn nextSequence(adapter: *Adapter, frame: *Frame) DecodeError!?Pending {
            if (frame.index == frame.length) {
                try expectToken(try adapter.typedNextRaw(), .array_end);
                return null;
            }
            const offset = frame.index * frame.stride;
            frame.index += 1;
            return .{
                .destination = &frame.items[offset],
                .token = try adapter.typedNextRaw(),
                .decode = frame.child_decode,
            };
        }

        fn finishSequence(_: *Frame) void {}

        pub fn vectorFinish(
            comptime T: type,
            comptime Child: type,
            comptime length: usize,
        ) *const fn (*Frame) void {
            return struct {
                fn finish(frame: *Frame) void {
                    const destination: *T = @ptrCast(@alignCast(frame.destination));
                    const values: [*]Child = @ptrCast(@alignCast(frame.items));
                    inline for (0..length) |index| destination.*[index] = values[index];
                }
            }.finish;
        }

        pub fn fields(
            comptime T: type,
            comptime struct_fields: []const std.builtin.Type.StructField,
            comptime object: bool,
        ) []const Field {
            const issue = comptime fieldIssue(T);
            if (issue) |problem| @compileError(fieldDiagnostic(problem));
            const Table = struct {
                const values = build();

                fn build() [struct_fields.len]Field {
                    var result: [struct_fields.len]Field = undefined;
                    for (struct_fields, 0..) |field, index| result[index] = .{
                        .name = if (object) schema.wireName(T, field.name) else "",
                        .offset = @offsetOf(T, field.name),
                        .decode = decodeFunction(field.type),
                        .accepted = !object or field.type != void,
                        .required = object and
                            field.type != void and
                            field.default_value_ptr == null,
                    };
                    return result;
                }
            };
            return &Table.values;
        }

        fn fieldDestination(frame: *Frame, field: Field) *anyopaque {
            const bytes: [*]u8 = @ptrCast(frame.destination);
            return &bytes[field.offset];
        }

        pub fn continueSequence(
            adapter: *Adapter,
            _: *Machine,
            frame: *Frame,
        ) DecodeError!?Pending {
            const current = try nextSequence(adapter, frame);
            if (current == null) frame.finish(frame);
            return current;
        }

        pub fn continueTuple(
            adapter: *Adapter,
            _: *Machine,
            frame: *Frame,
        ) DecodeError!?Pending {
            if (frame.index == frame.fields.len) {
                try expectToken(try adapter.typedNextRaw(), .array_end);
                return null;
            }
            const field = frame.fields[frame.index];
            frame.index += 1;
            return .{
                .destination = fieldDestination(frame, field),
                .token = try adapter.typedNextRaw(),
                .decode = field.decode,
            };
        }

        pub fn continueStruct(
            adapter: *Adapter,
            _: *Machine,
            frame: *Frame,
        ) DecodeError!?Pending {
            while (true) {
                const key = try adapter.typedNextRaw();
                if (key == .object_end) {
                    if (frame.required_remaining != 0) return error.MissingField;
                    return null;
                }
                const name = try adapter.typedString(key);
                for (frame.fields) |field| {
                    if (!field.accepted or !std.mem.eql(u8, name, field.name)) continue;
                    if (field.required) frame.required_remaining -= 1;
                    return .{
                        .destination = fieldDestination(frame, field),
                        .token = try adapter.typedNextRaw(),
                        .decode = field.decode,
                    };
                }
                try adapter.typedUnknown();
            }
        }

        pub fn continueUnionEnd(
            adapter: *Adapter,
            _: *Machine,
            _: *Frame,
        ) DecodeError!?Pending {
            try expectToken(try adapter.typedNextRaw(), .object_end);
            return null;
        }

        fn expectToken(
            actual: RawToken,
            comptime expected: std.meta.Tag(RawToken),
        ) DecodeError!void {
            if (std.meta.activeTag(actual) != expected) return error.TypeMismatch;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "type-erased field destinations reject non-addressable layouts" {
    const Packed = packed struct { value: u8 };
    const Comptime = struct { comptime value: u8 = 1 };
    try std.testing.expectEqual(FieldIssue.packed_layout, fieldIssue(Packed).?);
    try std.testing.expectEqual(FieldIssue.comptime_field, fieldIssue(Comptime).?);
    try std.testing.expect(fieldIssue(struct { value: u8 align(64) }) == null);
    try std.testing.expect(fieldIssue(struct { value: void }) == null);
}

test "only shallow acyclic typed shapes select direct traversal" {
    const Flat = struct {
        id: u64,
        name: []const u8,
        values: []const u16,
        nested: struct { note: ?[]const u8 },
    };
    const Recursive = struct {
        const Self = @This();
        next: ?*Self,
    };
    const Shapes = struct {
        fn Chain(comptime depth: usize) type {
            if (depth == 0) return u8;
            return struct { child: Chain(depth - 1) };
        }
    };
    try std.testing.expect(usesDirectTraversal(Flat));
    try std.testing.expect(!usesDirectTraversal(Recursive));
    try std.testing.expect(usesDirectTraversal(Shapes.Chain(16)));
    try std.testing.expect(!usesDirectTraversal(Shapes.Chain(17)));
}

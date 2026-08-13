const decode_token = @import("decode_token.zig");
const token_source = @import("token_source.zig");
const types = @import("types.zig");

const Container = enum(u8) { array, object };

const Pending = struct {
    value: *types.Value,
    token: token_source.RawToken,
};

const Frame = union(Container) {
    array: struct { values: []types.Value, next_index: usize },
    object: struct { members: []types.Member, next_index: usize },
};

pub fn Traversal(comptime Decoder: type, comptime Error: type) type {
    return struct {
        pub fn read(decoder: *Decoder, token: token_source.RawToken) Error!types.Value {
            const depth_max = decoder.dynamicDepthMax();
            if (depth_max <= 8) return readCapacity(decoder, 8, token);
            if (depth_max <= 16) return readCapacity(decoder, 16, token);
            if (depth_max <= 32) return readCapacity(decoder, 32, token);
            if (depth_max <= 64) return readCapacity(decoder, 64, token);
            if (depth_max <= 128) return readCapacity(decoder, 128, token);
            return readCapacity(decoder, token_source.depth_hard_max, token);
        }

        fn readCapacity(
            decoder: *Decoder,
            comptime capacity: usize,
            token: token_source.RawToken,
        ) Error!types.Value {
            var root: types.Value = undefined;
            var frames: [capacity]Frame = undefined;
            var frame_count: u16 = 0;
            var pending = Pending{ .value = &root, .token = token };
            while (true) {
                if (try readValue(decoder, capacity, pending, &frames, &frame_count)) |child| {
                    pending = child;
                    continue;
                }
                while (frame_count != 0) {
                    const frame = &frames[frame_count - 1];
                    const next: ?Pending = switch (frame.*) {
                        .array => |*array| if (array.next_index < array.values.len) next: {
                            const index = array.next_index;
                            array.next_index += 1;
                            break :next .{
                                .value = &array.values[index],
                                .token = try decoder.nextRaw(),
                            };
                        } else end: {
                            try decode_token.expect(try decoder.nextRaw(), .array_end);
                            break :end null;
                        },
                        .object => |*object| if (object.next_index < object.members.len) next: {
                            const index = object.next_index;
                            object.next_index += 1;
                            object.members[index].name = try decoder.persist(
                                try decoder.stringText(try decoder.nextRaw()),
                            );
                            break :next .{
                                .value = &object.members[index].value,
                                .token = try decoder.nextRaw(),
                            };
                        } else end: {
                            try decode_token.expect(try decoder.nextRaw(), .object_end);
                            break :end null;
                        },
                    };
                    if (next) |child| {
                        pending = child;
                        break;
                    }
                    frame_count -= 1;
                } else return root;
            }
        }

        fn readValue(
            decoder: *Decoder,
            comptime capacity: usize,
            pending: Pending,
            frames: *[capacity]Frame,
            frame_count: *u16,
        ) Error!?Pending {
            pending.value.* = switch (pending.token) {
                .null => .null,
                .true => .{ .boolean = true },
                .false => .{ .boolean = false },
                .number, .partial_number => .{
                    .number = try decoder.readNumberValue(pending.token, true),
                },
                .string,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => .{ .string = try decoder.persist(
                    try decoder.stringText(pending.token),
                ) },
                .array_begin => return beginArray(
                    decoder,
                    capacity,
                    pending.value,
                    frames,
                    frame_count,
                ),
                .object_begin => return beginObject(
                    decoder,
                    capacity,
                    pending.value,
                    frames,
                    frame_count,
                ),
                else => return error.TypeMismatch,
            };
            return null;
        }

        fn beginArray(
            decoder: *Decoder,
            comptime capacity: usize,
            value: *types.Value,
            frames: *[capacity]Frame,
            frame_count: *u16,
        ) Error!?Pending {
            const count = try decoder.dynamicTakePlan(.array);
            const values = try decoder.dynamicAllocate(types.Value, count);
            value.* = .{ .array = values };
            if (values.len == 0) {
                try decode_token.expect(try decoder.nextRaw(), .array_end);
                return null;
            }
            if (frame_count.* == frames.len) return error.DepthLimitExceeded;
            frames[frame_count.*] = .{ .array = .{ .values = values, .next_index = 1 } };
            frame_count.* += 1;
            return .{ .value = &values[0], .token = try decoder.nextRaw() };
        }

        fn beginObject(
            decoder: *Decoder,
            comptime capacity: usize,
            value: *types.Value,
            frames: *[capacity]Frame,
            frame_count: *u16,
        ) Error!?Pending {
            const count = try decoder.dynamicTakePlan(.object);
            const members = try decoder.dynamicAllocate(types.Member, count);
            value.* = .{ .object = members };
            if (members.len == 0) {
                try decode_token.expect(try decoder.nextRaw(), .object_end);
                return null;
            }
            if (frame_count.* == frames.len) return error.DepthLimitExceeded;
            members[0].name = try decoder.persist(
                try decoder.stringText(try decoder.nextRaw()),
            );
            frames[frame_count.*] = .{ .object = .{ .members = members, .next_index = 1 } };
            frame_count.* += 1;
            return .{ .value = &members[0].value, .token = try decoder.nextRaw() };
        }

        pub fn skip(decoder: *Decoder, token: token_source.RawToken) Error!void {
            const depth_max = decoder.dynamicDepthMax();
            if (depth_max <= 8) return skipCapacity(decoder, 8, token);
            if (depth_max <= 16) return skipCapacity(decoder, 16, token);
            if (depth_max <= 32) return skipCapacity(decoder, 32, token);
            if (depth_max <= 64) return skipCapacity(decoder, 64, token);
            if (depth_max <= 128) return skipCapacity(decoder, 128, token);
            return skipCapacity(decoder, token_source.depth_hard_max, token);
        }

        fn skipCapacity(
            decoder: *Decoder,
            comptime capacity: usize,
            token: token_source.RawToken,
        ) Error!void {
            var frames: [capacity]Container = undefined;
            var frame_count: u16 = 0;
            var current = token;
            while (true) {
                try skipValue(decoder, capacity, current, &frames, &frame_count);
                while (frame_count != 0) {
                    const kind = frames[frame_count - 1];
                    const next = try decoder.nextRaw();
                    if (kind == .array and next == .array_end or
                        kind == .object and next == .object_end)
                    {
                        frame_count -= 1;
                        continue;
                    }
                    if (kind == .object) try decoder.discardString(next);
                    current = if (kind == .object) try decoder.nextRaw() else next;
                    break;
                } else return;
            }
        }

        fn skipValue(
            decoder: *Decoder,
            comptime capacity: usize,
            token: token_source.RawToken,
            frames: *[capacity]Container,
            frame_count: *u16,
        ) Error!void {
            const kind: ?Container = switch (token) {
                .object_begin => .object,
                .array_begin => .array,
                .number, .partial_number => return decoder.discardNumber(token),
                .string,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => return decoder.discardString(token),
                .true, .false, .null => return,
                else => return error.TypeMismatch,
            };
            if (frame_count.* == frames.len) return error.DepthLimitExceeded;
            frames[frame_count.*] = kind.?;
            frame_count.* += 1;
        }
    };
}

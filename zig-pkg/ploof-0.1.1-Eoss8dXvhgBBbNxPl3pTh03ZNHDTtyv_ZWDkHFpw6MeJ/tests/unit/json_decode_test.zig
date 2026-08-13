pub const std = @import("std");
pub const body = @import("../../src/body.zig");
pub const decode = @import("../../src/internal/json/decode.zig");
pub const fuzz_support = @import("../../src/internal/http1/testing/smith.zig");
pub const json = @import("../../src/json.zig");
pub const schema = @import("../../src/internal/json/schema.zig");
pub const types = @import("../../src/internal/json/types.zig");
pub const validate = @import("../../src/internal/json/validate.zig");

pub const hash_key = [_]u8{
    0x8e, 0x31, 0x77, 0x04, 0x52, 0xae, 0xd9, 0x63,
    0xc4, 0x1b, 0xf0, 0x29, 0x95, 0x46, 0xba, 0x0d,
};

pub const Mode = enum {
    fast,
    safe,
};

pub const Record = struct {
    id: u16,
    label: []const u8,
    note: ?[]const u8 = null,
    mode: Mode = .fast,

    pub const ploof_json_fields = .{
        .id = schema.field(.{ .rename = "recordId" }),
        .note = schema.field(.{ .omit_if_null = true }),
    };
};

pub const HookSeconds = struct {
    value: i64,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        const wire = try parser.parse(struct { seconds: i64 });
        if (wire.seconds < 0) return error.InvalidValue;
        return .{ .value = wire.seconds };
    }
};

pub const HookList = struct {
    items: []const u64,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        const wire = try parser.parse(struct { items: []const u64 });
        return .{ .items = wire.items };
    }
};

pub const HookMutableString = struct {
    value: []u8,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        return .{ .value = try parser.parse([]u8) };
    }
};

pub fn FailingHook(comptime problem: json.ParseError) type {
    return struct {
        pub fn jsonParse(_: anytype) json.ParseError!@This() {
            return problem;
        }
    };
}

pub const CursorTotal = struct {
    total: i64,
    enabled: bool,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        var object = try parser.object();
        const values_value = object.get("values") orelse return error.InvalidValue;
        var values = try values_value.array();
        var total: i64 = 0;
        while (values.next()) |item| {
            total = std.math.add(i64, total, try item.parse(i64)) catch {
                return error.InvalidValue;
            };
        }
        const enabled = object.get("enabled") orelse return error.InvalidValue;
        if (enabled.kind() != .boolean) return error.TypeMismatch;
        return .{ .total = total, .enabled = try enabled.boolean() };
    }
};

pub const fuzz_corpus = struct {
    const object = fuzz_support.smithInput("{\"a\":1,\"b\":[true,null]}");
    const escaped = fuzz_support.smithInput("{\"\\u0061\":\"x\\u0021\"}");
    const unicode = fuzz_support.smithInput("[\"€\",-12.50e+2]");
    const malformed = fuzz_support.smithInput("{\"a\":");
    const values = [_][]const u8{ &object, &escaped, &unicode, &malformed };
}.values;

pub const custom_fuzz_corpus = struct {
    const valid = fuzz_support.smithInput("{\"seconds\":12}");
    const invalid = fuzz_support.smithInput("{\"seconds\":-1}");
    const malformed = fuzz_support.smithInput("{\"seconds\":");
    const values = [_][]const u8{ &valid, &invalid, &malformed };
}.values;

pub fn fuzzCustomDecode(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [256]u8 = undefined;
    const document = input_storage[0..smith.slice(&input_storage)];
    const single_chunks = [_]body.Chunk{body.Chunk.init(document)};
    var fragmented_chunks: [input_storage.len]body.Chunk = undefined;
    for (document, 0..) |_, index| {
        fragmented_chunks[index] = body.Chunk.init(document[index .. index + 1]);
    }
    const single_input = try body.Bytes.init(&single_chunks);
    const fragmented_input = try body.Bytes.init(fragmented_chunks[0..document.len]);
    var single_workspace: [32768]u8 align(validate.scratch_alignment) = undefined;
    var fragmented_workspace: [32768]u8 align(validate.scratch_alignment) = undefined;
    var single_error: ?decode.Error = null;
    var fragmented_error: ?decode.Error = null;
    const single = decode.decode(
        HookSeconds,
        single_input,
        &single_workspace,
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        single_error = problem;
        break :failed null;
    };
    const fragmented = decode.decode(
        HookSeconds,
        fragmented_input,
        &fragmented_workspace,
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        fragmented_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(single_error, fragmented_error);
    if (single) |left| {
        try std.testing.expectEqual(left.value.value, fragmented.?.value.value);
    }
}

pub fn fuzzDecode(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const document = input_storage[0..smith.slice(&input_storage)];
    const single_chunks = [_]body.Chunk{body.Chunk.init(document)};
    var fragmented_chunks: [input_storage.len]body.Chunk = undefined;
    for (document, 0..) |_, index| {
        fragmented_chunks[index] = body.Chunk.init(document[index .. index + 1]);
    }
    const single_input = try body.Bytes.init(&single_chunks);
    const fragmented_input = try body.Bytes.init(fragmented_chunks[0..document.len]);
    var single_workspace: [65536]u8 align(validate.scratch_alignment) = undefined;
    var fragmented_workspace: [65536]u8 align(validate.scratch_alignment) = undefined;
    var single_error: ?decode.Error = null;
    var fragmented_error: ?decode.Error = null;
    const single = decode.decodeValue(
        single_input,
        &single_workspace,
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        single_error = problem;
        break :failed null;
    };
    const fragmented = decode.decodeValue(
        fragmented_input,
        &fragmented_workspace,
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        fragmented_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(single_error, fragmented_error);
    if (single) |left| try expectValuesEqual(left.value.*, fragmented.?.value.*);
}

pub fn expectValuesEqual(left: types.Value, right: types.Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
    switch (left) {
        .null => {},
        .boolean => |value| try std.testing.expectEqual(value, right.boolean),
        .number => |value| {
            try std.testing.expectEqualStrings(value.lexeme, right.number.lexeme);
        },
        .string => |value| try std.testing.expectEqualStrings(value, right.string),
        .array => |values| {
            try std.testing.expectEqual(values.len, right.array.len);
            for (values, right.array) |a, b| try expectValuesEqual(a, b);
        },
        .object => |members| {
            try std.testing.expectEqual(members.len, right.object.len);
            for (members, right.object) |a, b| {
                try std.testing.expectEqualStrings(a.name, b.name);
                try expectValuesEqual(a.value, b.value);
            }
        },
    }
}

pub fn expectTyped(comptime T: type, document: []const u8, expected: T) !void {
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqual(expected, result.value.*);
}

pub fn expectTypedError(
    comptime T: type,
    document: []const u8,
    expected: decode.Error,
) !void {
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(
        expected,
        decode.decode(T, input, &workspace, .{ .hash_key = hash_key }),
    );
}

pub fn expectPointerIn(pointer: [*]const u8, bytes: []const u8) !void {
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(bytes.ptr);
    try std.testing.expect(address >= start and address < start + bytes.len);
}

test {
    _ = @import("json_decode_test_part_1.zig");
    _ = @import("json_parse_hook_stack_test.zig");
}

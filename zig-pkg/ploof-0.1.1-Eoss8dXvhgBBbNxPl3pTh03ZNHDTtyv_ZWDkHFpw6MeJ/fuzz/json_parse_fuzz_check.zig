const std = @import("std");
const body = @import("../src/body.zig");
const decode = @import("../src/internal/json/decode.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const json = @import("../src/json.zig");
const validate = @import("../src/internal/json/validate.zig");

const hash_key = [_]u8{
    0x63, 0x49, 0xa1, 0x2e, 0x75, 0xc8, 0x04, 0xdb,
    0xf0, 0x16, 0x8b, 0x31, 0x97, 0x5a, 0xec, 0x42,
};

const Item = struct {
    value: u16,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        const wire = try parser.parse(struct { value: u16 });
        return .{ .value = wire.value };
    }
};

const Payload = struct {
    label: []const u8,
    items: []const Item,
    enabled: bool,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        const object = try parser.object();
        const label = object.get("label") orelse return error.InvalidValue;
        const items = object.get("items") orelse return error.InvalidValue;
        const enabled = object.get("enabled") orelse return error.InvalidValue;
        return .{
            .label = try label.parse([]const u8),
            .items = try items.parse([]const Item),
            .enabled = try enabled.boolean(),
        };
    }
};

const corpus = struct {
    const structured = fuzz_support.smithInput(
        "{\"label\":\"zig\\u0021\",\"items\":[{\"value\":1},{\"value\":2}]," ++
            "\"enabled\":true}",
    );
    const empty = fuzz_support.smithInput(
        "{\"label\":\"\",\"items\":[],\"enabled\":false}",
    );
    const malformed = fuzz_support.smithInput(
        "{\"label\":\"\\ud800\",\"items\":[",
    );
    const values = [_][]const u8{ &structured, &empty, &malformed };
}.values;

test "structured jsonParse fuzz is fragmentation and memory-bound equivalent" {
    try std.testing.fuzz({}, fuzzStructured, .{ .corpus = &corpus });
}

fn fuzzStructured(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const document = input_storage[0..smith.slice(&input_storage)];
    const single_chunks = [_]body.Chunk{body.Chunk.init(document)};
    var fragmented_chunks: [input_storage.len]body.Chunk = undefined;
    for (document, 0..) |_, index| {
        fragmented_chunks[index] = body.Chunk.init(document[index .. index + 1]);
    }
    const single_input = try body.Bytes.init(&single_chunks);
    const fragmented_input = try body.Bytes.init(fragmented_chunks[0..document.len]);
    inline for ([_]usize{ 512, 32768 }) |memory_limit| {
        try expectEquivalent(single_input, fragmented_input, memory_limit);
    }
}

fn expectEquivalent(
    single_input: body.Bytes,
    fragmented_input: body.Bytes,
    memory_limit: usize,
) !void {
    var single_workspace: [32768]u8 align(validate.scratch_alignment) = undefined;
    var fragmented_workspace: [32768]u8 align(validate.scratch_alignment) = undefined;
    var single_error: ?decode.Error = null;
    var fragmented_error: ?decode.Error = null;
    const single = decode.decode(
        Payload,
        single_input,
        single_workspace[0..memory_limit],
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        single_error = problem;
        break :failed null;
    };
    const fragmented = decode.decode(
        Payload,
        fragmented_input,
        fragmented_workspace[0..memory_limit],
        .{ .hash_key = hash_key },
    ) catch |problem| failed: {
        fragmented_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(single_error, fragmented_error);
    if (single) |left| {
        const right = fragmented.?;
        try std.testing.expectEqualStrings(left.value.label, right.value.label);
        try std.testing.expectEqual(left.value.enabled, right.value.enabled);
        try std.testing.expectEqual(left.value.items.len, right.value.items.len);
        for (left.value.items, right.value.items) |a, b| {
            try std.testing.expectEqual(a.value, b.value);
        }
    }
}

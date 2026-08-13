const builtin = @import("builtin");
const std = @import("std");
const json = @import("../../src/json.zig");

test "typed encoding preserves declaration order exact integers and explicit null policy" {
    const Payload = struct {
        last: bool,
        exact: i128,
        visible_null: ?u8,
        hidden_null: ?[]const u8,
        empty: []const u8,
        zero: u8,

        pub const ploof_json_fields = .{
            .last = json.field(.{ .rename = "isLast" }),
            .hidden_null = json.field(.{ .omit_if_null = true }),
        };
    };
    const value = Payload{
        .last = false,
        .exact = -170141183460469231731687303715884105728,
        .visible_null = null,
        .hidden_null = null,
        .empty = "",
        .zero = 0,
    };
    var output: [512]u8 = undefined;
    const encoded = try json.encode(value, &output);
    try std.testing.expectEqualStrings(
        "{\"isLast\":false,\"exact\":-170141183460469231731687303715884105728," ++
            "\"visible_null\":null,\"empty\":\"\",\"zero\":0}",
        encoded,
    );
}

test "strings retain UTF-8 and escape only required bytes by default" {
    const value = .{ .text = "Grüße <tag> \"x\"\n\x01" };
    var output: [128]u8 = undefined;
    const encoded = try json.encode(value, &output);
    try std.testing.expectEqualStrings(
        "{\"text\":\"Grüße <tag> \\\"x\\\"\\n\\u0001\"}",
        encoded,
    );
}

test "indentation and HTML-safe escaping are comptime options" {
    const value = .{ .script = "</script>&'\u{2028}" };
    var output: [256]u8 = undefined;
    const encoded = try json.encodeWith(.{
        .whitespace = .indent_2,
        .html_safe = true,
    }, value, &output);
    try std.testing.expectEqualStrings(
        "{\n  \"script\": \"\\u003c/script\\u003e\\u0026\\u0027\\u2028\"\n}",
        encoded,
    );
}

test "dynamic values retain member order and validated number lexemes" {
    const number = try json.Number.init("123456789012345678901234567890.125e-9");
    const items = [_]json.Value{
        .{ .number = number },
        .{ .string = "ok" },
    };
    const members = [_]json.Member{
        .{ .name = "items", .value = .{ .array = &items } },
        .{ .name = "enabled", .value = .{ .boolean = true } },
    };
    const value = json.Value{ .object = &members };
    var output: [256]u8 = undefined;
    const encoded = try json.encode(value, &output);
    try std.testing.expectEqualStrings(
        "{\"items\":[123456789012345678901234567890.125e-9,\"ok\"],\"enabled\":true}",
        encoded,
    );
    const enabled = try value.get("enabled");
    try std.testing.expect(enabled.* == .boolean);
    try std.testing.expect(enabled.boolean);
}

test "dynamic numbers reject malformed lexemes and convert exactly" {
    for ([_][]const u8{ "", "+1", "01", "1.", "NaN", "Infinity", "1e" }) |input| {
        try std.testing.expectError(error.InvalidNumber, json.Number.init(input));
    }
    const integer = try json.Number.init("9223372036854775807");
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try integer.asInt(i64));
    try std.testing.expectError(error.Overflow, integer.asInt(i32));
    const fraction = try json.Number.init("1.5");
    try std.testing.expectError(error.InvalidNumber, fraction.asInt(i64));
    try std.testing.expectEqual(@as(f64, 1.5), try fraction.asFloat(f64));

    try std.testing.expectEqual(@as(i32, 100), try (try json.Number.init("1e2")).asInt(i32));
    try std.testing.expectEqual(@as(i32, 1), try (try json.Number.init("1.00")).asInt(i32));
    try std.testing.expectEqual(@as(i32, 1), try (try json.Number.init("100e-2")).asInt(i32));
    try std.testing.expectEqual(@as(i32, 12), try (try json.Number.init("1.2e1")).asInt(i32));
    try std.testing.expectEqual(@as(u8, 0), try (try json.Number.init("-0e999")).asInt(u8));
    try std.testing.expectError(
        error.InvalidNumber,
        (try json.Number.init("100e-3")).asInt(i32),
    );
    try std.testing.expectError(error.Overflow, (try json.Number.init("1e999")).asInt(i32));

    const forged = json.Number{ .lexeme = "01" };
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidNumber, json.encode(forged, &output));
}

test "invalid UTF-8 is rejected in typed strings and dynamic names" {
    const invalid = [_]u8{ 0xc0, 0x80 };
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, json.encode(invalid[0..], &output));

    const members = [_]json.Member{
        .{ .name = invalid[0..], .value = .null },
    };
    try std.testing.expectError(
        error.InvalidUtf8,
        json.encode(json.Value{ .object = &members }, &output),
    );
}

test "all non-finite float forms fail before success" {
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.NonFiniteFloat, json.encode(std.math.nan(f64), &output));
    try std.testing.expectError(error.NonFiniteFloat, json.encode(std.math.inf(f32), &output));
    try std.testing.expectError(error.NonFiniteFloat, json.encode(-std.math.inf(f64), &output));
    const finite = try json.encode(@as(f64, 1.25), &output);
    try std.testing.expectEqualStrings("1.25", finite);
}

test "output capacity and logical byte limit return no partial success" {
    const value = .{ .message = "bounded" };
    const expected = "{\"message\":\"bounded\"}";
    var exact: [expected.len]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try json.encode(value, &exact));

    var short: [expected.len - 1]u8 = @splat(0xaa);
    try std.testing.expectError(error.ResponseBodyTooLarge, json.encode(value, &short));

    var large: [64]u8 = @splat(0xaa);
    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        json.encodeWith(.{ .encoded_bytes_max = expected.len - 1 }, value, &large),
    );
}

test "maximum depth is enforced at its exact boundary" {
    var values: [json.depth_hard_max + 2]json.Value = undefined;
    const leaf_index = values.len - 1;
    values[leaf_index] = .null;
    var index: usize = leaf_index;
    while (index != 0) {
        index -= 1;
        values[index] = .{ .array = values[index + 1 .. index + 2] };
    }
    var output: [1024]u8 = undefined;
    const at_limit = try json.encode(values[leaf_index - 64], &output);
    try std.testing.expectEqual(@as(usize, 64 * 2 + 4), at_limit.len);
    try std.testing.expectError(
        error.MaxDepthExceeded,
        json.encode(values[leaf_index - 65], &output),
    );
    try std.testing.expectError(
        error.MaxDepthExceeded,
        json.encodeWith(.{ .max_depth = 2 }, values[leaf_index - 3], &output),
    );
    const hard_limit = try json.encodeWith(
        .{ .max_depth = json.depth_hard_max },
        values[leaf_index - json.depth_hard_max],
        &output,
    );
    try std.testing.expectEqual(@as(usize, json.depth_hard_max * 2 + 4), hard_limit.len);
    try std.testing.expectError(
        error.MaxDepthExceeded,
        json.encodeWith(
            .{ .max_depth = json.depth_hard_max },
            values[leaf_index - json.depth_hard_max - 1],
            &output,
        ),
    );
}

test "pointer and dynamic graph cycles are rejected while shared leaves are allowed" {
    const Node = struct {
        value: u8,
        next: ?*const @This(),
    };
    var node = Node{ .value = 1, .next = null };
    node.next = &node;
    const root: *const Node = &node;
    var output: [256]u8 = undefined;
    try std.testing.expectError(error.CircularReference, json.encode(root, &output));

    var cycle: [1]json.Value = undefined;
    cycle[0] = .{ .array = cycle[0..] };
    try std.testing.expectError(error.CircularReference, json.encode(cycle[0], &output));

    const leaf: u32 = 7;
    const aliases = .{ .first = &leaf, .second = &leaf };
    try std.testing.expectEqualStrings(
        "{\"first\":7,\"second\":7}",
        try json.encode(aliases, &output),
    );
}

test "typed recursive encoding reaches hard depth on a 64 KiB stack" {
    const Node = struct {
        value: u8,
        next: ?*const @This() = null,
    };
    const depth: usize = json.depth_hard_max;
    const Context = struct {
        nodes: [depth + 1]Node = undefined,
        at_limit_ok: bool = false,
        over_limit_ok: bool = false,

        fn run(self: *@This()) void {
            var output: [8 * 1024]u8 = undefined;
            const at_limit = json.encodeWith(
                .{ .max_depth = json.depth_hard_max },
                self.nodes[0],
                &output,
            ) catch return;
            self.at_limit_ok = at_limit.len != 0;
            self.nodes[depth - 1].next = &self.nodes[depth];
            _ = json.encodeWith(
                .{ .max_depth = json.depth_hard_max },
                self.nodes[0],
                &output,
            ) catch |problem| {
                self.over_limit_ok = problem == error.MaxDepthExceeded;
                return;
            };
        }
    };
    var context = Context{};
    for (&context.nodes, 0..) |*node, index| {
        node.* = .{ .value = @intCast(index % 10) };
    }
    for (0..depth - 1) |index| context.nodes[index].next = &context.nodes[index + 1];
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(
        .{ .stack_size = stack_size },
        Context.run,
        .{&context},
    );
    thread.join();
    try std.testing.expect(context.at_limit_ok);
    try std.testing.expect(context.over_limit_ok);
}

test "typed field storage forms retain stable representations" {
    const PackedInner = packed struct { a: u8, b: bool };
    const Packed = packed struct { inner: PackedInner, c: u8 };
    const Stored = struct {
        value: u8 align(64),
        empty: [2]struct {},
        comptime marker: u8 = 12,
    };
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"inner\":{\"a\":3,\"b\":true},\"c\":4}",
        try json.encode(Packed{ .inner = .{ .a = 3, .b = true }, .c = 4 }, &output),
    );
    try std.testing.expectEqualStrings(
        "{\"value\":13,\"empty\":[{},{}],\"marker\":12}",
        try json.encode(Stored{ .value = 13, .empty = .{ .{}, .{} } }, &output),
    );

    const left: u16 = 10;
    const right: u16 = 11;
    const pointers: @Vector(2, *const u16) = .{ &left, &right };
    try std.testing.expectEqualStrings("[10,11]", try json.encode(pointers, &output));
}

test "dynamic objects reject duplicate names" {
    const members = [_]json.Member{
        .{ .name = "same", .value = .null },
        .{ .name = "same", .value = .{ .boolean = false } },
    };
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        error.DuplicateField,
        json.encode(json.Value{ .object = &members }, &output),
    );
}

test "structured custom hook emits exactly one value and propagates finite errors" {
    const HookError = json.Error || error{Denied};
    const Custom = struct {
        denied: bool,
        pub const JsonApplicationError = error{Denied};

        pub fn jsonStringify(self: @This(), writer: anytype) HookError!void {
            if (self.denied) return error.Denied;
            try writer.beginObject();
            try writer.objectField("kind");
            try writer.write("custom");
            try writer.objectField("values");
            try writer.beginArray();
            try writer.write(@as(u8, 1));
            try writer.write(@as(u8, 2));
            try writer.endArray();
            try writer.endObject();
        }
    };
    try std.testing.expect(json.DeclaredEncodeError(Custom) == HookError);
    try std.testing.expect(json.CustomEncodeError(Custom) == error{Denied});
    try std.testing.expect(json.EncodeError(Custom) == HookError);
    try std.testing.expect(json.CustomEncodeError(struct { value: Custom }) == error{Denied});
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"kind\":\"custom\",\"values\":[1,2]}",
        try json.encode(Custom{ .denied = false }, &output),
    );
    try std.testing.expectError(error.Denied, json.encode(Custom{ .denied = true }, &output));
}

test "custom hook writer errors remain local across sibling hook types" {
    const Alpha = struct {
        denied: bool,
        pub const JsonApplicationError = error{AlphaDenied};

        pub fn jsonStringify(
            value: @This(),
            writer: anytype,
        ) (json.Error || JsonApplicationError)!void {
            if (value.denied) return error.AlphaDenied;
            return writer.write("alpha");
        }
    };
    const Beta = struct {
        denied: bool,
        pub const JsonApplicationError = error{BetaDenied};

        pub fn jsonStringify(
            value: @This(),
            writer: anytype,
        ) (json.Error || JsonApplicationError)!void {
            if (value.denied) return error.BetaDenied;
            return writer.write("beta");
        }
    };
    const Root = struct { alpha: Alpha, beta: Beta };
    try std.testing.expect(
        json.CustomEncodeError(Root) == error{ AlphaDenied, BetaDenied },
    );
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"alpha\":\"alpha\",\"beta\":\"beta\"}",
        try json.encode(.{
            .alpha = Alpha{ .denied = false },
            .beta = Beta{ .denied = false },
        }, &output),
    );
    try std.testing.expectError(error.AlphaDenied, json.encode(.{
        .alpha = Alpha{ .denied = true },
        .beta = Beta{ .denied = false },
    }, &output));
    try std.testing.expectError(error.BetaDenied, json.encode(.{
        .alpha = Alpha{ .denied = false },
        .beta = Beta{ .denied = true },
    }, &output));
}

test "custom hook grammar remains checked in ReleaseFast" {
    const Empty = struct {
        pub fn jsonStringify(_: @This(), _: anytype) json.Error!void {}
    };
    const TwoValues = struct {
        pub fn jsonStringify(_: @This(), writer: anytype) json.Error!void {
            try writer.write(true);
            try writer.write(false);
        }
    };
    const MissingValue = struct {
        pub fn jsonStringify(_: @This(), writer: anytype) json.Error!void {
            try writer.beginObject();
            try writer.objectField("missing");
            try writer.endObject();
        }
    };
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.MalformedCustomJson, json.encode(Empty{}, &output));
    try std.testing.expectError(error.MalformedCustomJson, json.encode(TwoValues{}, &output));
    try std.testing.expectError(error.MalformedCustomJson, json.encode(MissingValue{}, &output));
}

test "custom hook latches a swallowed child encoding failure" {
    const Swallow = struct {
        pub fn jsonStringify(_: @This(), writer: anytype) json.Error!void {
            try writer.beginObject();
            try writer.objectField("value");
            writer.write("\xff") catch {};
        }
    };
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, json.encode(Swallow{}, &output));
}

test "custom hook retains swallowed child application failure" {
    const Child = struct {
        pub const JsonApplicationError = error{Denied};

        pub fn jsonStringify(
            _: @This(),
            _: anytype,
        ) (json.Error || JsonApplicationError)!void {
            return error.Denied;
        }
    };
    const Parent = struct {
        pub const JsonApplicationError = error{Denied};

        pub fn jsonStringify(
            _: @This(),
            writer: anytype,
        ) (json.Error || JsonApplicationError)!void {
            try writer.beginArray();
            writer.write(Child{}) catch {};
            try writer.endArray();
        }
    };
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.Denied, json.encode(Parent{}, &output));
}

test "custom hook rejects duplicate decoded object names" {
    const Duplicate = struct {
        pub fn jsonStringify(_: @This(), writer: anytype) json.Error!void {
            try writer.beginObject();
            try writer.objectField("same");
            try writer.write(@as(u8, 1));
            try writer.objectField("same");
            try writer.write(@as(u8, 2));
            try writer.endObject();
        }
    };
    var output: [128]u8 = undefined;
    try std.testing.expectError(error.DuplicateField, json.encode(Duplicate{}, &output));
    try std.testing.expectError(
        error.DuplicateField,
        json.encodeWith(.{ .whitespace = .indent_2 }, Duplicate{}, &output),
    );
}

test "optional wrapped recursive hook reaches hook hard depth on a 64 KiB stack" {
    const Recursive = struct {
        next: ?*const @This() = null,

        pub fn jsonStringify(self: @This(), writer: anytype) json.Error!void {
            try writer.write(self.next);
        }
    };
    const depth: usize = json.hook_depth_hard_max;
    const Context = struct {
        nodes: [depth + 1]Recursive = undefined,
        at_limit_ok: bool = false,
        over_limit_ok: bool = false,

        fn run(self: *@This()) void {
            var output: [64]u8 = undefined;
            const at_limit = json.encodeWith(
                .{ .max_depth = json.depth_hard_max },
                self.nodes[0],
                &output,
            ) catch return;
            self.at_limit_ok = std.mem.eql(u8, at_limit, "null");
            self.nodes[depth - 1].next = &self.nodes[depth];
            _ = json.encodeWith(
                .{ .max_depth = json.depth_hard_max },
                self.nodes[0],
                &output,
            ) catch |problem| {
                self.over_limit_ok = problem == error.MaxDepthExceeded;
                return;
            };
        }
    };
    var context = Context{};
    for (&context.nodes) |*node| node.* = .{};
    for (0..depth - 1) |index| context.nodes[index].next = &context.nodes[index + 1];
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(
        .{ .stack_size = stack_size },
        Context.run,
        .{&context},
    );
    thread.join();
    try std.testing.expect(context.at_limit_ok);
    try std.testing.expect(context.over_limit_ok);
}

test "schema metadata reports invalid names collisions and omission" {
    const Duplicate = struct {
        first: u8,
        second: u8,
        pub const ploof_json_fields = .{
            .first = json.field(.{ .rename = "same" }),
            .second = json.field(.{ .rename = "same" }),
        };
    };
    const Empty = struct {
        value: u8,
        pub const ploof_json_fields = .{ .value = json.field(.{ .rename = "" }) };
    };
    const NonOptional = struct {
        value: u8,
        pub const ploof_json_fields = .{ .value = json.field(.{ .omit_if_null = true }) };
    };
    const Unknown = struct {
        value: u8,
        pub const ploof_json_fields = .{ .other = json.field(.{}) };
    };
    try std.testing.expectEqual(json.SchemaIssue.duplicate_name, json.schemaIssue(Duplicate).?);
    try std.testing.expectEqual(json.SchemaIssue.empty_name, json.schemaIssue(Empty).?);
    try std.testing.expectEqual(
        json.SchemaIssue.omit_non_optional,
        json.schemaIssue(NonOptional).?,
    );
    try std.testing.expectEqual(json.SchemaIssue.unknown_field, json.schemaIssue(Unknown).?);
}

test "only explicit ploof_json_fields metadata changes the wire schema" {
    const Unrelated = struct {
        value: u8,
        pub const json_fields = .{ .value = json.field(.{ .rename = "ignored" }) };
    };
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"value\":1}",
        try json.encode(Unrelated{ .value = 1 }, &output),
    );
}

test "non-exhaustive enum values require a declared string tag" {
    const Open = enum(u8) {
        known = 1,
        _,
    };
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\"known\"", try json.encode(Open.known, &output));
    const unknown: Open = @enumFromInt(7);
    try std.testing.expectError(error.UnknownEnumTag, json.encode(unknown, &output));
}

test "arrays tuples enums and tagged unions have stable representations" {
    const Kind = enum { alpha, beta };
    const Choice = union(enum) {
        count: u16,
        empty: void,
    };
    const value = .{
        .bytes = [_]u8{ 'o', 'k' },
        .tuple = .{ @as(u8, 1), true },
        .kind = Kind.beta,
        .choice = Choice{ .count = 9 },
    };
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"bytes\":\"ok\",\"tuple\":[1,true],\"kind\":\"beta\",\"choice\":{\"count\":9}}",
        try json.encode(value, &output),
    );
}

test {
    std.testing.refAllDecls(json);
}

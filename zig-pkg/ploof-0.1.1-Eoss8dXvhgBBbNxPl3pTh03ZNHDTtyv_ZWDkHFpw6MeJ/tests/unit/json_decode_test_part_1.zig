const source = @import("json_decode_test.zig");
const builtin = @import("builtin");
const std = source.std;
const body = source.body;
const decode = source.decode;
const fuzz_support = source.fuzz_support;
const json = source.json;
const schema = source.schema;
const types = source.types;
const validate = source.validate;
const hash_key = source.hash_key;
const Mode = source.Mode;
const Record = source.Record;
const HookSeconds = source.HookSeconds;
const HookList = source.HookList;
const HookMutableString = source.HookMutableString;
const FailingHook = source.FailingHook;
const CursorTotal = source.CursorTotal;
const fuzz_corpus = source.fuzz_corpus;
const custom_fuzz_corpus = source.custom_fuzz_corpus;
const fuzzCustomDecode = source.fuzzCustomDecode;
const fuzzDecode = source.fuzzDecode;
const expectValuesEqual = source.expectValuesEqual;
const expectTyped = source.expectTyped;
const expectTypedError = source.expectTypedError;
const expectPointerIn = source.expectPointerIn;

test "typed decode is strict and applies exact schema metadata" {
    const document =
        \\{"recordId":100,"label":"ploof","mode":"safe","extra":[1,true]}
    ;
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(Record, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqual(@as(u16, 100), result.value.id);
    try std.testing.expectEqualStrings("ploof", result.value.label);
    try std.testing.expect(result.value.note == null);
    try std.testing.expectEqual(Mode.safe, result.value.mode);

    try expectTypedError(bool, "1", error.TypeMismatch);
    try expectTypedError(u8, "true", error.TypeMismatch);
    try expectTypedError(u8, "-1", error.Overflow);
    try expectTypedError(i8, "128", error.Overflow);
    try expectTypedError(i32, "1.5", error.InvalidNumber);
    try expectTypedError(Mode, "\"FAST\"", error.UnknownEnumTag);
    try expectTypedError(Mode, "0", error.TypeMismatch);
}

test "integer and float decoding preserve numeric meaning without coercion" {
    try expectTyped(i32, "1e2", 100);
    try expectTyped(i32, "1.20e1", 12);
    try expectTyped(f64, "-12.5e+2", -1250.0);
    try expectTypedError(f64, "1e9999", error.Overflow);
    try expectTypedError(f64, "\"1.0\"", error.TypeMismatch);
}

test "optional absence requires a Zig default while explicit null is exact" {
    const RequiredOptional = struct { value: ?u8 };
    const DefaultOptional = struct { value: ?u8 = null };
    try expectTypedError(RequiredOptional, "{}", error.MissingField);

    const null_chunks = [_]body.Chunk{body.Chunk.init("{\"value\":null}")};
    const null_input = try body.Bytes.init(&null_chunks);
    var null_workspace: [1024]u8 align(validate.scratch_alignment) = undefined;
    const explicit = try decode.decode(
        RequiredOptional,
        null_input,
        &null_workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expect(explicit.value.value == null);
    try expectTyped(DefaultOptional, "{}", DefaultOptional{});
}

test "unknown field policy and duplicate validation apply at every depth" {
    const T = struct { id: u8 };
    const ignored_chunks = [_]body.Chunk{
        body.Chunk.init("{\"id\":1,\"unknown\":{\"nested\":[1,2]}}"),
    };
    const ignored_input = try body.Bytes.init(&ignored_chunks);
    var ignored_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const ignored = try decode.decode(T, ignored_input, &ignored_workspace, .{
        .hash_key = hash_key,
    });
    try std.testing.expectEqual(@as(u8, 1), ignored.value.id);

    var reject_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.UnknownField, decode.decode(
        T,
        ignored_input,
        &reject_workspace,
        .{ .hash_key = hash_key, .unknown_fields = .reject },
    ));

    const duplicate_chunks = [_]body.Chunk{
        body.Chunk.init("{\"id\":1,\"unknown\":{\"x\":1,\"\\u0078\":2}}"),
    };
    const duplicate_input = try body.Bytes.init(&duplicate_chunks);
    var duplicate_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.DuplicateName, decode.decode(
        T,
        duplicate_input,
        &duplicate_workspace,
        .{ .hash_key = hash_key },
    ));
}

test "ignored subtrees do not materialize container plans" {
    const T = struct { id: u8 };
    const shallow = "{\"id\":1,\"unknown\":0}";
    var nested_storage: [128]u8 = undefined;
    const prefix = "{\"id\":1,\"unknown\":";
    @memcpy(nested_storage[0..prefix.len], prefix);
    for (0..32) |index| nested_storage[prefix.len + index] = '[';
    nested_storage[prefix.len + 32] = '0';
    for (0..32) |index| nested_storage[prefix.len + 33 + index] = ']';
    nested_storage[prefix.len + 65] = '}';
    const nested = nested_storage[0 .. prefix.len + 66];

    const shallow_chunks = [_]body.Chunk{body.Chunk.init(shallow)};
    const nested_chunks = [_]body.Chunk{body.Chunk.init(nested)};
    var shallow_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    var nested_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const shallow_result = try decode.decode(
        T,
        try body.Bytes.init(&shallow_chunks),
        &shallow_workspace,
        .{ .hash_key = hash_key },
    );
    const nested_result = try decode.decode(
        T,
        try body.Bytes.init(&nested_chunks),
        &nested_workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqual(shallow_result.workspace_used, nested_result.workspace_used);
    try std.testing.expectEqual(
        shallow_result.workspace_required,
        nested_result.workspace_required,
    );
}

test "strings borrow whole unescaped chunks and retain decoded fragments" {
    const T = struct { text: []const u8 };
    const document = "{\"text\":\"borrowed\"}";
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [2048]u8 align(validate.scratch_alignment) = undefined;
    const borrowed = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    const offset = std.mem.indexOf(u8, document, "borrowed").?;
    try std.testing.expect(borrowed.value.text.ptr == document.ptr + offset);

    const escaped_chunks = [_]body.Chunk{
        body.Chunk.init("{\"text\":\"cop"),
        body.Chunk.init("ied\\u0021\"}"),
    };
    const escaped_input = try body.Bytes.init(&escaped_chunks);
    var escaped_workspace: [2048]u8 align(validate.scratch_alignment) = undefined;
    const copied = try decode.decode(
        T,
        escaped_input,
        &escaped_workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqualStrings("copied!", copied.value.text);
    try expectPointerIn(copied.value.text.ptr, &escaped_workspace);
}

test "mutable strings always copy and root values consume workspace" {
    const T = struct { text: []u8 };
    const document = "{\"text\":\"owned\"}";
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [1024]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try expectPointerIn(result.value.text.ptr, &workspace);
    result.value.text[0] = 'O';
    try std.testing.expectEqualStrings("Owned", result.value.text);
    try std.testing.expectEqualStrings("owned", document[9..14]);

    const scalar_chunks = [_]body.Chunk{body.Chunk.init("true")};
    const scalar_input = try body.Bytes.init(&scalar_chunks);
    var no_workspace: [0]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.WorkspaceTooSmall, decode.decode(
        bool,
        scalar_input,
        &no_workspace,
        .{ .hash_key = hash_key },
    ));
    var root_workspace: [1]u8 align(validate.scratch_alignment) = undefined;
    const scalar = try decode.decode(
        bool,
        scalar_input,
        &root_workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expect(scalar.value.*);
    try std.testing.expectEqual(@as(usize, 1), scalar.workspace_required);
}

test "dynamic DOM preserves object order arrays and exact number lexemes" {
    const chunks = [_]body.Chunk{
        body.Chunk.init("{\"n\":-12."),
        body.Chunk.init("50e+2,\"items\":[null,true,\"x\"]}"),
    };
    const input = try body.Bytes.init(&chunks);
    var workspace: [8192]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decodeValue(input, &workspace, .{ .hash_key = hash_key });
    const members = result.value.object;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("n", members[0].name);
    try std.testing.expectEqualStrings("-12.50e+2", members[0].value.number.lexeme);
    try expectPointerIn(members[0].value.number.lexeme.ptr, &workspace);
    try std.testing.expectEqualStrings("items", members[1].name);
    const items = members[1].value.array;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0] == .null);
    try std.testing.expect(items[1].boolean);
    try std.testing.expectEqualStrings("x", items[2].string);
}

test "fixed arrays slices tuples vectors pointers and tagged unions decode" {
    const Choice = union(enum) { count: u16, empty: void };
    const T = struct {
        bytes: [3]u8,
        list: []const u16,
        tuple: struct { u8, bool },
        vector: @Vector(2, i8),
        pointer: *const u8,
        choice: Choice,
    };
    const document =
        \\{"bytes":"zig","list":[1,2],"tuple":[3,true],
        \\ "vector":[-1,2],"pointer":4,"choice":{"count":5}}
    ;
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [8192]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqualStrings("zig", &result.value.bytes);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, result.value.list);
    try std.testing.expectEqual(@as(u8, 3), result.value.tuple[0]);
    try std.testing.expect(result.value.tuple[1]);
    try std.testing.expectEqual(@as(i8, -1), result.value.vector[0]);
    try std.testing.expectEqual(@as(u8, 4), result.value.pointer.*);
    try std.testing.expectEqual(@as(u16, 5), result.value.choice.count);

    try expectTypedError([2]u8, "\"x\"", error.LengthMismatch);
    try expectTypedError([2]u8, "[1,2]", error.TypeMismatch);
    try expectTypedError([2]u8, "\"xyz\"", error.LengthMismatch);
}

test "recursive optional pointers remain bounded by depth and workspace" {
    const Node = struct {
        value: u8,
        next: ?*@This() = null,
    };
    const document = "{\"value\":1,\"next\":{\"value\":2,\"next\":null}}";
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(Node, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqual(@as(u8, 1), result.value.value);
    try std.testing.expectEqual(@as(u8, 2), result.value.next.?.value);
    try std.testing.expect(result.value.next.?.next == null);
    try expectPointerIn(@ptrCast(result.value.next.?), &workspace);
}

test "typed traversal preserves zero-size and over-aligned destinations" {
    const Empty = struct {};
    const Choice = union(enum) { empty: Empty, count: u16 };
    const T = struct {
        aligned: u32 align(64),
        fixed: [2]Empty,
        slice: []const Empty,
        choice: Choice,
    };
    const document =
        \\{"aligned":9,"fixed":[{},{}],"slice":[{},{}],"choice":{"empty":{}}}
    ;
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    var workspace: [16 * 1024]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(
        T,
        try body.Bytes.init(&chunks),
        &workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqual(@as(u32, 9), result.value.aligned);
    try std.testing.expectEqual(@as(usize, 2), result.value.slice.len);
    try std.testing.expect(result.value.choice == .empty);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&result.value.aligned) % 64);
}

test "recursive typed traversal reaches hard depth on a 64 KiB stack" {
    const Node = struct { next: ?*@This() = null };
    const depth: usize = json.depth_hard_max;
    const prefix = "{\"next\":";
    var document: [depth * (prefix.len + 1) + 4]u8 = undefined;
    for (0..depth) |index| {
        const start = index * prefix.len;
        @memcpy(document[start .. start + prefix.len], prefix);
    }
    const null_start = depth * prefix.len;
    @memcpy(document[null_start .. null_start + 4], "null");
    @memset(document[null_start + 4 ..], '}');

    const Context = struct {
        document: []const u8,
        workspace: []align(validate.scratch_alignment) u8,
        problem: ?decode.Error = null,
        count: usize = 0,

        fn run(context: *@This()) void {
            const chunks = [_]body.Chunk{body.Chunk.init(context.document)};
            const input = body.Bytes.init(&chunks) catch {
                context.problem = error.CountOverflow;
                return;
            };
            const result = decode.decode(Node, input, context.workspace, .{
                .hash_key = hash_key,
                .depth_max = json.depth_hard_max,
            }) catch |problem| {
                context.problem = problem;
                return;
            };
            var current: ?*const Node = result.value;
            while (current) |node| {
                context.count += 1;
                current = node.next;
            }
        }
    };
    var workspace: [64 * 1024]u8 align(validate.scratch_alignment) = undefined;
    var context = Context{ .document = &document, .workspace = &workspace };
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, Context.run, .{&context});
    thread.join();
    try std.testing.expect(context.problem == null);
    try std.testing.expectEqual(depth, context.count);
}

test "acyclic type graphs beyond direct depth use bounded traversal" {
    const Shapes = struct {
        fn Chain(comptime depth: usize) type {
            if (depth == 0) return u8;
            return struct { child: Chain(depth - 1) };
        }
    };
    const depth = 17;
    const T = Shapes.Chain(depth);
    const prefix = "{\"child\":";
    var document: [depth * (prefix.len + 1) + 1]u8 = undefined;
    for (0..depth) |index| {
        const start = index * prefix.len;
        @memcpy(document[start .. start + prefix.len], prefix);
    }
    document[depth * prefix.len] = '7';
    @memset(document[depth * prefix.len + 1 ..], '}');

    const Context = struct {
        document: []const u8,
        workspace: []align(validate.scratch_alignment) u8,
        problem: ?decode.Error = null,

        fn run(context: *@This()) void {
            const chunks = [_]body.Chunk{body.Chunk.init(context.document)};
            const input = body.Bytes.init(&chunks) catch {
                context.problem = error.CountOverflow;
                return;
            };
            _ = decode.decode(T, input, context.workspace, .{
                .hash_key = hash_key,
                .depth_max = depth,
            }) catch |problem| {
                context.problem = problem;
                return;
            };
        }
    };
    var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    var context = Context{ .document = &document, .workspace = &workspace };
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, Context.run, .{&context});
    thread.join();
    try std.testing.expect(context.problem == null);
}

test "every split boundary and byte sized fragmentation decode identically" {
    const T = struct {
        name: []const u8,
        values: []const i16,
    };
    const document = "{\"na\\u006de\":\"pl\\u006fof\",\"values\":[-1,0,23]}";
    for (0..document.len + 1) |split| {
        const chunks = [_]body.Chunk{
            body.Chunk.init(document[0..split]),
            body.Chunk.init(document[split..]),
        };
        const input = try body.Bytes.init(&chunks);
        var workspace: [8192]u8 align(validate.scratch_alignment) = undefined;
        const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
        try std.testing.expectEqualStrings("ploof", result.value.name);
        try std.testing.expectEqualSlices(i16, &.{ -1, 0, 23 }, result.value.values);
    }

    var chunks: [document.len]body.Chunk = undefined;
    for (&chunks, 0..) |*chunk, index| chunk.* = body.Chunk.init(document[index .. index + 1]);
    const input = try body.Bytes.init(&chunks);
    var workspace: [8192]u8 align(validate.scratch_alignment) = undefined;
    const fragmented = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqualStrings("ploof", fragmented.value.name);
    try std.testing.expectEqualSlices(i16, &.{ -1, 0, 23 }, fragmented.value.values);
}

test "copied field names cannot be overwritten into another schema match" {
    const T = struct {
        a: []const u8,
        b: u8,
    };
    const chunks = [_]body.Chunk{
        body.Chunk.init("{\"\\u0061\":\""),
        body.Chunk.init("b\",\"b\":2}"),
    };
    const input = try body.Bytes.init(&chunks);
    var workspace: [2048]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqualStrings("b", result.value.a);
    try std.testing.expectEqual(@as(u8, 2), result.value.b);
}

test "reported workspace requirement accepts N and N plus one and rejects N minus one" {
    const T = struct { items: []const []const u8 };
    const chunks = [_]body.Chunk{
        body.Chunk.init("{\"items\":[\"a"),
        body.Chunk.init("bc\",\"def\"]}"),
    };
    const input = try body.Bytes.init(&chunks);
    var generous: [8192]u8 align(validate.scratch_alignment) = undefined;
    const measured = try decode.decode(T, input, &generous, .{ .hash_key = hash_key });
    const required = measured.workspace_required;
    try std.testing.expect(required > 0);

    var exact: [8192]u8 align(validate.scratch_alignment) = undefined;
    const exact_result = try decode.decode(
        T,
        input,
        exact[0..required],
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqualSlices(u8, "abc", exact_result.value.items[0]);

    var plus_one: [8192]u8 align(validate.scratch_alignment) = undefined;
    _ = try decode.decode(
        T,
        input,
        plus_one[0 .. required + 1],
        .{ .hash_key = hash_key },
    );

    var short: [8192]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.WorkspaceTooSmall, decode.decode(
        T,
        input,
        short[0 .. required - 1],
        .{ .hash_key = hash_key },
    ));
}

test "decode enforces configured depth in every build mode" {
    var document: [132]u8 = undefined;
    for (0..65) |index| document[index] = '[';
    document[65] = '0';
    for (0..65) |index| document[66 + index] = ']';
    const chunks = [_]body.Chunk{body.Chunk.init(&document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [16384]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.DepthLimitExceeded, decode.decodeValue(
        input,
        &workspace,
        .{ .hash_key = hash_key, .depth_max = 64 },
    ));
}

test "dynamic and ignored JSON traverse the hard depth with bounded frames" {
    const depth = json.depth_hard_max;
    var document: [depth * 2 + 1]u8 = undefined;
    for (document[0..depth]) |*byte| byte.* = '[';
    document[depth] = '0';
    for (document[depth + 1 ..]) |*byte| byte.* = ']';
    const chunks = [_]body.Chunk{body.Chunk.init(&document)};
    var workspace: [64 * 1024]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decodeValue(
        try body.Bytes.init(&chunks),
        &workspace,
        .{ .hash_key = hash_key, .depth_max = depth },
    );
    var leaf: *const json.Value = result.value;
    for (0..depth) |_| leaf = &leaf.array[0];
    try std.testing.expectEqualStrings("0", leaf.number.bytes());

    const prefix = "{\"unknown\":";
    const suffix = ",\"kept\":7}";
    var ignored: [prefix.len + (depth - 1) * 2 + 1 + suffix.len]u8 = undefined;
    @memcpy(ignored[0..prefix.len], prefix);
    @memset(ignored[prefix.len .. prefix.len + depth - 1], '[');
    ignored[prefix.len + depth - 1] = '0';
    @memset(ignored[prefix.len + depth .. ignored.len - suffix.len], ']');
    @memcpy(ignored[ignored.len - suffix.len ..], suffix);
    const ignored_chunks = [_]body.Chunk{body.Chunk.init(&ignored)};
    const typed = try decode.decode(
        struct { kept: u8 },
        try body.Bytes.init(&ignored_chunks),
        &workspace,
        .{ .hash_key = hash_key, .depth_max = depth },
    );
    try std.testing.expectEqual(@as(u8, 7), typed.value.kept);
}

test "jsonParse typed hooks compose at root and nested positions" {
    const T = struct {
        primary: HookSeconds,
        history: []const HookSeconds,
    };
    const document =
        \\{"primary":{"seconds":7},"history":[{"seconds":8},{"seconds":9}]}
    ;
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [16384]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(T, input, &workspace, .{ .hash_key = hash_key });
    try std.testing.expectEqual(@as(i64, 7), result.value.primary.value);
    try std.testing.expectEqual(@as(usize, 2), result.value.history.len);
    try std.testing.expectEqual(@as(i64, 8), result.value.history[0].value);
    try std.testing.expectEqual(@as(i64, 9), result.value.history[1].value);
}

test "jsonParse structured cursor reads scalar array and object values" {
    const document = "{\"values\":[1,2,3],\"enabled\":true}";
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const input = try body.Bytes.init(&chunks);
    var workspace: [8192]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(
        CursorTotal,
        input,
        &workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqual(@as(i64, 6), result.value.total);
    try std.testing.expect(result.value.enabled);
}

test "jsonParse errors and one-root contract are enforced in ReleaseFast" {
    const Empty = struct {
        pub fn jsonParse(parser: anytype) json.ParseError!@This() {
            _ = parser;
            return .{};
        }
    };
    const Twice = struct {
        value: u8,

        pub fn jsonParse(parser: anytype) json.ParseError!@This() {
            const value = try parser.parse(u8);
            _ = parser.parse(u8) catch {};
            return .{ .value = value };
        }
    };
    const CopiedTwice = struct {
        value: u8,

        pub fn jsonParse(parser: anytype) json.ParseError!@This() {
            var copy = parser.*;
            const value = try parser.parse(u8);
            _ = copy.parse(u8) catch {};
            return .{ .value = value };
        }
    };
    try expectTypedError(HookSeconds, "{\"seconds\":-1}", error.InvalidValue);
    try expectTypedError(Empty, "null", error.MalformedCustomJson);
    try expectTypedError(Twice, "1", error.MalformedCustomJson);
    try expectTypedError(CopiedTwice, "1", error.MalformedCustomJson);
}

test "jsonParse normalizes synthetic framework errors only" {
    inline for ([_]json.ParseError{
        error.CountOverflow,
        error.InvalidDepthLimit,
        error.PlanMismatch,
        error.ScannerCapacity,
        error.WorkspaceTooSmall,
    }) |problem| {
        try expectTypedError(FailingHook(problem), "null", error.InvalidValue);
    }

    const chunks = [_]body.Chunk{body.Chunk.init("\"x\"")};
    const input = try body.Bytes.init(&chunks);
    var workspace: [@sizeOf(HookMutableString)]u8 align(validate.scratch_alignment) =
        undefined;
    try std.testing.expectError(error.WorkspaceTooSmall, decode.decode(
        HookMutableString,
        input,
        &workspace,
        .{ .hash_key = hash_key },
    ));
}

test "jsonParse preserves validation and surrogate unknown-field policy" {
    try expectTypedError(
        HookSeconds,
        "{\"seconds\":1,\"\\u0073econds\":2}",
        error.DuplicateName,
    );
    try expectTypedError(HookSeconds, "{\"seconds\":1} null", error.Syntax);

    const chunks = [_]body.Chunk{
        body.Chunk.init("{\"seconds\":1,\"extra\":true}"),
    };
    const input = try body.Bytes.init(&chunks);
    var ignored_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    const ignored = try decode.decode(
        HookSeconds,
        input,
        &ignored_workspace,
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqual(@as(i64, 1), ignored.value.value);

    var rejected_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.UnknownField, decode.decode(
        HookSeconds,
        input,
        &rejected_workspace,
        .{ .hash_key = hash_key, .unknown_fields = .reject },
    ));

    const invalid_byte = [_]u8{0xff};
    const invalid_chunks = [_]body.Chunk{
        body.Chunk.init("{\"seconds\":\""),
        body.Chunk.init(&invalid_byte),
        body.Chunk.init("\"}"),
    };
    var invalid_workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.Syntax, decode.decode(
        HookSeconds,
        try body.Bytes.init(&invalid_chunks),
        &invalid_workspace,
        .{ .hash_key = hash_key },
    ));
}

test "jsonParse parse-memory accounting accepts N and rejects N minus one" {
    const chunks = [_]body.Chunk{
        body.Chunk.init("{\"items\":[1,"),
        body.Chunk.init("2,3,4]}"),
    };
    const input = try body.Bytes.init(&chunks);
    var generous: [16384]u8 align(validate.scratch_alignment) = undefined;
    const measured = try decode.decode(
        HookList,
        input,
        &generous,
        .{ .hash_key = hash_key },
    );
    const required = measured.workspace_required;
    try std.testing.expect(required > @sizeOf(HookList));

    var exact: [16384]u8 align(validate.scratch_alignment) = undefined;
    const result = try decode.decode(
        HookList,
        input,
        exact[0..required],
        .{ .hash_key = hash_key },
    );
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, result.value.items);

    var short: [16384]u8 align(validate.scratch_alignment) = undefined;
    try std.testing.expectError(error.WorkspaceTooSmall, decode.decode(
        HookList,
        input,
        short[0 .. required - 1],
        .{ .hash_key = hash_key },
    ));
}

test "jsonParse every split boundary decodes identically" {
    const document = "{\"seconds\":123}";
    for (0..document.len + 1) |split| {
        const chunks = [_]body.Chunk{
            body.Chunk.init(document[0..split]),
            body.Chunk.init(document[split..]),
        };
        var workspace: [4096]u8 align(validate.scratch_alignment) = undefined;
        const result = try decode.decode(
            HookSeconds,
            try body.Bytes.init(&chunks),
            &workspace,
            .{ .hash_key = hash_key },
        );
        try std.testing.expectEqual(@as(i64, 123), result.value.value);
    }
}

test "jsonParse fragmentation fuzz has one semantic outcome" {
    try std.testing.fuzz({}, fuzzCustomDecode, .{ .corpus = &custom_fuzz_corpus });
}

test "dynamic decode fragmentation fuzz has one semantic outcome" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = &fuzz_corpus });
}

test {
    _ = types;
}

const std = @import("std");
const application_input = @import("../../src/internal/application/input.zig");
const body = @import("../../src/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const form = @import("../../src/form.zig");
const input_materialize = @import("../../src/internal/application/input_materialize.zig");
const json = @import("../../src/json.zig");
const multipart = @import("../../src/multipart.zig");
const query = @import("../../src/query.zig");

const hash_key = [_]u8{
    0x91, 0x26, 0xd8, 0x43, 0x5b, 0xae, 0x70, 0x1f,
    0x0d, 0xe4, 0x39, 0xc7, 0x68, 0xb2, 0x54, 0xfa,
};

test "query-only materialization uses exact workspace and absence is empty" {
    const Target = struct {
        page: u16 = 7,
        tags: []const u16 = &.{},
    };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(Target, .{ .segments_max = 4 }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;

    const populated = try input_materialize.materialize(
        Handler,
        .none,
        null,
        "page=9&tags=2&tags=3",
        &workspace,
        hash_key,
    );
    const input = switch (populated) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 9), input.query.page);
    try std.testing.expectEqualSlices(u16, &.{ 2, 3 }, input.query.tags);
    try expectPointerIn(input.query.tags.ptr, &workspace);

    const absent = try input_materialize.materialize(
        Handler,
        .none,
        null,
        null,
        &workspace,
        hash_key,
    );
    const defaulted = switch (absent) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 7), defaulted.query.page);
    try std.testing.expectEqual(@as(usize, 0), defaulted.query.tags.len);

    try std.testing.expectError(error.InvariantViolation, input_materialize.materialize(
        Handler,
        .none,
        null,
        null,
        workspace[0 .. workspace.len - 1],
        hash_key,
    ));
}

test "query and form bind independently and borrow request workspace" {
    const QueryTarget = struct { trace: []const u8 };
    const FormTarget = struct {
        csrf: []const u8,
        enabled: bool,
        values: []const u16,
    };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(QueryTarget, .{ .segments_max = 2 }),
        .body = form.typed(FormTarget, .{
            .encoded_wire_bytes_max = 64,
            .decoded_bytes_max = 64,
            .segments_max = 4,
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "csrf=a%2Bb&enabled=1&values=4&values=8",
        &chunks,
    );

    const outcome = try input_materialize.materialize(
        Handler,
        decoded,
        0,
        "trace=request-7",
        &workspace,
        hash_key,
    );
    const input = switch (outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("request-7", input.query.trace);
    try std.testing.expectEqualStrings("a+b", input.body.csrf);
    try std.testing.expect(input.body.enabled);
    try std.testing.expectEqualSlices(u16, &.{ 4, 8 }, input.body.values);
    try expectPointerIn(input.query.trace.ptr, &workspace);
    try expectPointerIn(input.body.csrf.ptr, &workspace);
    try expectPointerIn(input.body.values.ptr, &workspace);
}

test "raw query and form tables stay separate and workspace-backed" {
    const Definition = endpoint.Endpoint(.{
        .query = query.raw(.{ .segments_max = 3 }),
        .body = form.raw(.{
            .encoded_wire_bytes_max = 32,
            .decoded_bytes_max = 32,
            .segments_max = 2,
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "token=a%2Bb",
        &chunks,
    );
    const outcome = try input_materialize.materialize(
        Handler,
        decoded,
        0,
        "id=1&id=2",
        &workspace,
        hash_key,
    );
    const input = switch (outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(input.query.source == .query);
    try std.testing.expect(input.body.source == .form);
    try std.testing.expectEqual(@as(usize, 2), input.query.pairs.len);
    try std.testing.expectEqualStrings("2", input.query.pairs[1].value);
    try std.testing.expectEqualStrings("a+b", input.body.pairs[0].value);
    try expectPointerIn(input.query.pairs.ptr, &workspace);
    try expectPointerIn(input.body.pairs.ptr, &workspace);
}

test "oneOf materializes only the selected exact union field" {
    const FormTarget = struct { token: []const u8 };
    const octet_media = [_]body.MediaPattern{.{ .exact = "application/octet-stream" }};
    const Definition = endpoint.Endpoint(.{
        .body = body.oneOf(.{
            .bytes = body.raw(.{
                .encoded_wire_bytes_max = 32,
                .decoded_bytes_max = 32,
                .accepted_media = &octet_media,
            }),
            .form = form.typed(FormTarget, .{
                .encoded_wire_bytes_max = 32,
                .decoded_bytes_max = 32,
                .segments_max = 2,
            }),
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const bytes_decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "opaque",
        &chunks,
    );
    const bytes_outcome = try input_materialize.materialize(
        Handler,
        bytes_decoded,
        0,
        null,
        &workspace,
        hash_key,
    );
    const bytes_input = switch (bytes_outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(bytes_input.body == .bytes);
    try std.testing.expect(bytes_input.body.bytes.eql("opaque"));

    const form_decoded = try retainBody(
        &workspace,
        layout.body_decoders[1].body,
        "token=chosen",
        &chunks,
    );
    const form_outcome = try input_materialize.materialize(
        Handler,
        form_decoded,
        1,
        null,
        &workspace,
        hash_key,
    );
    const form_input = switch (form_outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(form_input.body == .form);
    try std.testing.expectEqualStrings("chosen", form_input.body.form.token);
}

test "direct bytes and text preserve retained descriptors" {
    const bytes_media = [_]body.MediaPattern{.{ .exact = "application/octet-stream" }};
    const BytesDefinition = endpoint.Endpoint(.{ .body = body.raw(.{
        .encoded_wire_bytes_max = 16,
        .decoded_bytes_max = 16,
        .accepted_media = &bytes_media,
    }) });
    const bytes_handler = BytesDefinition.handle(struct {
        fn call(_: *u8, _: BytesDefinition.InputType) void {}
    }.call);
    const BytesHandler = @TypeOf(bytes_handler);
    const bytes_layout = comptime application_input.workspaceLayout(BytesHandler);
    var bytes_workspace: [bytes_layout.total_bytes_max]u8 align(64) = undefined;
    var bytes_chunks: [1]body.Chunk = undefined;
    const decoded_bytes = try retainBody(
        &bytes_workspace,
        bytes_layout.body_decoders[0].body,
        "raw",
        &bytes_chunks,
    );
    const bytes_outcome = try input_materialize.materialize(
        BytesHandler,
        decoded_bytes,
        0,
        null,
        &bytes_workspace,
        hash_key,
    );
    const bytes_input = switch (bytes_outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(bytes_input.body.eql("raw"));

    const text_media = [_]body.MediaPattern{.{ .exact = "text/plain" }};
    const TextDefinition = endpoint.Endpoint(.{ .body = body.utf8(.{
        .encoded_wire_bytes_max = 16,
        .decoded_bytes_max = 16,
        .accepted_media = &text_media,
    }) });
    const text_handler = TextDefinition.handle(struct {
        fn call(_: *u8, _: TextDefinition.InputType) void {}
    }.call);
    const TextHandler = @TypeOf(text_handler);
    const text_layout = comptime application_input.workspaceLayout(TextHandler);
    var text_workspace: [text_layout.total_bytes_max]u8 align(64) = undefined;
    var text_chunks: [1]body.Chunk = undefined;
    const retained = try retainBytes(
        &text_workspace,
        text_layout.body_decoders[0].body,
        "hello",
        &text_chunks,
    );
    const decoded_text = body.Decoded{ .text = try body.Text.fromBytes(retained) };
    const text_outcome = try input_materialize.materialize(
        TextHandler,
        decoded_text,
        0,
        null,
        &text_workspace,
        hash_key,
    );
    const text_input = switch (text_outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(text_input.body.eql("hello"));
}

test "JSON binding is strict and retains body and parse lifetimes" {
    const Target = struct {
        name: []const u8,
        values: []const u16,
    };
    const Definition = endpoint.Endpoint(.{ .body = json.typed(Target, .{
        .encoded_wire_bytes_max = 128,
        .decoded_bytes_max = 128,
        .parse_memory_bytes_max = 4096,
        .unknown_fields = .reject,
    }) });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "{\"name\":\"ploof\",\"values\":[2,4]}",
        &chunks,
    );
    const outcome = try input_materialize.materialize(
        Handler,
        decoded,
        0,
        null,
        &workspace,
        hash_key,
    );
    const input = switch (outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("ploof", input.body.name);
    try std.testing.expectEqualSlices(u16, &.{ 2, 4 }, input.body.values);
    try expectPointerIn(input.body.name.ptr, &workspace);
    try expectPointerIn(input.body.values.ptr, &workspace);

    const unknown = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "{\"name\":\"x\",\"values\":[],\"extra\":1}",
        &chunks,
    );
    const rejected = try input_materialize.materialize(
        Handler,
        unknown,
        0,
        null,
        &workspace,
        hash_key,
    );
    try expectRejection(rejected, .bad_request);
}

test "JSON parse-memory exhaustion is a payload limit" {
    const Target = struct { values: []const u64 };
    const Definition = endpoint.Endpoint(.{ .body = json.typed(Target, .{
        .encoded_wire_bytes_max = 64,
        .decoded_bytes_max = 64,
        .parse_memory_bytes_max = 48,
    }) });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "{\"values\":[1,2,3,4]}",
        &chunks,
    );
    const outcome = try input_materialize.materialize(
        Handler,
        decoded,
        0,
        null,
        &workspace,
        hash_key,
    );
    try expectRejection(outcome, .payload_too_large);
}

test "jsonParse representation failures are safe bad requests" {
    const Target = struct {
        value: u8,

        pub fn jsonParse(parser: anytype) json.ParseError!@This() {
            const wire = try parser.parse(struct { value: u16 });
            if (wire.value > 10) return error.InvalidValue;
            return .{ .value = @intCast(wire.value) };
        }
    };
    const Definition = endpoint.Endpoint(.{ .body = json.typed(Target, .{
        .encoded_wire_bytes_max = 64,
        .decoded_bytes_max = 64,
        .parse_memory_bytes_max = 2048,
    }) });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const decoded = try retainBody(
        &workspace,
        layout.body_decoders[0].body,
        "{\"value\":11}",
        &chunks,
    );
    const outcome = try input_materialize.materialize(
        Handler,
        decoded,
        0,
        null,
        &workspace,
        hash_key,
    );
    try expectRejection(outcome, .bad_request);
}

test "malformed unknown and cardinality query failures are 400" {
    const Target = struct { id: u8 };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(Target, .{
            .segments_max = 3,
            .unknown_fields = .reject,
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;

    const cases = [_][]const u8{
        "id=%GG",
        "id=1&extra=2",
        "id=1&id=2",
    };
    for (cases) |raw| {
        const outcome = try input_materialize.materialize(
            Handler,
            .none,
            null,
            raw,
            &workspace,
            hash_key,
        );
        try expectRejection(outcome, .bad_request);
    }
}

test "query segment excess is 400 while form resource excess is 413" {
    const QueryDefinition = endpoint.Endpoint(.{
        .query = query.raw(.{ .segments_max = 2 }),
    });
    const query_handler = QueryDefinition.handle(struct {
        fn call(_: *u8, _: QueryDefinition.InputType) void {}
    }.call);
    const QueryHandler = @TypeOf(query_handler);
    const query_layout = comptime application_input.workspaceLayout(QueryHandler);
    var query_workspace: [query_layout.total_bytes_max]u8 align(64) = undefined;
    const query_outcome = try input_materialize.materialize(
        QueryHandler,
        .none,
        null,
        "a=1&b=2&c=3",
        &query_workspace,
        hash_key,
    );
    try expectRejection(query_outcome, .bad_request);

    const FormDefinition = endpoint.Endpoint(.{
        .body = form.raw(.{
            .encoded_wire_bytes_max = 32,
            .decoded_bytes_max = 32,
            .segments_max = 2,
        }),
    });
    const form_handler = FormDefinition.handle(struct {
        fn call(_: *u8, _: FormDefinition.InputType) void {}
    }.call);
    const FormHandler = @TypeOf(form_handler);
    const form_layout = comptime application_input.workspaceLayout(FormHandler);
    var form_workspace: [form_layout.total_bytes_max]u8 align(64) = undefined;
    var chunks: [1]body.Chunk = undefined;
    const too_many = try retainBody(
        &form_workspace,
        form_layout.body_decoders[0].body,
        "a=1&b=2&c=3",
        &chunks,
    );
    const form_outcome = try input_materialize.materialize(
        FormHandler,
        too_many,
        0,
        null,
        &form_workspace,
        hash_key,
    );
    try expectRejection(form_outcome, .payload_too_large);

    const malformed = try retainBody(
        &form_workspace,
        form_layout.body_decoders[0].body,
        "a=%GG",
        &chunks,
    );
    const malformed_outcome = try input_materialize.materialize(
        FormHandler,
        malformed,
        0,
        null,
        &form_workspace,
        hash_key,
    );
    try expectRejection(malformed_outcome, .bad_request);
}

test "short or misaligned workspace and decoder mismatch are invariants" {
    const Target = struct { id: u8 = 1 };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(Target, .{ .segments_max = 1 }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var storage: [layout.total_bytes_max + 1]u8 align(64) = undefined;
    try std.testing.expectError(error.InvariantViolation, input_materialize.materialize(
        Handler,
        .none,
        null,
        null,
        storage[1..],
        hash_key,
    ));
    try std.testing.expectError(error.InvariantViolation, input_materialize.materialize(
        Handler,
        .{ .bytes = try emptyBytes() },
        null,
        null,
        storage[0..layout.total_bytes_max],
        hash_key,
    ));
}

test "multipart completion materializes only from decoded none" {
    const spec = multipart.decode(.{
        .csrf = multipart.field([]const u8, multipart.required),
    }, .{ .limits = .{
        .encoded_wire_bytes_max = 2_048,
        .total_body_bytes_max = 2_048,
        .file_bytes_max = 1_024,
        .field_bytes_max = 128,
    } });
    const Spec = @TypeOf(spec);
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(struct { page: u8 = 1 }, .{ .segments_max = 1 }),
        .body = spec,
        .response_json_bytes_max = 64,
    });
    const handler = Definition.handle(MultipartConsumer(Spec){});
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;

    const outcome = try input_materialize.materialize(
        Handler,
        .none,
        0,
        "page=7",
        &workspace,
        hash_key,
    );
    const input = switch (outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 7), input.query.page);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(input.body)));

    try std.testing.expectError(error.InvariantViolation, input_materialize.materialize(
        Handler,
        .{ .bytes = try emptyBytes() },
        0,
        null,
        &workspace,
        hash_key,
    ));
    const chunks = [_]body.Chunk{body.Chunk.init("not multipart parser output")};
    try std.testing.expectError(error.InvariantViolation, input_materialize.materialize(
        Handler,
        .{ .text = try body.Text.init(&chunks) },
        0,
        null,
        &workspace,
        hash_key,
    ));
}

test "multipart alternative materializes its exact zero-size union tag" {
    const upload = multipart.decode(.{
        .token = multipart.bytes_field(multipart.optional),
    }, .{ .limits = .{
        .encoded_wire_bytes_max = 1_024,
        .total_body_bytes_max = 1_024,
        .file_bytes_max = 512,
        .field_bytes_max = 64,
    } });
    const Upload = @TypeOf(upload);
    const binary_media = [_]body.MediaPattern{.{ .exact = "application/octet-stream" }};
    const Definition = endpoint.Endpoint(.{ .body = body.oneOf(.{
        .binary = body.raw(.{
            .encoded_wire_bytes_max = 32,
            .decoded_bytes_max = 32,
            .accepted_media = &binary_media,
        }),
        .upload = upload,
    }) });
    const handler = Definition.handle(MultipartConsumer(Upload){});
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    var workspace: [layout.total_bytes_max]u8 align(64) = undefined;

    const outcome = try input_materialize.materialize(
        Handler,
        .none,
        1,
        null,
        &workspace,
        hash_key,
    );
    const input = switch (outcome) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(input.body == .upload);
}

fn MultipartConsumer(comptime Spec: type) type {
    return struct {
        pub const State = void;

        pub fn field(_: *State, _: Spec.Field) void {}

        pub fn complete(
            _: @This(),
            _: anytype,
            _: *State,
            _: anytype,
            _: Spec.Summaries,
        ) multipart.Decision(void) {
            return multipart.commit({});
        }
    };
}

fn retainBody(
    workspace: []u8,
    region: application_input.Region,
    content: []const u8,
    chunks: *[1]body.Chunk,
) !body.Decoded {
    return .{ .bytes = try retainBytes(workspace, region, content, chunks) };
}

fn retainBytes(
    workspace: []u8,
    region: application_input.Region,
    content: []const u8,
    chunks: *[1]body.Chunk,
) !body.Bytes {
    if (content.len > region.bytes) return error.TestUnexpectedResult;
    const retained = workspace[region.offset..][0..content.len];
    @memcpy(retained, content);
    chunks[0] = body.Chunk.init(retained);
    return body.Bytes.init(chunks);
}

fn emptyBytes() !body.Bytes {
    return body.Bytes.init(&.{});
}

fn expectRejection(outcome: anytype, expected: input_materialize.Rejection) !void {
    switch (outcome) {
        .ready => return error.TestUnexpectedResult,
        .rejected => |actual| try std.testing.expectEqual(expected, actual),
    }
}

fn expectPointerIn(pointer: anytype, bytes: []const u8) !void {
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(bytes.ptr);
    try std.testing.expect(address >= start and address < start + bytes.len);
}

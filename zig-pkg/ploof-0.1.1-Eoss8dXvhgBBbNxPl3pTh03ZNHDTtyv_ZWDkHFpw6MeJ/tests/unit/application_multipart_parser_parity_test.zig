const std = @import("std");

const flat_schema = @import("../../src/internal/flat/schema.zig");
const flat_wire = @import("../../src/internal/flat/wire.zig");
const multipart = @import("../../src/multipart.zig");
const scalar_runtime = @import("../../src/internal/application/multipart_runtime.zig");
const upload_runtime = @import("../../src/internal/application/multipart_upload_runtime.zig");

const OpaqueSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct {
        bytes: u64 = 0,
        writes: u8 = 0,
    };
    pub const WriteState = void;
    pub const Summary = struct {
        bytes: u64,
        writes: u8,
    };
    pub const BeginInput = void;
    pub const Runtime = struct {
        bytes: [512]u8 = undefined,
        bytes_len: usize = 0,
        begins: u8 = 0,
        writes: u8 = 0,
        finishes: u8 = 0,
        commits: u8 = 0,
    };
    pub const StartupState = void;
    pub const Error = error{ UnexpectedCompletion, NoSpace, ByteMismatch };
    pub const io_requirements = multipart.IoRequirements.none;
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: multipart.PollEvent(multipart.RuntimeStartInput),
    ) Error!multipart.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        return doneVoid(event);
    }

    pub fn begin(
        runtime: *Runtime,
        state: *State,
        event: multipart.PollEvent(BeginInput),
    ) Error!multipart.Poll(void) {
        return switch (event) {
            .start => started: {
                runtime.begins += 1;
                state.* = .{};
                break :started .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn write(
        runtime: *Runtime,
        state: *State,
        _: *WriteState,
        event: multipart.PollEvent(multipart.WriteInput),
    ) Error!multipart.Poll(void) {
        return switch (event) {
            .start => |input| started: {
                if (input.bytes.len > runtime.bytes.len - runtime.bytes_len) {
                    return error.NoSpace;
                }
                @memcpy(runtime.bytes[runtime.bytes_len..][0..input.bytes.len], input.bytes);
                runtime.bytes_len += input.bytes.len;
                runtime.writes += 1;
                state.bytes += input.bytes.len;
                state.writes += 1;
                break :started .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn finish(
        runtime: *Runtime,
        state: *State,
        event: multipart.PollEvent(multipart.FinishInput),
    ) Error!multipart.Poll(Summary) {
        return switch (event) {
            .start => |input| started: {
                if (input.bytes != state.bytes) return error.ByteMismatch;
                runtime.finishes += 1;
                break :started .{ .done = .{
                    .bytes = state.bytes,
                    .writes = state.writes,
                } };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn commit(
        runtime: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        return switch (event) {
            .start => started: {
                runtime.commits += 1;
                break :started .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        return doneVoid(event);
    }

    fn doneVoid(event: multipart.PollEvent(void)) Error!multipart.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};

const OpaqueSpec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(OpaqueSink, multipart.required),
}, .{ .upload = .{ .window = 1, .chunk_bytes = 1024 } }));

const OpaqueContext = struct {
    pub const ResponseType = u16;
};

const OpaqueConsumer = struct {
    pub const State = struct {
        starts: u8 = 0,
        media_valid: bool = false,
    };

    pub fn init(_: OpaqueConsumer, _: *OpaqueContext) State {
        return .{};
    }

    pub fn fileStart(
        _: OpaqueConsumer,
        _: *OpaqueContext,
        state: *State,
        event: OpaqueSpec.FileStart,
    ) OpaqueSpec.FileAdmission(u16) {
        const metadata = switch (event) {
            .upload => |value| value,
        };
        state.starts += 1;
        state.media_valid = validMixedMedia(metadata);
        return .{ .accept = .{ .upload = {} } };
    }

    fn validMixedMedia(metadata: multipart.FileStart) bool {
        const media = metadata.claimed_media_type orelse return false;
        return std.mem.eql(u8, metadata.part_name, "upload") and
            metadata.occurrence == 1 and
            std.mem.eql(u8, media.type, "multipart") and
            std.mem.eql(u8, media.subtype, "mixed") and
            std.mem.eql(u8, media.raw, "multipart/mixed; boundary=inner");
    }
};

const OpaqueHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = OpaqueSpec;
    };
    pub const MultipartConsumer = OpaqueConsumer;
    pub const MultipartState = OpaqueConsumer.State;
    pub const handler_fn = OpaqueConsumer{};
};

const OpaqueSource = struct {
    runtime: OpaqueSink.Runtime = .{},

    pub fn get(self: *OpaqueSource, comptime Sink: type) *Sink.Runtime {
        if (Sink == OpaqueSink) return &self.runtime;
        unreachable;
    }
};

const nested_payload =
    "--inner\r\n" ++
    "Content-Disposition: form-data; name=nested; filename=nested.txt\r\n" ++
    "Content-Type: text/plain\r\n\r\n" ++
    "nested-data\r\n" ++
    "--inner--";

const opaque_wire =
    "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=batch.bin\r\n" ++
    "Content-Type: multipart/mixed; boundary=inner\r\n\r\n" ++
    nested_payload ++ "\r\n--B--";

test "declared multipart mixed file remains one opaque upload" {
    const Runtime = upload_runtime.Runtime(OpaqueHandler);
    var context = OpaqueContext{};
    var source = OpaqueSource{};
    var runtime: Runtime = undefined;
    try runtime.initInPlace("B", &context, &source);

    const fed = try runtime.feedProgress(opaque_wire);
    try std.testing.expectEqual(opaque_wire.len, fed.consumed);
    try std.testing.expectEqual(.ready, fed.flow);
    try std.testing.expectEqual(.complete, (try runtime.finishProgress()).flow);

    const state = try runtime.state();
    try std.testing.expectEqual(@as(u8, 1), state.starts);
    try std.testing.expect(state.media_valid);
    try std.testing.expectEqualStrings(
        nested_payload,
        source.runtime.bytes[0..source.runtime.bytes_len],
    );

    const summaries = try runtime.summaries();
    try std.testing.expectEqual(@as(usize, 1), summaries.upload.slice().len);
    try std.testing.expectEqual(
        @as(u64, nested_payload.len),
        summaries.upload.slice()[0].bytes,
    );
    try std.testing.expectEqual(@as(u8, 10), summaries.upload.slice()[0].writes);
    try std.testing.expectEqual(@as(u8, 1), source.runtime.begins);
    try std.testing.expectEqual(@as(u8, 10), source.runtime.writes);
    try std.testing.expectEqual(@as(u8, 1), source.runtime.finishes);

    try runtime.markCommitReady();
    try std.testing.expectEqual(.complete, try runtime.startCommit());
    try std.testing.expectEqual(@as(u8, 1), source.runtime.commits);
}

const Code = struct {
    input: []const u8,

    pub fn parseText(input: []const u8) multipart.TextDecodeError!Code {
        if (input.len != 3) return error.InvalidSyntax;
        for (input) |byte| {
            if (byte < 'A' or byte > 'Z') return error.InvalidRepresentation;
        }
        return .{ .input = input };
    }
};

const ScalarTarget = struct {
    code: Code,
    decimal: f32,
};

const ScalarSpec = @TypeOf(multipart.decode(.{
    .code = multipart.field(Code, multipart.required),
    .decimal = multipart.field(f32, multipart.required),
}, .{}));

const ScalarContext = struct {
    code: [3]u8 = undefined,
    code_len: u8 = 0,
    decimal: f32 = 0,
    callbacks: u8 = 0,
};

const ScalarConsumer = struct {
    pub const State = *ScalarContext;

    pub fn init(_: ScalarConsumer, context: *ScalarContext) State {
        return context;
    }

    pub fn field(_: ScalarConsumer, state: *State, event: ScalarSpec.Field) void {
        const values = state.*;
        values.callbacks += 1;
        switch (event) {
            .code => |value| {
                @memcpy(values.code[0..value.input.len], value.input);
                values.code_len = @intCast(value.input.len);
            },
            .decimal => |value| values.decimal = value,
        }
    }
};

const ScalarHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = ScalarSpec;
    };
    pub const MultipartState = ScalarConsumer.State;
    pub const handler_fn = ScalarConsumer{};
};

const valid_pairs = [_]flat_wire.Pair{
    .{ .name = "code", .value = "ABC" },
    .{ .name = "decimal", .value = "-.5e+2" },
};

test "multipart custom text and float values match query and form binding" {
    const query_value = try bindReady(.query, &valid_pairs);
    const form_value = try bindReady(.form, &valid_pairs);
    const multipart_value = try parseScalarMultipart(&valid_pairs);

    try std.testing.expectEqualStrings("ABC", query_value.code.input);
    try std.testing.expectEqualStrings(query_value.code.input, form_value.code.input);
    try std.testing.expectEqualStrings(
        query_value.code.input,
        multipart_value.code[0..multipart_value.code_len],
    );
    try std.testing.expectEqual(@as(f32, -50), query_value.decimal);
    try std.testing.expectEqual(query_value.decimal, form_value.decimal);
    try std.testing.expectEqual(query_value.decimal, multipart_value.decimal);
    try std.testing.expectEqual(@as(u8, 2), multipart_value.callbacks);
}

test "multipart scalar rejection matches flat invalid and cardinality classes" {
    const invalid_custom = [_]flat_wire.Pair{
        .{ .name = "code", .value = "AbC" },
        .{ .name = "decimal", .value = "1" },
    };
    try expectScalarFailure(
        &invalid_custom,
        .invalid_value,
        "code",
        error.InvalidField,
        0,
    );

    const invalid_floats = [_][]const u8{
        "", "NaN", "inf", "+1", "0x1p2", "1e", "--1", " 1", "1e9999",
    };
    for (invalid_floats) |input| {
        const pairs = [_]flat_wire.Pair{
            .{ .name = "code", .value = "ABC" },
            .{ .name = "decimal", .value = input },
        };
        try expectScalarFailure(
            &pairs,
            .invalid_value,
            "decimal",
            error.InvalidField,
            1,
        );
    }

    const duplicate = [_]flat_wire.Pair{
        .{ .name = "code", .value = "ABC" },
        .{ .name = "decimal", .value = "1" },
        .{ .name = "code", .value = "XYZ" },
    };
    try expectScalarFailure(
        &duplicate,
        .cardinality,
        "code",
        error.InvalidMultipart,
        2,
    );

    const missing = [_]flat_wire.Pair{
        .{ .name = "code", .value = "ABC" },
    };
    try expectScalarFailure(
        &missing,
        .missing_field,
        "decimal",
        error.InvalidMultipart,
        1,
    );
}

fn bindReady(source: flat_wire.Source, pairs: []const flat_wire.Pair) !ScalarTarget {
    var scratch: [1]u8 = undefined;
    var arena = flat_schema.Arena.init(&scratch);
    return switch (flat_schema.bind(
        ScalarTarget,
        table(source, pairs),
        &arena,
        .{},
    )) {
        .ready => |value| value,
        .rejected => error.TestUnexpectedResult,
    };
}

fn parseScalarMultipart(pairs: []const flat_wire.Pair) !ScalarContext {
    const Runtime = scalar_runtime.Runtime(ScalarHandler);
    var wire_storage: [1024]u8 = undefined;
    const wire = try scalarWire(&wire_storage, pairs);
    var context = ScalarContext{};
    var runtime = try Runtime.init("S", &context);
    try runtime.feed(wire);
    try runtime.finish();
    return context;
}

fn expectScalarFailure(
    pairs: []const flat_wire.Pair,
    flat_class: flat_schema.IssueClass,
    field: []const u8,
    multipart_error: scalar_runtime.Error,
    callbacks: u8,
) !void {
    try expectFlatFailure(.query, pairs, flat_class, field);
    try expectFlatFailure(.form, pairs, flat_class, field);

    const Runtime = scalar_runtime.Runtime(ScalarHandler);
    var wire_storage: [1024]u8 = undefined;
    const wire = try scalarWire(&wire_storage, pairs);
    var context = ScalarContext{};
    var runtime = try Runtime.init("S", &context);
    var actual: ?scalar_runtime.Error = null;
    runtime.feed(wire) catch |problem| {
        actual = problem;
    };
    if (actual == null) runtime.finish() catch |problem| {
        actual = problem;
    };
    try std.testing.expectEqual(multipart_error, actual.?);
    try std.testing.expectEqual(callbacks, context.callbacks);
}

fn expectFlatFailure(
    source: flat_wire.Source,
    pairs: []const flat_wire.Pair,
    class: flat_schema.IssueClass,
    field: []const u8,
) !void {
    var scratch: [1]u8 = undefined;
    var arena = flat_schema.Arena.init(&scratch);
    const issue = switch (flat_schema.bind(
        ScalarTarget,
        table(source, pairs),
        &arena,
        .{},
    )) {
        .rejected => |value| value,
        .ready => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(class, issue.class);
    try std.testing.expectEqualStrings(field, issue.field.?);
}

fn table(source: flat_wire.Source, pairs: []const flat_wire.Pair) flat_wire.Table {
    return .{
        .source = source,
        .segments_count = @intCast(pairs.len),
        .pairs = pairs,
    };
}

fn scalarWire(buffer: []u8, pairs: []const flat_wire.Pair) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (pairs) |pair| {
        try writer.print(
            "--S\r\nContent-Disposition: form-data; name={s}\r\n\r\n{s}\r\n",
            .{ pair.name, pair.value },
        );
    }
    try writer.print("--S--", .{});
    return writer.buffered();
}

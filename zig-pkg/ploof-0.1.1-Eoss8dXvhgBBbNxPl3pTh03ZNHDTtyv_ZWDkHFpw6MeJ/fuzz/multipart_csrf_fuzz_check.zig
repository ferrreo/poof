const std = @import("std");

const csrf = @import("../src/csrf.zig");
const csrf_request = @import("../src/internal/csrf/request.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const multipart = @import("../src/multipart.zig");
const runtime_module = @import("../src/internal/application/multipart_runtime.zig");

const raw_token = [_]u8{0x5a} ** csrf.synchronizer_bytes;
const encoded_token = csrf_request.encodeSynchronizer(&raw_token);
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

const Spec = @TypeOf(multipart.decode(.{
    ._csrf = csrf.multipartField(),
    .note = multipart.bytesField(multipart.optional),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 2048,
    .total_body_bytes_max = 1024,
    .file_bytes_max = 128,
    .field_bytes_max = 8,
    .parts_max = 4,
    .files_max = 1,
    .part_headers_max = 3,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
} }));

const Context = struct {
    csrf_request: ?*csrf.RequestState,
    init_calls: u8 = 0,
    field_calls: u8 = 0,
};

const Consumer = struct {
    pub const State = struct { context: *Context };

    pub fn init(_: Consumer, context: *Context) State {
        context.init_calls += 1;
        return .{ .context = context };
    }

    pub fn field(_: Consumer, state: *State, value: Spec.Field) void {
        switch (value) {
            .note => state.context.field_calls += 1,
        }
    }
};

const Handler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = Spec;
    };
    pub const MultipartState = Consumer.State;
    pub const handler_fn = Consumer{};
};
const Runtime = runtime_module.Runtime(Handler);

const Status = enum(u8) {
    complete,
    body_rejected,
    csrf_rejected,
    invalid,
    limit,
    unsupported,
};

const Result = struct {
    status: Status,
    csrf_status: csrf_request.Status,
    token_source: csrf.TokenSource,
    terminal: runtime_module.TerminalSource,
    init_calls: u8,
    field_calls: u8,
};

test "multipart CSRF parser fuzz preserves token admission invariants" {
    try std.testing.fuzz({}, fuzzMultipartCsrf, .{ .corpus = &corpus });
}

const corpus = struct {
    const valid = fuzz_support.smithInput("\x04" ++ encoded_token);
    const duplicate = fuzz_support.smithInput("\x05" ++ encoded_token);
    const filename = fuzz_support.smithInput("\x06" ++ encoded_token);
    const header_only = fuzz_support.smithInput("\x08");
    const mixed = fuzz_support.smithInput("\x0c" ++ encoded_token);
    const missing = fuzz_support.smithInput("\x00");
    const oversized = fuzz_support.smithInput("\x04" ++ ("x" ** 129));
    const values = [_][]const u8{
        &valid,
        &duplicate,
        &filename,
        &header_only,
        &mixed,
        &missing,
        &oversized,
    };
}.values;

fn fuzzMultipartCsrf(_: void, smith: *std.testing.Smith) !void {
    var generated: [161]u8 = undefined;
    const input = generated[0..smith.slice(&generated)];
    const selector = if (input.len == 0) 0 else input[0];
    var token_storage: [160]u8 = undefined;
    const token = normalizedToken(input, &token_storage);
    var body_storage: [1024]u8 = undefined;
    const body = try buildBody(&body_storage, selector, token);

    const whole = try execute(body, selector, body.len);
    const bytewise = try execute(body, selector, 1);
    const fragmented = try execute(body, selector, 1 + selector % 31);
    try expectEqual(whole, bytewise);
    try expectEqual(whole, fragmented);
    try validateResult(whole, selector);
}

fn normalizedToken(input: []const u8, output: *[160]u8) []const u8 {
    if (input.len <= 1) return "";
    const bytes = input[1..@min(input.len, output.len + 1)];
    for (bytes, 0..) |byte, index| {
        output[index] = if (std.mem.indexOfScalar(u8, alphabet, byte) != null)
            byte
        else
            alphabet[byte & 63];
    }
    return output[0..bytes.len];
}

fn execute(body: []const u8, selector: u8, fragment_bytes: usize) !Result {
    var state = csrf.RequestState{ .body_source = .multipart };
    state.beginSynchronizer(&raw_token);
    if (selector & 0x08 != 0) {
        try std.testing.expect(state.observe(.header, &encoded_token));
    }
    var context = Context{ .csrf_request = &state };
    var runtime = try Runtime.init("F", &context);
    var offset: usize = 0;
    while (offset < body.len) {
        const end = @min(body.len, offset + fragment_bytes);
        runtime.feed(body[offset..end]) catch |problem| {
            return resultForError(&runtime, &context, &state, problem);
        };
        offset = end;
    }
    runtime.finish() catch |problem| {
        return resultForError(&runtime, &context, &state, problem);
    };
    const accepted = state.completeBody();
    return capture(&runtime, &context, &state, if (accepted) .complete else .body_rejected);
}

fn resultForError(
    runtime: *Runtime,
    context: *const Context,
    state: *csrf.RequestState,
    problem: anytype,
) Result {
    const status: Status = if (problem == error.FileRejected)
        .csrf_rejected
    else if (problem == error.InvalidMultipart or problem == error.InvalidField)
        .invalid
    else if (problem == error.LimitExceeded)
        .limit
    else if (problem == error.UnsupportedMedia)
        .unsupported
    else
        unreachable;
    return capture(runtime, context, state, status);
}

fn capture(
    runtime: *Runtime,
    context: *const Context,
    state: *const csrf.RequestState,
    status: Status,
) Result {
    return .{
        .status = status,
        .csrf_status = state.status,
        .token_source = state.token_source,
        .terminal = runtime.terminalSource(),
        .init_calls = context.init_calls,
        .field_calls = context.field_calls,
    };
}

fn validateResult(result: Result, selector: u8) !void {
    try std.testing.expect(result.init_calls <= 1);
    try std.testing.expect(result.field_calls <= 1);
    try std.testing.expect(result.field_calls <= result.init_calls);
    if (result.csrf_status == .accepted) {
        try std.testing.expect(result.token_source == .header or
            result.token_source == .multipart);
    }
    if (result.status == .csrf_rejected or result.status == .body_rejected) {
        try std.testing.expectEqual(csrf_request.Status.rejected, result.csrf_status);
    }
    if (result.status == .csrf_rejected) {
        try std.testing.expectEqual(runtime_module.TerminalSource.rejection, result.terminal);
    }
    if (selector & 0x04 == 0 and selector & 0x08 == 0) {
        try std.testing.expect(result.csrf_status != .accepted);
    }
}

fn expectEqual(expected: Result, actual: Result) !void {
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.csrf_status, actual.csrf_status);
    try std.testing.expectEqual(expected.token_source, actual.token_source);
    try std.testing.expectEqual(expected.terminal, actual.terminal);
    try std.testing.expectEqual(expected.init_calls, actual.init_calls);
    try std.testing.expectEqual(expected.field_calls, actual.field_calls);
}

fn buildBody(output: []u8, selector: u8, token: []const u8) ![]const u8 {
    var used: usize = 0;
    const marker_present = selector & 0x04 != 0;
    const note_present = selector & 0x10 != 0;
    const note_first = selector & 0x20 != 0;
    if (note_present and note_first) try appendNote(output, &used);
    if (marker_present) try appendMarker(output, &used, token, selector & 0x02 != 0);
    if (marker_present and selector & 0x01 != 0) {
        try appendMarker(output, &used, token, false);
    }
    if (note_present and !note_first) try appendNote(output, &used);
    try append(output, &used, "--F--\r\n");
    return output[0..used];
}

fn appendMarker(output: []u8, used: *usize, token: []const u8, filename: bool) !void {
    try append(output, used, "--F\r\nContent-Disposition: form-data; name=\"_csrf\"");
    if (filename) try append(output, used, "; filename=\"x\"");
    try append(output, used, "\r\n\r\n");
    try append(output, used, token);
    try append(output, used, "\r\n");
}

fn appendNote(output: []u8, used: *usize) !void {
    try append(output, used, "--F\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n\r\nok\r\n");
}

fn append(output: []u8, used: *usize, bytes: []const u8) !void {
    if (bytes.len > output.len - used.*) return error.NoSpaceLeft;
    @memcpy(output[used.*..][0..bytes.len], bytes);
    used.* += bytes.len;
}

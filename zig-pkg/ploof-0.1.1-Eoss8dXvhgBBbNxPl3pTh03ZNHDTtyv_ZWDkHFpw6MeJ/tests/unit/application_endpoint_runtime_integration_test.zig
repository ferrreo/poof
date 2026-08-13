const std = @import("std");
const application = @import("../../src/application.zig");
const connection_body = @import("../../src/internal/runtime/connection/body.zig");
const body_runtime = @import("../../src/internal/runtime/connection/body_runtime.zig");
const config = @import("../../src/internal/runtime/config.zig");
const endpoint = @import("../../src/endpoint.zig");
const query = @import("../../src/query.zig");
const request_accept_encoding = @import("../../src/internal/http1/request_accept_encoding.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const response_staging_bytes: u32 = 72 * 1024;
const response_data_bytes = response_staging_bytes + 256;
const response_data = "x" ** response_data_bytes;
const expected_json =
    "{\"request_id\":41,\"trace\":\"runtime\",\"data\":\"" ++
    response_data ++
    "\"}";
const expected_json_bytes = 74_029;
const expected_wrapped_json =
    "{\"body\":\"{\\\"request_id\\\":41,\\\"trace\\\":\\\"runtime\\\"," ++
    "\\\"data\\\":\\\"" ++ response_data ++ "\\\"}\"}";
const seeded_data_bytes = 96 * 1024;
const seeded_alphabet =
    "!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}~";
const seeded_data = seeded: {
    @setEvalBranchQuota(1_000_000);
    var result: [seeded_data_bytes]u8 = undefined;
    var state: u64 = 0x6a09_e667_f3bc_c909;
    for (&result) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = seeded_alphabet[state % seeded_alphabet.len];
    }
    break :seeded result;
};
const expected_seeded_json =
    "{\"request_id\":41,\"trace\":\"runtime\",\"data\":\"" ++
    seeded_data ++
    "\"}";
const response_json_bytes_max = expected_seeded_json.len;

comptime {
    if (expected_json.len != expected_json_bytes) {
        @compileError("endpoint runtime fixture length drifted");
    }
    if (expected_json.len <= response_staging_bytes) {
        @compileError("endpoint runtime fixture must exceed response staging");
    }
}

const QueryInput = struct {
    request_id: u16,
    trace: []const u8,
};

const Definition = endpoint.Endpoint(.{
    .query = query.typed(QueryInput, .{
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = response_json_bytes_max,
});

const AppState = struct {
    calls: u8 = 0,
    query_matched: bool = false,
    json_failed: bool = false,
    seeded_response: bool = false,
    replace_response: bool = false,
    wrap_response: bool = false,
    wrap_failed: bool = false,
    replacements: u8 = 0,
};

const TestContext = application.Context(AppState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;

fn endpointHandler(context: *TestContext, request: Definition.InputType) TestResponse {
    context.state.calls += 1;
    context.state.query_matched = request.query.request_id == 41 and
        std.mem.eql(u8, request.query.trace, "runtime");
    const data: []const u8 = if (context.state.seeded_response)
        &seeded_data
    else
        response_data;
    return context.json(.ok, .{
        .request_id = request.query.request_id,
        .trace = request.query.trace,
        .data = data,
    }) catch {
        context.state.json_failed = true;
        return context.empty(.internal_server_error);
    };
}

const ReplaceResponse = struct {
    pub const State = void;

    pub fn responsePhase(
        _: ReplaceResponse,
        context: *TestContext,
        _: *State,
        value: *TestResponse,
    ) void {
        if (context.state.wrap_response) {
            const previous = value.bodyBytes();
            value.* = context.json(.ok, .{ .body = previous }) catch {
                context.state.wrap_failed = true;
                value.* = context.empty(.internal_server_error);
                return;
            };
            return;
        }
        if (!context.state.replace_response) return;
        context.state.replacements += 1;
        value.* = context.textStatic(.internal_server_error, "middleware-failure");
    }

    pub const response = responsePhase;
};

const handler = Definition.handle(endpointHandler);
const TestApp = application.Application(.{
    .State = AppState,
    .middleware = .{ReplaceResponse{}},
    .response_gzip = application.ResponseGzip{
        .minimum_bytes = 0,
        .level = .fastest,
    },
    .routes = .{route.get("/endpoint", handler)},
});

const test_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 128,
    .pipeline_bytes_per_connection = 128,
    .response_bytes_per_request = response_staging_bytes,
    .submission_entries = 8,
    .completion_entries = 16,
});
const TestStorage = worker_storage.Storage(TestApp, test_limits);

const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    state: AppState = .{},
    connection: u16 = undefined,

    fn init(self: *Harness) !void {
        try self.storage.init(&self.slab);
        self.connection = self.storage.acquireConnection(.{ .value = 41 }) orelse {
            return error.TestUnexpectedResult;
        };
    }

    fn run(self: *Harness, accept_encoding: request_accept_encoding.Preferences) !u16 {
        return self.runMethod("GET", accept_encoding);
    }

    fn runMethod(
        self: *Harness,
        method: []const u8,
        accept_encoding: request_accept_encoding.Preferences,
    ) !u16 {
        const request_input = makeInput(method, accept_encoding);
        var request_plan = TestApp.plan(
            request_input,
            &self.storage.route_search_workspace,
        );
        const request = switch (self.storage.acquireRequestClassified(
            self.connection,
            request_plan.body.workspace_class,
            false,
        )) {
            .acquired => |index| index,
            else => return error.TestUnexpectedResult,
        };
        const head = try TestApp.prepareHeadPlannedIn(
            &self.state,
            &self.storage.requests[request].workspace,
            try self.storage.bodyWorkspace(request),
            self.storage.responseWritable(request),
            &request_plan,
            .{},
        );
        switch (head) {
            .receive_body => |plan| if (plan.kind != .input) {
                return error.TestUnexpectedResult;
            },
            .prepared => return error.TestUnexpectedResult,
        }
        const receiver = switch (connection_body.FixedIdentity.init(0, 0, 0)) {
            .accepted => |value| value,
            .over_limit => return error.TestUnexpectedResult,
        };
        try body_runtime.startFixed(&self.storage, request, receiver, .none);
        const finished = try body_runtime.finish(TestApp, &self.storage, request);
        try std.testing.expectEqual(body_runtime.Event.prepared, finished.event);
        return request;
    }

    fn wire(self: *const Harness, request: u16) []const u8 {
        const used: usize = self.storage.requests[request].response_used;
        return self.storage.responseReadable(request)[0..used];
    }
};

fn makeInput(
    method: []const u8,
    accept_encoding: request_accept_encoding.Preferences,
) application.Input {
    return .{
        .method = method,
        .path = "/endpoint",
        .raw_target = "/endpoint?request_id=41&trace=runtime",
        .raw_path = "/endpoint",
        .raw_query = "request_id=41&trace=runtime",
        .date = fixed_date,
        .accept_encoding = accept_encoding,
    };
}

fn expectMaterialized(state: AppState) !void {
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expect(state.query_matched);
    try std.testing.expect(!state.json_failed);
}

const expected_identity_wire =
    "HTTP/1.1 200 OK\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-type: application/json; charset=utf-8\r\n" ++
    "content-length: 74029\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    expected_json;

test "zero-length query Endpoint commits exact large JSON identity wire externally" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.run(.{ .gzip = 0, .identity = 1000 });

    try expectMaterialized(harness.state);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        harness.storage.responseSource(request),
    );
    const wire = harness.wire(request);
    try std.testing.expect(wire.len > response_staging_bytes);
    try std.testing.expectEqualStrings(expected_identity_wire, wire);
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

test "large Endpoint JSON gzip round trips from external response source" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.run(.{ .gzip = 1000, .identity = 0 });

    try expectMaterialized(harness.state);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        harness.storage.responseSource(request),
    );
    const wire = harness.wire(request);
    try std.testing.expect(wire.len < response_staging_bytes);
    try expectGzipRoundTrip(wire, expected_json);
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

test "large incompressible Endpoint JSON gzip exceeds internal staging" {
    var harness = Harness{};
    harness.state.seeded_response = true;
    try harness.init();
    const request = try harness.run(.{ .gzip = 1000, .identity = 0 });

    try expectMaterialized(harness.state);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        harness.storage.responseSource(request),
    );
    const wire = harness.wire(request);
    try std.testing.expect(wire.len > response_staging_bytes);
    try expectGzipRoundTrip(wire, expected_seeded_json);
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

test "large Endpoint JSON HEAD keeps hypothetical gzip length and suppresses body" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.runMethod("HEAD", .{ .gzip = 1000, .identity = 0 });

    try expectMaterialized(harness.state);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        harness.storage.responseSource(request),
    );
    const wire = harness.wire(request);
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(marker + 4, wire.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        wire[0..marker],
        "content-encoding: gzip\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        wire[0..marker],
        "content-length: ",
    ) != null);
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

fn expectGzipRoundTrip(wire: []const u8, expected: []const u8) !void {
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    const head = wire[0 .. marker + 4];
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "content-encoding: gzip\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "vary: Accept-Encoding\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "content-type: application/json; charset=utf-8\r\n",
    ) != null);

    var input_reader = std.Io.Reader.fixed(wire[marker + 4 ..]);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var decoded: [response_json_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&decoded);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualStrings(expected, decoded[0..written]);
}

const expected_failure_wire =
    "HTTP/1.1 500 Internal Server Error\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 18\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "middleware-failure";

test "middleware replacement discards large Endpoint JSON and commits marker internally" {
    var harness = Harness{};
    harness.state.replace_response = true;
    try harness.init();
    const request = try harness.run(.{ .gzip = 0, .identity = 1000 });

    try expectMaterialized(harness.state);
    try std.testing.expectEqual(@as(u8, 1), harness.state.replacements);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.internal,
        harness.storage.responseSource(request),
    );
    try std.testing.expectEqualStrings(expected_failure_wire, harness.wire(request));
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

test "response middleware re-encodes live Endpoint JSON through disjoint storage" {
    var harness = Harness{};
    harness.state.wrap_response = true;
    try harness.init();
    const request = try harness.run(.{ .gzip = 0, .identity = 1000 });

    try expectMaterialized(harness.state);
    try std.testing.expect(!harness.state.wrap_failed);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        harness.storage.responseSource(request),
    );
    const wire = harness.wire(request);
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected_wrapped_json, wire[marker + 4 ..]);
    _ = try TestApp.complete(&harness.storage.requests[request].workspace);
}

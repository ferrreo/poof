const split = @import("worker_gzip_io_uring_runtime_test_support.zig");
pub const std = @import("std");
pub const linux = std.os.linux;

pub const application = @import("../../../../src/application.zig");
pub const body = @import("../../../../src/body.zig");
pub const endpoint = @import("../../../../src/endpoint.zig");
pub const json = @import("../../../../src/json.zig");
pub const multipart = @import("../../../../src/multipart.zig");
pub const query = @import("../../../../src/query.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const allocation_guard = @import("../../../../src/internal/runtime/allocation_guard.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const gzip_encoder = @import("../../../../src/internal/runtime/gzip/encoder.zig");
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const epoch_second: i64 = 1_784_030_400;
pub const completion_limit: u16 = 512;
pub const completion_wait_ns: u64 = 2 * std.time.ns_per_s;
pub const guarded_request_count: u16 = 3;
pub const typed_json_body = "{\"name\":\"zig\",\"enabled\":true}";
pub const typed_gzip_bytes_max = gzip_encoder.bound(typed_json_body.len) catch unreachable;
pub const large_body_bytes: usize = 3 * 1024;
pub const large_gzip_bytes_max: usize = gzip_encoder.bound(large_body_bytes) catch unreachable;
pub const multipart_boundary = "uring-boundary";
pub const multipart_count_part =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n\r\n" ++
    "23\r\n";
pub const multipart_upload_head =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n";
pub const multipart_close = "\r\n--" ++ multipart_boundary ++ "--\r\n";
pub const multipart_body = multipart_count_part ++ multipart_upload_head ++
    "abcdef" ++ multipart_close;
pub const multipart_large_body = multipart_count_part ++ multipart_upload_head ++
    [_]u8{'x'} ** 700 ++ multipart_close;
pub const multipart_gzip_bytes_max = gzip_encoder.bound(multipart_large_body.len) catch unreachable;
pub const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
pub const gzip_abcdef = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x03, 0x00,
    0xef, 0x39, 0x8e, 0x4b, 0x06, 0x00, 0x00, 0x00,
};
pub const gzip_twelve = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf,
    0xc8, 0xcc, 0xca, 0xce, 0x01, 0x00, 0x24, 0x1b, 0x78,
    0xf6, 0x0c, 0x00, 0x00, 0x00,
};
pub const gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: gzip.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n\r\n";
pub const expect_gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: gzip.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const chunked_gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: gzip.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
pub const chunked_gzip_wire = "1a\r\n" ++ gzip_abcdef ++
    "\r\n0\r\nX-Check: yes\r\n\r\n";
pub const ping_request =
    "GET /ping HTTP/1.1\r\n" ++
    "Host: gzip.integration.test\r\n\r\n";
pub const multipart_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: gzip.integration.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ multipart_boundary ++ "\r\n" ++
    "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{multipart_body.len}) ++
    "\r\n\r\n";
pub const body_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 7\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "body-ok";
pub const ping_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "pong";
pub const typed_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: application/json; charset=utf-8\r\n" ++
    "content-length: 45\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "{\"request_id\":41,\"name\":\"zig\",\"enabled\":true}";
pub const multipart_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 12\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "multipart-ok";
pub const bad_request_response = rejectionResponse("400 Bad Request");
pub const too_large_response = rejectionResponse("413 Payload Too Large");
pub const unavailable_response = rejectionResponse("503 Service Unavailable");

pub const LargeFixture = struct {
    decoded: [large_body_bytes]u8,
    encoded: [large_gzip_bytes_max]u8,
    encoded_len: usize,

    pub fn init(self: *LargeFixture) !void {
        var random_state: u64 = 0x9e3779b97f4a7c15;
        for (&self.decoded) |*byte| {
            random_state ^= random_state << 13;
            random_state ^= random_state >> 7;
            random_state ^= random_state << 17;
            byte.* = @truncate(random_state);
        }

        var workspace: gzip_encoder.Workspace = undefined;
        const encoded = try gzip_encoder.compress(
            &workspace,
            &self.decoded,
            &self.encoded,
            .fastest,
        );
        self.encoded_len = encoded.len;
    }

    pub fn gzip(self: *const LargeFixture) []const u8 {
        return self.encoded[0..self.encoded_len];
    }
};

pub fn rejectionResponse(comptime status: []const u8) []const u8 {
    return "HTTP/1.1 " ++ status ++ "\r\n" ++
        "content-length: 0\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "connection: close\r\n\r\n";
}

pub const State = struct {
    body_calls: u16 = 0,
    ping_calls: u16 = 0,
    typed_calls: u16 = 0,
    multipart_calls: u16 = 0,
    multipart_count: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
    bodies_valid: bool = true,
    trailers_valid: bool = true,
    typed_valid: bool = true,
    large_expected: []const u8 = &.{},
};

pub const Context = application.Context(State, response.standard_head_limits);

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub fn echo(context: *Context, value: body.Bytes) Context.ResponseType {
    context.state.body_calls += 1;
    context.state.bodies_valid = context.state.bodies_valid and value.eql("abcdef");
    const trailers = context.request.trailers.raw();
    if (trailers.count() != 0) {
        const check = context.request.trailers.all("x-check");
        context.state.trailers_valid = context.state.trailers_valid and
            trailers.count() == 1 and check.count() == 1 and
            std.mem.eql(u8, check.first().?, "yes");
    }
    return context.textStatic(.ok, "body-ok");
}

pub fn ping(context: *Context) Context.ResponseType {
    context.state.ping_calls += 1;
    return context.textStatic(.ok, "pong");
}

pub fn largeEcho(context: *Context, value: body.Bytes) Context.ResponseType {
    context.state.body_calls += 1;
    context.state.bodies_valid = context.state.bodies_valid and
        value.eql(context.state.large_expected);
    return context.textStatic(.ok, "body-ok");
}

pub const TypedQuery = struct { request_id: u16 };
pub const TypedPayload = struct {
    name: []const u8,
    enabled: bool,
};
pub const TypedEndpoint = endpoint.Endpoint(.{
    .query = query.typed(TypedQuery, .{
        .segments_max = 1,
        .unknown_fields = .reject,
    }),
    .body = json.typed(TypedPayload, .{
        .encoded_wire_bytes_max = typed_gzip_bytes_max,
        .decoded_bytes_max = typed_json_body.len,
        .parse_memory_bytes_max = 2048,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = 128,
});

pub fn typed(context: *Context, input: TypedEndpoint.InputType) Context.ResponseType {
    context.state.typed_calls += 1;
    context.state.typed_valid = context.state.typed_valid and
        input.query.request_id == 41 and input.body.enabled and
        std.mem.eql(u8, input.body.name, "zig");
    return context.json(.ok, .{
        .request_id = input.query.request_id,
        .name = input.body.name,
        .enabled = input.body.enabled,
    }) catch context.empty(.internal_server_error);
}

pub const MultipartBody = multipart.decode(.{
    .count = multipart.field(u16, multipart.required),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = multipart_gzip_bytes_max,
    .total_body_bytes_max = 1536,
    .file_bytes_max = 1024,
    .field_bytes_max = 16,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 32,
}) });
pub const MultipartEndpoint = endpoint.Endpoint(.{ .body = MultipartBody });
pub const MultipartSpec = @TypeOf(MultipartBody);

pub const MultipartConsumer = struct {
    pub const State = struct { count: u16 = 0 };

    pub fn init(_: MultipartConsumer, _: *Context) MultipartConsumer.State {
        return .{};
    }

    pub fn field(
        _: MultipartConsumer,
        state: *MultipartConsumer.State,
        value: @TypeOf(MultipartBody).Field,
    ) void {
        state.count = value.count;
    }

    pub fn fileStart(
        _: MultipartConsumer,
        _: *Context,
        _: *MultipartConsumer.State,
        _: MultipartSpec.FileStart,
    ) MultipartSpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: MultipartConsumer,
        context: *Context,
        state: *MultipartConsumer.State,
        _: MultipartEndpoint.InputType,
        _: MultipartSpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        context.state.multipart_calls += 1;
        context.state.multipart_count = state.count;
        return multipart.commit(context.textStatic(.ok, "multipart-ok"));
    }
};

pub const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .routes = .{
        route.post("/echo", body.bytes(.{
            .encoded_wire_bytes_max = 80,
            .decoded_bytes_max = 8,
        }, echo)),
        route.post("/large", body.bytes(.{
            .encoded_wire_bytes_max = large_gzip_bytes_max,
            .decoded_bytes_max = large_body_bytes,
        }, largeEcho)),
        route.post("/typed", TypedEndpoint.handle(typed)),
        route.post("/multipart", MultipartEndpoint.handle(MultipartConsumer{})),
        route.get("/ping", ping),
    },
});

pub const limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .chunked_workspace_slots = 2,
    .receive_buffers = 4,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 32,
    .completion_entries = 64,
    .gzip = .{
        .decoder_slots = 1,
        .input_chunks_per_slot = 4,
        .members_max = 2,
        .thread_stack_bytes = 128 * 1024,
    },
    .timeouts = .{
        .first_head_ns = 2 * std.time.ns_per_s,
        .keepalive_idle_ns = 2 * std.time.ns_per_s,
        .reused_head_progress_ns = 2 * std.time.ns_per_s,
        .body_inactivity_ns = 2 * std.time.ns_per_s,
        .write_stall_ns = 2 * std.time.ns_per_s,
    },
});

pub const ReceiveBuffers = buffer_ring.BufferRing(
    limits.receive_buffers,
    limits.receive_buffer_bytes,
    47,
);
pub const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
pub const Storage = worker_storage.Storage(App, limits);
pub const Worker = worker_runtime.Worker(App, Storage, Backend);

pub const ActiveGzip = struct {
    connection_index: u16,
    request_index: u16,
};

pub const Runtime = split.Runtime;

pub const expectClosedRejection = split.expectClosedRejection;

pub const expectGuardedChild = split.expectGuardedChild;

pub const runGuardedGzip = split.runGuardedGzip;

pub const expectState = split.expectState;

pub const expectMultipartResult = split.expectMultipartResult;

pub const activeGzip = split.activeGzip;

pub const waitDecodePaused = split.waitDecodePaused;

pub const waitForSpaceNotification = split.waitForSpaceNotification;

pub const expectReadable = split.expectReadable;

pub const discardLiveSockets = split.discardLiveSockets;

pub const resolveStep = split.resolveStep;

pub const waitCompletion = split.waitCompletion;

pub const connectClient = split.connectClient;

pub const sendAll = split.sendAll;

pub const receiveExact = split.receiveExact;

pub const monotonicNow = split.monotonicNow;

test {
    _ = @import("worker_gzip_io_uring_integration_test_part_1.zig");
}

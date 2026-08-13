pub const std = @import("std");
pub const linux = std.os.linux;

pub const application = @import("../../../../src/application.zig");
pub const body = @import("../../../../src/body.zig");
pub const endpoint = @import("../../../../src/endpoint.zig");
pub const json = @import("../../../../src/json.zig");
pub const query = @import("../../../../src/query.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const allocation_guard = @import("../../../../src/internal/runtime/allocation_guard.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const epoch_second: i64 = 1_784_030_400;
pub const completion_limit: u16 = 256;
pub const completion_wait_ns: u64 = 2 * std.time.ns_per_s;
pub const guarded_request_count: u16 = 3;
pub const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
pub const echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 6\r\n\r\n";
pub const expect_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 6\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const chunked_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
pub const expect_chunked_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const undeclared_chunked_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
pub const chunked_echo_body =
    "2\r\nab\r\n" ++
    "2\r\ncd\r\n" ++
    "2\r\nef\r\n" ++
    "0\r\nX-Check: yes\r\n\r\n";
pub const ping_request =
    "GET /ping HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n\r\n";
pub const typed_request =
    "POST /typed?request_id=41 HTTP/1.1\r\n" ++
    "Host: body.integration.test\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 29\r\n\r\n" ++
    "{\"name\":\"zig\",\"enabled\":true}";
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
pub const bad_request_response =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";

pub const State = struct {
    body_calls: u16 = 0,
    ping_calls: u16 = 0,
    typed_calls: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
    bodies_valid: bool = true,
    trailer_calls: u16 = 0,
    trailers_valid: bool = true,
    typed_valid: bool = true,
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
        context.state.trailer_calls += 1;
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
        .encoded_wire_bytes_max = 64,
        .decoded_bytes_max = 64,
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

pub const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .routes = .{
        route.post("/echo", body.bytes(.{
            .encoded_wire_bytes_max = chunked_echo_body.len,
            .decoded_bytes_max = 8,
        }, echo)),
        route.post("/typed", TypedEndpoint.handle(typed)),
        route.get("/ping", ping),
    },
});

pub const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 16,
    .completion_entries = 32,
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
    44,
);
pub const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
pub const Storage = worker_storage.Storage(App, limits);
pub const Worker = worker_runtime.Worker(App, Storage, Backend);

pub const Runtime = struct {
    listener: listener_runtime.Listener = undefined,
    client: linux.fd_t = -1,
    buffers: ReceiveBuffers.Buffers = undefined,
    backend: Backend = undefined,
    slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined,
    storage: Storage = undefined,
    state: State = .{},
    worker: Worker = undefined,
    sample: worker_runtime.ClockSample = undefined,
    listener_live: bool = false,
    client_live: bool = false,
    backend_live: bool = false,
    storage_ready: bool = false,
    worker_started: bool = false,

    pub fn init(self: *Runtime) !void {
        errdefer self.abort();
        self.listener = switch (listener_runtime.open(.{})) {
            .listener => |value| value,
            .failure => return error.ListenerOpenFailed,
        };
        self.listener_live = true;
        self.client = try connectClient(self.listener.bound_address);
        self.client_live = true;
        try self.backend.init(&self.buffers);
        self.backend_live = true;
        try self.storage.init(&self.slab);
        self.storage_ready = true;
        try self.worker.init(
            &self.state,
            &self.storage,
            &self.backend,
            0,
            self.listener.socket,
            null,
        );
        self.sample = .{
            .monotonic_ns = try monotonicNow(),
            .epoch_second = epoch_second,
        };
        try resolveStep(&self.worker, try self.worker.start(self.sample));
        self.worker_started = true;
    }

    pub fn stop(self: *Runtime) !void {
        if (!self.worker_started) return error.WorkerNotStarted;
        try resolveStep(&self.worker, try self.worker.stop());
        try self.driveUntilStopped();
        if (!self.worker.cleanupStatus().quiescent()) return error.WorkerNotQuiescent;
        self.worker_started = false;
        try self.backend.deinit();
        self.backend_live = false;
    }

    pub fn abort(self: *Runtime) void {
        if (self.backend_live) {
            _ = self.backend.abort() catch {};
            if (self.storage_ready) {
                for (self.storage.connections) |connection| {
                    if (connection.phase == .free or connection.socket_closed) continue;
                    self.backend.discard(connection.socket) catch {};
                }
            }
            self.backend_live = false;
        }
        if (self.client_live) {
            _ = linux.close(self.client);
            self.client_live = false;
        }
        if (self.listener_live) {
            _ = self.listener.close();
            self.listener_live = false;
        }
    }

    pub fn step(self: *Runtime) !void {
        const completion = try waitCompletion(&self.backend);
        try resolveStep(&self.worker, try self.worker.handle(completion, self.sample));
    }

    pub fn driveUntilCompleted(self: *Runtime, expected: u16) !void {
        var completions: u16 = 0;
        while (self.state.completed < expected) : (completions += 1) {
            if (completions == completion_limit) return error.CompletionLimitExceeded;
            try self.step();
        }
        if (self.state.completed != expected) return error.UnexpectedCompletionCount;
    }

    pub fn driveUntilBodyProgress(self: *Runtime, expected: u32) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                if (connection.phase != .receiving_body) continue;
                const request_index = connection.active_request orelse continue;
                const receiver = self.storage.requests[request_index].body.receiver;
                if (receiver.progress() == expected) return;
            }
        }
        return error.BodyProgressNotObserved;
    }

    pub fn driveUntilChunkProgress(
        self: *Runtime,
        expected_wire: u64,
        expected_body: u32,
    ) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                if (connection.phase != .receiving_body) continue;
                const request_index = connection.active_request orelse continue;
                const request = &self.storage.requests[request_index];
                const state = self.storage.chunkedState(request_index) catch continue;
                if (state.wireBytesConsumed() != expected_wire) continue;
                if (request.body.used != expected_body) continue;
                return;
            }
        }
        return error.ChunkProgressNotObserved;
    }

    pub fn driveUntilContinueDelivered(self: *Runtime) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                if (connection.phase != .receiving_body) continue;
                if (connection.continue_cursor != 0) continue;
                if (connection.send_token != null) continue;
                return;
            }
        }
        return error.ContinueNotDelivered;
    }

    pub fn driveUntilStopped(self: *Runtime) !void {
        var completions: u16 = 0;
        while (!self.worker.cleanupStatus().quiescent()) : (completions += 1) {
            if (completions == completion_limit) return error.CompletionLimitExceeded;
            try self.step();
        }
    }

    pub fn driveUntilConnectionClosed(self: *Runtime) !void {
        var completions: u16 = 0;
        while (self.worker.cleanupStatus().live_connections != 0) : (completions += 1) {
            if (completions == completion_limit) return error.CompletionLimitExceeded;
            try self.step();
        }
    }
};

pub fn expectChunkedBadRequest(head: []const u8, wire: []const u8) !void {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, head);
    try sendAll(runtime.client, wire);
    try runtime.driveUntilCompleted(1);
    var received: [bad_request_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(bad_request_response, &received);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.completed);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.aborted);
    try runtime.driveUntilConnectionClosed();
    try runtime.stop();
}

pub fn expectGuardedChild(comptime run: anytype, failure_code: u8) !void {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        run() catch linux.exit_group(failure_code);
        linux.exit_group(0);
    }

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

pub fn runGuardedBodies() !void {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();
    try allocation_guard.denyAddressSpaceGrowth();

    var response_bytes: [body_response.len]u8 = undefined;
    var expected: u16 = 1;
    while (expected <= guarded_request_count) : (expected += 1) {
        try sendAll(runtime.client, echo_head ++ "abcdef");
        try runtime.driveUntilCompleted(expected);
        try receiveExact(runtime.client, &response_bytes);
        if (!std.mem.eql(u8, body_response, &response_bytes)) {
            return error.UnexpectedResponse;
        }
    }
    if (runtime.state.body_calls != guarded_request_count) {
        return error.UnexpectedBodyCalls;
    }
    if (!runtime.state.bodies_valid) return error.UnexpectedBody;
    try runtime.stop();
}

pub fn runGuardedChunkedBodies() !void {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();
    try allocation_guard.denyAddressSpaceGrowth();

    var response_bytes: [body_response.len]u8 = undefined;
    var expected: u16 = 1;
    while (expected <= guarded_request_count) : (expected += 1) {
        try sendAll(runtime.client, chunked_echo_head ++ chunked_echo_body);
        try runtime.driveUntilCompleted(expected);
        try receiveExact(runtime.client, &response_bytes);
        if (!std.mem.eql(u8, body_response, &response_bytes)) {
            return error.UnexpectedResponse;
        }
        if (runtime.storage.bodyWorkspaceAvailable() != 1) {
            return error.BodyWorkspaceNotReleased;
        }
        if (runtime.storage.chunkedWorkspaceAvailable() != 1) {
            return error.ChunkedWorkspaceNotReleased;
        }
    }
    if (runtime.state.body_calls != guarded_request_count) {
        return error.UnexpectedBodyCalls;
    }
    if (runtime.state.trailer_calls != guarded_request_count) {
        return error.UnexpectedTrailerCalls;
    }
    if (!runtime.state.bodies_valid) return error.UnexpectedBody;
    if (!runtime.state.trailers_valid) return error.UnexpectedTrailers;
    try runtime.stop();
}

pub fn runGuardedTypedEndpoint() !void {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();
    try allocation_guard.denyAddressSpaceGrowth();

    var response_bytes: [typed_response.len]u8 = undefined;
    var expected: u16 = 1;
    while (expected <= guarded_request_count) : (expected += 1) {
        try sendAll(runtime.client, typed_request);
        try runtime.driveUntilCompleted(expected);
        try receiveExact(runtime.client, &response_bytes);
        if (!std.mem.eql(u8, typed_response, &response_bytes)) {
            return error.UnexpectedResponse;
        }
        if (runtime.storage.bodyWorkspaceAvailable() != 1) {
            return error.BodyWorkspaceNotReleased;
        }
    }
    if (runtime.state.typed_calls != guarded_request_count or
        !runtime.state.typed_valid)
    {
        return error.UnexpectedTypedEndpointState;
    }
    try runtime.stop();
}

pub fn expectBodyState(
    state: *const State,
    body_calls: u16,
    ping_calls: u16,
    completed: u16,
) !void {
    try std.testing.expectEqual(body_calls, state.body_calls);
    try std.testing.expectEqual(ping_calls, state.ping_calls);
    try std.testing.expectEqual(completed, state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);
    try std.testing.expect(state.bodies_valid);
    try std.testing.expect(state.trailers_valid);
}

pub fn resolveStep(worker: *Worker, first: worker_runtime.Step) !void {
    var step = first;
    var retries: u8 = 0;
    while (step == .flush_retry) : (retries += 1) {
        if (retries == 8) return error.FlushRetryLimitExceeded;
        step = try worker.retryFlush();
    }
}

pub fn waitCompletion(backend: *Backend) !reactor.Completion {
    const deadline = try std.math.add(u64, try monotonicNow(), completion_wait_ns);
    while (true) {
        const completion = backend.poll() catch |problem| switch (problem) {
            error.WaitInterrupted, error.WaitRetry => null,
            else => return problem,
        };
        if (completion) |ready| return ready;
        if (try monotonicNow() >= deadline) return error.CompletionWaitTimedOut;

        const pause = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        const pause_error = linux.errno(linux.nanosleep(&pause, null));
        if (pause_error != .SUCCESS and pause_error != .INTR) {
            return error.CompletionPollSleepFailed;
        }
    }
}

pub fn connectClient(address: listener_runtime.Address) !linux.fd_t {
    const socket_result = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(socket_result) != .SUCCESS) return error.ClientSocketFailed;
    const fd: linux.fd_t = @intCast(socket_result);
    errdefer _ = linux.close(fd);

    const ipv4 = switch (address) {
        .ipv4 => |value| value,
        .ipv6 => return error.UnexpectedAddressFamily,
    };
    const socket_address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, ipv4.port),
        .addr = @bitCast(ipv4.bytes),
    };
    const result = linux.connect(fd, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in));
    if (linux.errno(result) != .SUCCESS) return error.ClientConnectFailed;
    return fd;
}

pub fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    var retries: u16 = 0;
    while (sent < bytes.len) : (retries += 1) {
        if (retries == completion_limit) return error.ClientSendRetryLimitExceeded;
        const result = linux.sendto(
            fd,
            bytes[sent..].ptr,
            bytes.len - sent,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ClientSendFailed;
                sent += result;
            },
            .AGAIN, .INTR => {},
            else => return error.ClientSendFailed,
        }
    }
}

pub fn receiveExact(fd: linux.fd_t, output: []u8) !void {
    var used: usize = 0;
    while (used < output.len) {
        var descriptors = [1]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const polled = linux.poll(&descriptors, descriptors.len, 2_000);
        if (linux.errno(polled) != .SUCCESS or polled != 1 or
            descriptors[0].revents & linux.POLL.IN == 0)
        {
            return error.ClientReceiveTimedOut;
        }
        const result = linux.recvfrom(
            fd,
            output[used..].ptr,
            output.len - used,
            0,
            null,
            null,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ClientClosedWithoutResponse;
                used += result;
            },
            .INTR => {},
            else => return error.ClientReceiveFailed,
        }
    }
}

pub fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0) return error.ClockUnavailable;
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    return std.math.add(u64, seconds, @intCast(value.nsec));
}

test {
    _ = @import("worker_body_io_uring_integration_test_part_1.zig");
}

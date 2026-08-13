const std = @import("std");
const linux = std.os.linux;

const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const route = @import("../../src/route.zig");
const allocation_guard = @import("../../src/internal/runtime/allocation_guard.zig");
const buffer_ring = @import("../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../src/internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("../../src/internal/runtime/listener.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const worker_runtime = @import("../../src/internal/runtime/worker.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const request =
    "GET /stream HTTP/1.1\r\n" ++
    "Host: stream.test\r\n" ++
    "TE: trailers\r\n\r\n";
const body_bytes: usize = 256 * 1024;
const chunk_prefix = "40000\r\n";
const terminal = "\r\n0\r\nx-checksum: done\r\n\r\n";
const response_head =
    "HTTP/1.1 200 OK\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-type: application/octet-stream\r\n" ++
    "transfer-encoding: chunked\r\n" ++
    "trailer: x-checksum\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n";
const wire_bytes = response_head.len + chunk_prefix.len + body_bytes + terminal.len;
const epoch_second: i64 = 1_784_030_400;
const socket_buffer_bytes: i32 = 1024;
const completion_limit: u16 = 1024;
const test_timeout_ns: u64 = 5 * std.time.ns_per_s;
const trailer_names = [_][]const u8{"x-checksum"};
const trailer_fields = [_]response_stream.TrailerField{
    .{ .name = "x-checksum", .value = "done" },
};

const ProducerControl = struct {
    step: u8 = 0,
    polls: u8 = 0,
    joins: u8 = 0,
    aborts: u8 = 0,
    wake: ?response_stream.Wake = null,
};

const State = struct {
    producer: ProducerControl = .{},
    completed: u8 = 0,
    last_transport: application.TransportOutcome = .aborted,
};

const Context = application.Context(State, response.standard_head_limits);
const StreamResponse = Context.StreamResponse(Producer);

const Producer = struct {
    control: *ProducerControl,

    pub fn poll(
        self: *Producer,
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.control.polls += 1;
        const step = self.control.step;
        self.control.step += 1;
        return switch (step) {
            0 => firstChunk(output),
            1 => self.pending(wake),
            else => .{ .done = &trailer_fields },
        };
    }

    pub fn abort(self: *Producer) void {
        self.control.aborts += 1;
    }

    pub fn join(self: *Producer) void {
        self.control.joins += 1;
    }

    fn pending(self: *Producer, wake: response_stream.Wake) response_stream.PollResult {
        self.control.wake = wake;
        return .pending;
    }
};

fn firstChunk(output: []u8) response_stream.PollError!response_stream.PollResult {
    if (output.len < body_bytes) return error.ProducerFailed;
    @memset(output[0..body_bytes], 'x');
    return .{ .progress = body_bytes };
}

const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.completed += 1;
        context.state.last_transport = outcome.transport;
    }
};

fn stream(context: *Context) StreamResponse {
    return context.streamUnknown(
        .ok,
        response.media.octet_stream,
        Producer{ .control = &context.state.producer },
        &trailer_names,
    );
}

const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .routes = .{route.get("/stream", stream)},
});

const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = body_bytes + 1024,
    .submission_entries = 32,
    .completion_entries = 64,
    .timeouts = .{
        .first_head_ns = test_timeout_ns,
        .write_stall_ns = test_timeout_ns,
    },
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 512, 53);
const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
const Storage = worker_storage.Storage(App, limits);
const Worker = worker_runtime.Worker(App, Storage, Backend);

test "real io_uring stream preserves partial chunk wake trailers and stop" {
    try runStream(false);
}

test "ready io_uring stream stays allocation free" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        runStream(true) catch |problem| {
            std.debug.print("guarded stream failed: {s}\n", .{@errorName(problem)});
            linux.exit_group(141);
        };
        linux.exit_group(0);
    }

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

fn runStream(guarded: bool) !void {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);

    var storage: Storage = undefined;
    var storage_ready = false;
    const slab = try std.posix.mmap(
        null,
        Storage.required_bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(slab);
    try storage.init(slab);
    storage_ready = true;

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };

    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));
    if (guarded) try allocation_guard.denyAddressSpaceGrowth();
    try sendAll(client, request);

    try driveUntilPartialBody(&worker, &backend, sample, &storage, &state);
    if (state.completed != 0) return error.CompletedBeforeWake;
    try drainResponse(&worker, &backend, sample, client, &state);

    if (state.producer.polls != 3 or state.producer.joins != 1 or
        state.producer.aborts != 0 or state.last_transport != .completed)
    {
        return error.UnexpectedProducerLifecycle;
    }

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    if (!worker.cleanupStatus().quiescent()) return error.WorkerNotQuiescent;
    try backend.deinit();
    backend_live = false;
}

fn driveUntilPartialBody(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    storage: *const Storage,
    state: *const State,
) !void {
    var accepted_configured = false;
    for (0..completion_limit) |_| {
        const completion = try waitCompletion(backend);
        const fields = try completion.token.fields();
        if (acceptedSocket(completion)) |socket| {
            if (accepted_configured) return error.MultipleAcceptedSockets;
            try setSocketBuffer(socket, linux.SO.SNDBUF);
            accepted_configured = true;
        }
        try resolveStep(worker, try worker.handle(completion, sample));
        if (fields.kind != .send or state.producer.polls == 0) continue;
        const progress = activeResponseProgress(storage) orelse continue;
        if (progress.sent > 0 and progress.sent < progress.used) return;
    }
    return error.PartialSendNotObserved;
}

const ResponseProgress = struct { sent: u32, used: u32 };

fn activeResponseProgress(storage: *const Storage) ?ResponseProgress {
    for (storage.connections) |connection| {
        const request_index = connection.active_request orelse continue;
        const active = &storage.requests[request_index];
        return .{ .sent = active.response_sent, .used = active.response_used };
    }
    return null;
}

fn drainResponse(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    client: linux.fd_t,
    state: *State,
) !void {
    const deadline = try std.math.add(u64, try monotonicNow(), test_timeout_ns);
    var received: usize = 0;
    var notified = false;
    while (received < wire_bytes or state.completed == 0) {
        var progressed = try drainAvailable(client, &received);
        if (!notified) if (state.producer.wake) |wake| {
            wake.notify();
            notified = true;
            progressed = true;
        };
        var handled: u8 = 0;
        while (handled < 16) : (handled += 1) {
            const completion = backend.poll() catch |problem| switch (problem) {
                error.WaitInterrupted, error.WaitRetry => break,
                else => return problem,
            } orelse break;
            if (acceptedSocket(completion) != null) return error.UnexpectedAcceptedSocket;
            try resolveStep(worker, try worker.handle(completion, sample));
            progressed = true;
        }
        if (received == wire_bytes and state.completed == 1) return;
        if (received > wire_bytes or state.completed > 1) return error.ResponseOverrun;
        if (try monotonicNow() >= deadline) return error.ResponseDrainTimedOut;
        if (!progressed) try pause();
    }
}

fn drainAvailable(client: linux.fd_t, received: *usize) !bool {
    var progressed = false;
    var output: [8192]u8 = undefined;
    while (received.* < wire_bytes) {
        const remaining = wire_bytes - received.*;
        const result = linux.recvfrom(
            client,
            &output,
            @min(output.len, remaining),
            linux.MSG.DONTWAIT,
            null,
            null,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ClientClosedWithoutResponse;
                try verifyWire(received.*, output[0..result]);
                received.* += result;
                progressed = true;
            },
            .AGAIN => return progressed,
            .INTR => {},
            else => return error.ClientReceiveFailed,
        }
    }
    return progressed;
}

fn verifyWire(offset: usize, bytes: []const u8) !void {
    for (bytes, 0..) |byte, index| {
        const position = offset + index;
        const expected = expectedWireByte(position) orelse return error.ResponseOverrun;
        if (byte != expected) return error.ResponseBytesMismatch;
    }
}

fn expectedWireByte(position: usize) ?u8 {
    if (position < response_head.len) return response_head[position];
    const after_head = position - response_head.len;
    if (after_head < chunk_prefix.len) return chunk_prefix[after_head];
    const after_prefix = after_head - chunk_prefix.len;
    if (after_prefix < body_bytes) return 'x';
    const after_body = after_prefix - body_bytes;
    if (after_body < terminal.len) return terminal[after_body];
    return null;
}

fn acceptedSocket(completion: reactor.Completion) ?reactor.Socket {
    return switch (completion.result) {
        .success => |success| switch (success) {
            .accept => |accepted| accepted.socket,
            else => null,
        },
        .failure => null,
    };
}

fn setSocketBuffer(socket: reactor.Socket, option: u32) !void {
    if (socket.value > std.math.maxInt(linux.fd_t)) return error.InvalidSocket;
    try setRawSocketBuffer(@intCast(socket.value), option);
}

fn setRawSocketBuffer(fd: linux.fd_t, option: u32) !void {
    const result = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        option,
        @ptrCast(&socket_buffer_bytes),
        @sizeOf(i32),
    );
    if (linux.errno(result) != .SUCCESS) return error.SetSocketBufferFailed;
}

fn driveUntilStopped(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
) !void {
    for (0..completion_limit) |_| {
        if (worker.cleanupStatus().quiescent()) return;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
    return error.CompletionLimitExceeded;
}

fn resolveStep(worker: *Worker, first: worker_runtime.Step) !void {
    var step = first;
    var retries: u8 = 0;
    while (step == .flush_retry) : (retries += 1) {
        if (retries == 8) return error.FlushRetryLimitExceeded;
        step = try worker.retryFlush();
    }
}

fn waitCompletion(backend: *Backend) !reactor.Completion {
    const deadline = try std.math.add(u64, try monotonicNow(), test_timeout_ns);
    while (true) {
        const completion = backend.poll() catch |problem| switch (problem) {
            error.WaitInterrupted, error.WaitRetry => null,
            else => return problem,
        };
        if (completion) |ready| return ready;
        if (try monotonicNow() >= deadline) return error.CompletionWaitTimedOut;
        try pause();
    }
}

fn abortTestBackend(backend: *Backend, storage: ?*const Storage) void {
    _ = backend.abort() catch {};
    const initialized = storage orelse return;
    for (initialized.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed or
            connection.close_token != null) continue;
        backend.discard(connection.socket) catch {};
    }
}

fn expectProgress(step: worker_runtime.Step) !void {
    if (step != .progressed) return error.UnexpectedWorkerStep;
}

fn connectClient(address: listener_runtime.Address) !linux.fd_t {
    const socket_result = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(socket_result) != .SUCCESS) return error.ClientSocketFailed;
    const fd: linux.fd_t = @intCast(socket_result);
    errdefer _ = linux.close(fd);
    try setRawSocketBuffer(fd, linux.SO.RCVBUF);

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

fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
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
            .INTR => {},
            else => return error.ClientSendFailed,
        }
    }
}

fn pause() !void {
    const duration = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    const pause_error = linux.errno(linux.nanosleep(&duration, null));
    if (pause_error != .SUCCESS and pause_error != .INTR) {
        return error.CompletionPollSleepFailed;
    }
}

fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0) return error.ClockUnavailable;
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    return std.math.add(u64, seconds, @intCast(value.nsec));
}

test {
    std.testing.refAllDecls(@This());
}

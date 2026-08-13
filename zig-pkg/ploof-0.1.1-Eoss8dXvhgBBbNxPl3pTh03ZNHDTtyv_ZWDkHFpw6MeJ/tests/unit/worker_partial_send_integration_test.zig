const std = @import("std");
const linux = std.os.linux;

const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const buffer_ring = @import("../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../src/internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("../../src/internal/runtime/listener.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const worker_runtime = @import("../../src/internal/runtime/worker.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const request = "GET /large HTTP/1.1\r\nHost: partial-send.test\r\n\r\n";
const body_bytes: usize = 512 * 1024;
const body = [_]u8{'x'} ** body_bytes;
const response_head =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: application/octet-stream\r\n" ++
    "content-length: 524288\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n";
const wire_bytes = response_head.len + body.len;
const epoch_second: i64 = 1_784_030_400;
const socket_buffer_bytes: i32 = 1024;
const completion_limit: u16 = 512;
const test_timeout_ns: u64 = 5 * std.time.ns_per_s;

const State = struct {
    calls: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
};

const Context = application.Context(State, response.standard_head_limits);

const Observe = struct {
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

fn large(context: *Context) Context.ResponseType {
    context.state.calls += 1;
    return context.bytesStatic(.ok, &body);
}

const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .routes = .{route.get("/large", large)},
});

const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = body_bytes + 512,
    .submission_entries = 16,
    .completion_entries = 32,
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 512, 47);
const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
const Storage = worker_storage.Storage(App, limits);
const Worker = worker_runtime.Worker(App, Storage, Backend);

test "real io_uring retries a partial send without duplicating response bytes" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    try sendAll(client, request);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    var storage: Storage = undefined;
    var storage_ready = false;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };

    const slab_mapping = try std.posix.mmap(
        null,
        Storage.required_bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(slab_mapping);
    try storage.init(slab_mapping);
    storage_ready = true;

    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));

    try driveUntilFirstPartialSend(&worker, &backend, sample, &storage);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try std.testing.expectEqual(@as(u16, 0), state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    try drainResponse(&worker, &backend, sample, client, &state);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try std.testing.expectEqual(@as(u16, 1), state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

fn driveUntilFirstPartialSend(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    storage: *const Storage,
) !void {
    var completions: u16 = 0;
    var accepted_configured = false;
    while (completions < completion_limit) : (completions += 1) {
        const completion = try waitCompletion(backend);
        const fields = try completion.token.fields();
        if (acceptedSocket(completion)) |socket| {
            if (accepted_configured) return error.MultipleAcceptedSockets;
            try setSocketBuffer(socket, linux.SO.SNDBUF);
            accepted_configured = true;
        }
        try resolveStep(worker, try worker.handle(completion, sample));
        if (fields.kind != .send) continue;
        if (!accepted_configured) return error.AcceptedSocketNotConfigured;

        const progress = activeResponseProgress(storage) orelse {
            return error.FullFirstSend;
        };
        if (progress.sent == 0 or progress.sent >= progress.used) {
            return error.FullFirstSend;
        }
        return;
    }
    return error.CompletionLimitExceeded;
}

const ResponseProgress = struct {
    sent: u32,
    used: u32,
};

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
    state: *const State,
) !void {
    const deadline = try std.math.add(u64, try monotonicNow(), test_timeout_ns);
    var received: usize = 0;
    while (received < wire_bytes or state.completed == 0) {
        var progressed = try drainAvailable(client, &received);
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
        const expected = if (position < response_head.len)
            response_head[position]
        else
            'x';
        if (byte != expected) return error.ResponseBytesMismatch;
    }
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
    const result = linux.setsockopt(
        @intCast(socket.value),
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
    var completions: u16 = 0;
    while (!worker.cleanupStatus().quiescent()) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
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

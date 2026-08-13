pub const std = @import("std");
pub const linux = std.os.linux;

pub const application = @import("../../../../src/application.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
pub const memory_budget = @import("../../../../src/internal/runtime/memory_budget.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const ping_request = "GET /ping HTTP/1.1\r\nHost: integration.test\r\n\r\n";
pub const epoch_second: i64 = 1_784_030_400;
pub const completion_limit: u16 = 128;
pub const completion_wait_ns: u64 = 2 * std.time.ns_per_s;
pub const poll_pause_ns: i64 = std.time.ns_per_ms;
pub const burst_client_count: usize = 8;
pub const buffer_reuse_request_count: u16 = ReceiveBuffers.count * 2 + 1;
pub const ping_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "pong";
pub const request_timeout_response =
    "HTTP/1.1 408 Request Timeout\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";

pub const State = struct {
    calls: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
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

pub fn ping(context: *Context) Context.ResponseType {
    context.state.calls += 1;
    return context.textStatic(.ok, "pong");
}

pub const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .routes = .{route.get("/ping", ping)},
});

pub const limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 1,
    .receive_buffers = 4,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 32,
    .completion_entries = 64,
    .timeouts = .{ .first_head_ns = 250 * std.time.ns_per_ms },
});

pub const ReceiveBuffers = buffer_ring.BufferRing(
    limits.receive_buffers,
    limits.receive_buffer_bytes,
    37,
);
pub const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
pub const Storage = worker_storage.Storage(App, limits);
pub const Worker = worker_runtime.Worker(App, Storage, Backend);

pub const StandardReceiveBuffers = buffer_ring.BufferRing(
    config.standard_limits.receive_buffers,
    config.standard_limits.receive_buffer_bytes,
    38,
);
pub const StandardBackend = io_uring_backend.IoUringBackend(
    config.standard_limits,
    StandardReceiveBuffers,
);
pub const StandardStorage = worker_storage.Storage(App, config.standard_limits);
pub const StandardWorker = worker_runtime.Worker(App, StandardStorage, StandardBackend);

pub fn mappingVmBytes(bytes: usize) u64 {
    return std.mem.alignForward(u64, @intCast(bytes), memory_budget.vm_page_bytes);
}

pub fn driveUntilCompleted(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    state: *const State,
    expected: u16,
) !void {
    var completions: u16 = 0;
    while (state.completed < expected) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        const completion = try waitCompletion(backend);
        try resolveStep(worker, try worker.handle(completion, sample));
    }
    if (state.completed != expected) return error.UnexpectedCompletionCount;
}

pub fn driveUntilPartialHead(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    storage: *const Storage,
    state: *const State,
    expected_phase: worker_storage.ConnectionPhase,
    expected_calls: u16,
    fragment: []const u8,
) !void {
    var completions: u16 = 0;
    while (completions < completion_limit) : (completions += 1) {
        const completion = try waitCompletion(backend);
        try resolveStep(worker, try worker.handle(completion, sample));
        for (storage.connections) |connection| {
            if (connection.phase == .free) continue;
            if (connection.phase != expected_phase) continue;
            const observed = connection.head_decoder.bytes();
            if (observed.len == 0) continue;
            if (!std.mem.eql(u8, observed, fragment) or state.calls != expected_calls) {
                return error.PartialHeadNotObserved;
            }
            return;
        }
    }
    return error.CompletionLimitExceeded;
}

pub fn driveUntilResponseQueued(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    storage: *const Storage,
    state: *const State,
) !void {
    var completions: u16 = 0;
    while (completions < completion_limit) : (completions += 1) {
        const completion = try waitCompletion(backend);
        try resolveStep(worker, try worker.handle(completion, sample));
        for (storage.connections) |connection| {
            if (connection.phase == .responding and connection.send_token != null) {
                if (state.calls != 0) return error.UnexpectedApplicationCall;
                return;
            }
        }
    }
    return error.CompletionLimitExceeded;
}

pub fn driveUntilConnectionsClosed(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
) !void {
    var completions: u16 = 0;
    while (worker.cleanupStatus().live_connections != 0) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        const completion = try waitCompletion(backend);
        try resolveStep(worker, try worker.handle(completion, sample));
    }
}

pub fn driveUntilCapacityPaused(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    descriptor_limit: u16,
) !void {
    var completions: u16 = 0;
    try expectOpenDescriptorLimit(descriptor_limit);
    try expectAcceptedDescriptorsBounded(worker);
    while (worker.controller.phase != .paused) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        const completion = try waitCompletion(backend);
        try expectOpenDescriptorLimit(descriptor_limit);
        try resolveStep(worker, try worker.handle(completion, sample));
        try expectOpenDescriptorLimit(descriptor_limit);
        try expectAcceptedDescriptorsBounded(worker);
    }
}

pub fn expectOpenDescriptorLimit(limit: u16) !void {
    if (try openFileDescriptorCount() > limit) return error.DescriptorCapacityExceeded;
}

pub fn openFileDescriptorCount() !u16 {
    const opened = linux.open(
        "/proc/self/fd",
        .{ .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    if (linux.errno(opened) != .SUCCESS) return error.FdDirectoryOpenFailed;
    const directory: linux.fd_t = @intCast(opened);
    defer _ = linux.close(directory);

    var entries: [4096]u8 align(@alignOf(u64)) = undefined;
    var count: u16 = 0;
    while (true) {
        const read_result = linux.getdents64(directory, &entries, entries.len);
        if (linux.errno(read_result) != .SUCCESS) return error.FdDirectoryReadFailed;
        if (read_result == 0) return count;

        var offset: usize = 0;
        while (offset < read_result) {
            if (read_result - offset < 19) return error.InvalidFdDirectoryEntry;
            const length = std.mem.readInt(u16, entries[offset + 16 ..][0..2], .little);
            if (length < 19 or length > read_result - offset) {
                return error.InvalidFdDirectoryEntry;
            }
            count = std.math.add(u16, count, 1) catch return error.TooManyFileDescriptors;
            offset += length;
        }
    }
}

pub fn expectAcceptedDescriptorsBounded(worker: *const Worker) !void {
    var live: u16 = 0;
    for (worker.storage.connections) |connection| {
        if (connection.phase == .free) continue;
        live += 1;
        const fd: linux.fd_t = @intCast(connection.socket.value);
        if (linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) != .SUCCESS) {
            return error.AcceptedDescriptorInvalid;
        }
    }
    if (live > limits.connection_slots or
        worker.metricsSnapshot().connections_high_water > limits.connection_slots)
    {
        return error.ConnectionCapacityExceeded;
    }
}

pub fn driveUntilStopped(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
) !void {
    var completions: u16 = 0;
    while (!worker.cleanupStatus().quiescent()) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        const completion = try waitCompletion(backend);
        try resolveStep(worker, try worker.handle(completion, sample));
    }
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

        const pause = linux.timespec{ .sec = 0, .nsec = poll_pause_ns };
        const pause_error = linux.errno(linux.nanosleep(&pause, null));
        if (pause_error != .SUCCESS and pause_error != .INTR) {
            return error.CompletionPollSleepFailed;
        }
    }
}

pub fn abortTestBackend(backend: *Backend, storage: ?*const Storage) void {
    _ = backend.abort() catch {};
    const initialized = storage orelse return;
    for (initialized.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed or
            connection.close_token != null) continue;
        backend.discard(connection.socket) catch {};
    }
}

pub fn expectProgress(step: worker_runtime.Step) !void {
    if (step != .progressed) return error.UnexpectedWorkerStep;
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
    const connect_error = linux.errno(result);
    if (connect_error != .SUCCESS) return error.ClientConnectFailed;
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
        const polled = linux.poll(&descriptors, descriptors.len, 1_000);
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
    _ = @import("worker_io_uring_integration_test_part_1.zig");
}

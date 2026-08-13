const std = @import("std");
const linux = std.os.linux;

const application = @import("../../../../src/application.zig");
const asset_fixture = @import("../../asset_test.zig");
const response = @import("../../../../src/response.zig");
const route = @import("../../../../src/route.zig");
const static_file = @import("../../../../src/static_file.zig");
const allocation_guard = @import("../../../../src/internal/runtime/allocation_guard.zig");
const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

const ping_request =
    "GET /ping HTTP/1.1\r\n" ++
    "Host: allocation.test\r\n" ++
    "Accept-Encoding: gzip\r\n" ++
    "\r\n";
const ping_head_request =
    "HEAD /ping HTTP/1.1\r\n" ++
    "Host: allocation.test\r\n" ++
    "Accept-Encoding: gzip\r\n" ++
    "\r\n";
const asset_get_request =
    "GET " ++ asset_fixture.Generated.assets[0].path ++ " HTTP/1.1\r\n" ++
    "Host: allocation.test\r\n\r\n";
const asset_head_request =
    "HEAD " ++ asset_fixture.Generated.assets[0].path ++ " HTTP/1.1\r\n" ++
    "Host: allocation.test\r\n\r\n";
const live_get_request =
    "GET /live HTTP/1.1\r\nHost: allocation.test\r\n\r\n";
const live_head_request =
    "HEAD /live HTTP/1.1\r\nHost: allocation.test\r\n\r\n";
const live_bytes = @embedFile("../../../../src/application.zig");
const response_bytes_max: usize = live_bytes.len + 4096;
const epoch_second: i64 = 1_784_030_400;
const completion_limit: u16 = 128;
const completion_wait_ns: u64 = 2 * std.time.ns_per_s;
const ping_count: u16 = 5;

const State = struct {
    calls: u16 = 0,
    completed: u16 = 0,
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
            else => {},
        }
    }
};

fn ping(context: *Context) Context.ResponseType {
    context.state.calls += 1;
    return context.textStatic(.ok, "pong");
}

const App = application.Application(.{
    .State = State,
    .assets = asset_fixture.Assets,
    .middleware = .{Observe{}},
    .live_static_slots_per_worker = 1,
    .live_static_read_bytes = 4096,
    .routes = .{
        route.get("/ping", ping),
        static_file.StaticFile.configured(
            "/live",
            ".",
            "src/application.zig",
            .{},
            .{},
            null,
        ),
    },
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
});

const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = 32 * 1024,
    .submission_entries = 32,
    .completion_entries = 64,
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 512, 43);
const Backend = io_uring_backend.IoUringBackendWithFiles(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 1,
        .live_static_roots = 1,
    },
);
const Storage = worker_storage.Storage(App, limits);
const Worker = worker_runtime.Worker(App, Storage, Backend);

test "ready io_uring worker serves dynamic and static responses without growth" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        runGuardedResponses() catch |problem| {
            std.debug.print("guarded response failed: {s}\n", .{@errorName(problem)});
            linux.exit_group(121);
        };
        linux.exit_group(0);
    }

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

fn runGuardedResponses() !void {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    if (try worker.start(sample) != .progressed) return error.UnexpectedWorkerStep;

    try allocation_guard.denyAddressSpaceGrowth();
    var received: [response_bytes_max]u8 = undefined;
    var expected: u16 = 1;
    while (expected <= ping_count) : (expected += 1) {
        const head_only = expected & 1 == 0;
        try sendAll(client, if (head_only) ping_head_request else ping_request);
        try driveUntilCompleted(&worker, &backend, sample, &state, expected);
        const response_bytes = try receiveResponse(client, &received, head_only);
        try validateGzipResponse(response_bytes, head_only);
        for (std.mem.asBytes(&storage.response_gzip_workspace)) |byte| {
            if (byte != 0) return error.ResponseGzipWorkspaceNotCleared;
        }
        if (state.calls != expected or state.completed != expected) {
            return error.UnexpectedApplicationState;
        }
    }

    for ([_]bool{ false, true }) |head_only| {
        try sendAll(client, if (head_only) asset_head_request else asset_get_request);
        try driveUntilReadable(&worker, &backend, sample, client);
        try driveUntilRequestIdle(&worker, &backend, sample);
        const response_bytes = try receiveResponse(client, &received, head_only);
        try validateStaticResponse(
            response_bytes,
            asset_fixture.Generated.assets[0].identity.bytes,
            head_only,
        );
        if (state.calls != ping_count or state.completed != ping_count) {
            return error.UnexpectedApplicationState;
        }
    }

    var live_completed: u16 = ping_count;
    for ([_]bool{ false, true }) |head_only| {
        try sendAll(client, if (head_only) live_head_request else live_get_request);
        try driveUntilReadable(&worker, &backend, sample, client);
        try driveUntilRequestIdle(&worker, &backend, sample);
        const response_bytes = try receiveResponse(client, &received, head_only);
        try validateStaticResponse(response_bytes, live_bytes, head_only);
        live_completed += 1;
        if (state.calls != ping_count or state.completed != live_completed) {
            return error.UnexpectedApplicationState;
        }
    }

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    if (!worker.cleanupStatus().quiescent()) return error.WorkerNotQuiescent;
    try backend.deinit();
    backend_live = false;
}

fn driveUntilReadable(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    client: linux.fd_t,
) !void {
    var completions: u16 = 0;
    while (!try readable(client)) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
}

fn driveUntilRequestIdle(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
) !void {
    var completions: u16 = 0;
    while (true) : (completions += 1) {
        const status = worker.cleanupStatus();
        if (status.live_requests == 0 and status.live_static_requests == 0) return;
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
}

fn readable(fd: linux.fd_t) !bool {
    var descriptors = [1]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    const polled = linux.poll(&descriptors, descriptors.len, 0);
    if (linux.errno(polled) != .SUCCESS) return error.ClientPollFailed;
    return polled == 1 and descriptors[0].revents & linux.POLL.IN != 0;
}

fn driveUntilCompleted(
    worker: *Worker,
    backend: *Backend,
    sample: worker_runtime.ClockSample,
    state: *const State,
    expected: u16,
) !void {
    var completions: u16 = 0;
    while (state.completed < expected) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
    if (state.completed != expected) return error.UnexpectedApplicationState;
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

fn connectClient(address: listener_runtime.Address) !linux.fd_t {
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

fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
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

fn receiveResponse(fd: linux.fd_t, output: []u8, head_only: bool) ![]const u8 {
    var used: usize = 0;
    var expected: ?usize = null;
    while (expected == null or used < expected.?) {
        if (used == output.len) return error.ResponseTooLarge;
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
        if (expected == null) expected = try responseLength(output[0..used], head_only);
        if (expected) |length| {
            if (length > output.len) return error.ResponseTooLarge;
            if (used > length) return error.ResponseLengthMismatch;
        }
    }
    return output[0..expected.?];
}

fn responseLength(bytes: []const u8, head_only: bool) !?usize {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    const head_end = marker + 4;
    if (head_only) return head_end;
    const body_length = try contentLength(bytes[0..head_end]);
    return std.math.add(usize, head_end, body_length) catch error.ResponseTooLarge;
}

fn contentLength(head: []const u8) !usize {
    const prefix = "content-length: ";
    const start = std.mem.indexOf(u8, head, prefix) orelse {
        return error.MissingContentLength;
    };
    const value_start = start + prefix.len;
    const value_end_offset = std.mem.indexOf(u8, head[value_start..], "\r\n") orelse {
        return error.InvalidContentLength;
    };
    const value_end = value_start + value_end_offset;
    return std.fmt.parseUnsigned(usize, head[value_start..value_end], 10) catch {
        return error.InvalidContentLength;
    };
}

fn validateGzipResponse(bytes: []const u8, head_only: bool) !void {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.MissingResponseHead;
    };
    const head_end = marker + 4;
    const head = bytes[0..head_end];
    if (!std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n")) {
        return error.UnexpectedResponseStatus;
    }
    if (std.mem.indexOf(u8, head, "content-encoding: gzip\r\n") == null or
        std.mem.indexOf(u8, head, "vary: Accept-Encoding\r\n") == null)
    {
        return error.MissingGzipResponseFields;
    }
    const encoded_length = try contentLength(head);
    if (encoded_length < 18) return error.InvalidGzipContentLength;
    if (head_only) {
        if (bytes.len != head_end) return error.UnexpectedHeadBody;
        return;
    }
    if (bytes.len != head_end + encoded_length) return error.ResponseLengthMismatch;

    var reader = std.Io.Reader.fixed(bytes[head_end..]);
    var decoder = std.compress.flate.Decompress.init(&reader, .gzip, &.{});
    var decoded: [4]u8 = undefined;
    var writer = std.Io.Writer.fixed(&decoded);
    const written = try decoder.reader.streamRemaining(&writer);
    if (written != decoded.len or !std.mem.eql(u8, &decoded, "pong")) {
        return error.GzipRoundTripMismatch;
    }
}

fn validateStaticResponse(
    bytes: []const u8,
    expected_body: []const u8,
    head_only: bool,
) !void {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.MissingResponseHead;
    };
    const head_end = marker + 4;
    const head = bytes[0..head_end];
    if (!std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n")) {
        return error.UnexpectedResponseStatus;
    }
    if (try contentLength(head) != expected_body.len) {
        return error.InvalidContentLength;
    }
    if (head_only) {
        if (bytes.len != head_end) return error.UnexpectedHeadBody;
        return;
    }
    if (!std.mem.eql(u8, bytes[head_end..], expected_body)) {
        return error.StaticBodyMismatch;
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

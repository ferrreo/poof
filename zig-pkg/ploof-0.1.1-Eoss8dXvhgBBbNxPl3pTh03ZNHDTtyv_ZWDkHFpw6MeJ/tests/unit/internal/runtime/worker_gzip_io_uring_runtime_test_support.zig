const source = @import("worker_gzip_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const json = source.json;
const multipart = source.multipart;
const query = source.query;
const response = source.response;
const route = source.route;
const allocation_guard = source.allocation_guard;
const buffer_ring = source.buffer_ring;
const config = source.config;
const gzip_encoder = source.gzip_encoder;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const guarded_request_count = source.guarded_request_count;
const typed_json_body = source.typed_json_body;
const typed_gzip_bytes_max = source.typed_gzip_bytes_max;
const large_body_bytes = source.large_body_bytes;
const large_gzip_bytes_max = source.large_gzip_bytes_max;
const multipart_boundary = source.multipart_boundary;
const multipart_count_part = source.multipart_count_part;
const multipart_upload_head = source.multipart_upload_head;
const multipart_close = source.multipart_close;
const multipart_body = source.multipart_body;
const multipart_large_body = source.multipart_large_body;
const multipart_gzip_bytes_max = source.multipart_gzip_bytes_max;
const continue_response = source.continue_response;
const gzip_abcdef = source.gzip_abcdef;
const gzip_twelve = source.gzip_twelve;
const gzip_head = source.gzip_head;
const expect_gzip_head = source.expect_gzip_head;
const chunked_gzip_head = source.chunked_gzip_head;
const chunked_gzip_wire = source.chunked_gzip_wire;
const ping_request = source.ping_request;
const multipart_head = source.multipart_head;
const body_response = source.body_response;
const ping_response = source.ping_response;
const typed_response = source.typed_response;
const multipart_response = source.multipart_response;
const bad_request_response = source.bad_request_response;
const too_large_response = source.too_large_response;
const unavailable_response = source.unavailable_response;
const LargeFixture = source.LargeFixture;
const rejectionResponse = source.rejectionResponse;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const echo = source.echo;
const ping = source.ping;
const largeEcho = source.largeEcho;
const TypedQuery = source.TypedQuery;
const TypedPayload = source.TypedPayload;
const TypedEndpoint = source.TypedEndpoint;
const typed = source.typed;
const MultipartBody = source.MultipartBody;
const MultipartEndpoint = source.MultipartEndpoint;
const MultipartSpec = source.MultipartSpec;
const MultipartConsumer = source.MultipartConsumer;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const ActiveGzip = source.ActiveGzip;

pub const Runtime = struct {
    listener: listener_runtime.Listener = undefined,
    clients: [2]linux.fd_t = .{ -1, -1 },
    buffers: ReceiveBuffers.Buffers = undefined,
    backend: Backend = undefined,
    slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined,
    storage: Storage = undefined,
    state: State = .{},
    worker: Worker = undefined,
    sample: worker_runtime.ClockSample = undefined,
    client_count: u8 = 0,
    listener_live: bool = false,
    backend_live: bool = false,
    storage_ready: bool = false,
    worker_started: bool = false,

    pub fn init(self: *Runtime, client_count: u8) !void {
        if (client_count == 0 or client_count > self.clients.len) {
            return error.InvalidClientCount;
        }
        errdefer self.abort();
        self.listener = switch (listener_runtime.open(.{})) {
            .listener => |value| value,
            .failure => return error.ListenerOpenFailed,
        };
        self.listener_live = true;
        while (self.client_count < client_count) : (self.client_count += 1) {
            self.clients[self.client_count] = try connectClient(self.listener.bound_address);
        }
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
        if (self.worker_started and self.backend_live) {
            const stopped = self.worker.stop() catch null;
            if (stopped) |stop_step| {
                resolveStep(&self.worker, stop_step) catch {};
                self.driveUntilStopped() catch {};
            }
            self.worker_started = false;
        }
        if (self.backend_live) {
            _ = self.backend.abort() catch {};
            if (self.storage_ready) discardLiveSockets(&self.backend, &self.storage);
            self.backend_live = false;
        }
        for (&self.clients) |*client| {
            if (client.* < 0) continue;
            _ = linux.close(client.*);
            client.* = -1;
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

    pub fn driveUntilIdentityProgress(self: *Runtime, expected: u32) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                if (connection.phase != .receiving_body) continue;
                const request_index = connection.active_request orelse continue;
                const request = self.storage.requests[request_index];
                if (request.gzip_lease != null or !request.body.multipart) continue;
                if (request.body.receiver.progress() == expected) return;
            }
        }
        return error.MultipartIdentityProgressNotObserved;
    }

    pub fn driveUntilClosed(self: *Runtime, expected: u64) !void {
        var completions: u16 = 0;
        while (self.worker.metricsSnapshot().connections_closed < expected) : (completions += 1) {
            if (completions == completion_limit) return error.CompletionLimitExceeded;
            try self.step();
        }
    }

    pub fn driveUntilFixedProgress(self: *Runtime, expected: u32) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                const request_index = connection.active_request orelse continue;
                const request = self.storage.requests[request_index];
                if (request.gzip_lease == null or request.chunked_workspace_index != null) continue;
                if (request.body.receiver.progress() == expected) return;
            }
        }
        return error.GzipFixedProgressNotObserved;
    }

    pub fn driveUntilChunkProgress(self: *Runtime, expected: u64) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                const request_index = connection.active_request orelse continue;
                const request = self.storage.requests[request_index];
                if (request.gzip_lease == null or request.chunked_workspace_index == null) continue;
                const state = self.storage.chunkedState(request_index) catch continue;
                if (state.wireBytesConsumed() == expected) return;
            }
        }
        return error.GzipChunkProgressNotObserved;
    }

    pub fn driveUntilContinueDelivered(self: *Runtime) !void {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            try self.step();
            for (self.storage.connections) |connection| {
                if (connection.phase != .receiving_body) continue;
                if (connection.continue_cursor == 0 and connection.send_token == null) return;
            }
        }
        return error.ContinueNotDelivered;
    }

    pub fn driveUntilGzipPaused(self: *Runtime) !ActiveGzip {
        var completions: u16 = 0;
        while (completions < completion_limit) : (completions += 1) {
            if (activeGzip(self)) |active| {
                if (self.storage.connections[active.connection_index]
                    .receive_flags.gzip_paused) return active;
            }
            try self.step();
        }
        return error.GzipQueuePauseNotObserved;
    }

    pub fn driveUntilStopped(self: *Runtime) !void {
        var completions: u16 = 0;
        while (!self.worker.cleanupStatus().quiescent()) : (completions += 1) {
            if (completions == completion_limit) return error.CompletionLimitExceeded;
            try self.step();
        }
    }
};

pub fn expectClosedRejection(wire: []const u8, expected: []const u8) !void {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();
    try sendAll(runtime.clients[0], wire);
    try runtime.driveUntilClosed(1);
    var received: [unavailable_response.len]u8 = undefined;
    if (expected.len > received.len) return error.InvalidExpectedResponse;
    try receiveExact(runtime.clients[0], received[0..expected.len]);
    try std.testing.expectEqualStrings(expected, received[0..expected.len]);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
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

pub fn runGuardedGzip() !void {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();
    try allocation_guard.denyAddressSpaceGrowth();

    var received: [body_response.len]u8 = undefined;
    var expected: u16 = 1;
    while (expected <= guarded_request_count) : (expected += 1) {
        try sendAll(runtime.clients[0], gzip_head ++ gzip_abcdef);
        try runtime.driveUntilCompleted(expected);
        try receiveExact(runtime.clients[0], &received);
        if (!std.mem.eql(u8, body_response, &received)) return error.UnexpectedResponse;
        if (runtime.storage.bodyWorkspaceAvailable() != limits.body_workspace_slots) {
            return error.BodyWorkspaceNotReleased;
        }
        if (runtime.storage.gzipPool().?.available() != limits.gzip.decoder_slots) {
            return error.GzipDecoderNotReleased;
        }
    }
    if (runtime.state.body_calls != guarded_request_count) {
        return error.UnexpectedBodyCalls;
    }
    if (!runtime.state.bodies_valid) return error.UnexpectedBody;
    try runtime.stop();
}

pub fn expectState(state: *const State, body_calls: u16, ping_calls: u16, completed: u16) !void {
    try std.testing.expectEqual(body_calls, state.body_calls);
    try std.testing.expectEqual(ping_calls, state.ping_calls);
    try std.testing.expectEqual(completed, state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);
    try std.testing.expect(state.bodies_valid);
    try std.testing.expect(state.trailers_valid);
}

pub fn expectMultipartResult(runtime: *Runtime) !void {
    try std.testing.expectEqual(@as(u16, 1), runtime.state.multipart_calls);
    try std.testing.expectEqual(@as(u16, 23), runtime.state.multipart_count);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.completed);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.aborted);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.typed_calls);
    try std.testing.expectEqual(@as(u16, 0), runtime.storage.gzipPool().?.activeJobs());
    try std.testing.expectEqual(
        limits.gzip.decoder_slots,
        runtime.storage.gzipPool().?.available(),
    );
    try std.testing.expectEqual(
        limits.body_workspace_slots,
        runtime.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        limits.chunked_workspace_slots,
        runtime.storage.chunkedWorkspaceAvailable(),
    );
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(@as(u16, 0), runtime.backend.borrowedCount());
}

pub fn activeGzip(runtime: *Runtime) ?ActiveGzip {
    for (runtime.storage.connections, 0..) |connection, index| {
        const request_index = connection.active_request orelse continue;
        if (runtime.storage.requests[request_index].gzip_lease == null) continue;
        return .{
            .connection_index = @intCast(index),
            .request_index = request_index,
        };
    }
    return null;
}

pub fn waitDecodePaused() !void {
    const deadline = try std.math.add(u64, try monotonicNow(), completion_wait_ns);
    while (!Storage.GzipDecoderPool.TestAccess.decodePaused()) {
        if (try monotonicNow() >= deadline) return error.DecodePauseNotObserved;
        std.Thread.yield() catch {};
    }
}

pub fn waitForSpaceNotification(queue: anytype) !void {
    const deadline = try std.math.add(u64, try monotonicNow(), completion_wait_ns);
    while (!queue.spaceNotificationPending()) {
        if (try monotonicNow() >= deadline) return error.SpaceNotificationNotObserved;
        std.Thread.yield() catch {};
    }
}

pub fn expectReadable(descriptor: linux.fd_t) !void {
    var descriptors = [1]linux.pollfd{.{
        .fd = descriptor,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const count = linux.poll(&descriptors, descriptors.len, 2_000);
        switch (linux.errno(count)) {
            .SUCCESS => {
                if (count != 1 or descriptors[0].revents & linux.POLL.IN == 0) {
                    return error.WakeDescriptorNotReadable;
                }
                return;
            },
            .INTR => continue,
            else => return error.WakePollFailed,
        }
    }
}

pub fn discardLiveSockets(backend: *Backend, storage: *const Storage) void {
    for (storage.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed) continue;
        backend.discard(connection.socket) catch {};
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
        if (linux.errno(polled) != .SUCCESS or polled != 1) {
            return error.ClientReceiveTimedOut;
        }
        if (descriptors[0].revents & linux.POLL.IN == 0) {
            return error.ClientClosedWithoutResponse;
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

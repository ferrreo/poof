const source = @import("worker_file_sink_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const endpoint = source.endpoint;
const multipart = source.multipart;
const response = source.response;
const route = source.route;
const buffer_ring = source.buffer_ring;
const config = source.config;
const connection_body_transport = source.connection_body_transport;
const connection_driver = source.connection_driver;
const gzip_encoder = source.gzip_encoder;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const upload_metrics = source.upload_metrics;
const request_head = source.request_head;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const boundary = source.boundary;
const first_bytes = source.first_bytes;
const second_bytes = source.second_bytes;
const first_part = source.first_part;
const second_part = source.second_part;
const valid_body = source.valid_body;
const failed_body = source.failed_body;
const rejected_body = source.rejected_body;
const missing_required_body = source.missing_required_body;
const invalid_after_first_body = source.invalid_after_first_body;
const success_response = source.success_response;
const failure_response = source.failure_response;
const bad_request_response = source.bad_request_response;
const too_large_response = source.too_large_response;
const unsupported_response = source.unsupported_response;
const forbidden_status = source.forbidden_status;
const Sink = source.Sink;
const Body = source.Body;
const Definition = source.Definition;
const Spec = source.Spec;
const AppState = source.AppState;
const Context = source.Context;
const Consumer = source.Consumer;
const Observe = source.Observe;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const BodyTransport = source.BodyTransport;
const deadline_limits = source.deadline_limits;
const DeadlineBackend = source.DeadlineBackend;
const DeadlineStorage = source.DeadlineStorage;
const DeadlineWorker = source.DeadlineWorker;
const HalfSubmitBackend = source.HalfSubmitBackend;
const HalfSubmitWorker = source.HalfSubmitWorker;
const ActiveGzipUpload = source.ActiveGzipUpload;

pub const Runtime = struct {
    listener: listener_runtime.Listener = undefined,
    client: linux.fd_t = -1,
    buffers: ReceiveBuffers.Buffers = undefined,
    backend: Backend = undefined,
    slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined,
    storage: Storage = undefined,
    state: AppState = .{},
    worker: Worker = undefined,
    sample: worker_runtime.ClockSample = undefined,
    listener_live: bool = false,
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
        try std.testing.expectEqual([_]u8{0} ** 32, self.worker.upload_entropy);
        self.worker_started = true;
    }

    pub fn stop(self: *Runtime) !void {
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
        self.closeClient();
        if (self.listener_live) {
            _ = self.listener.close();
            self.listener_live = false;
        }
    }

    pub fn step(self: *Runtime) !void {
        const completion = try waitCompletion(&self.backend);
        self.sample.monotonic_ns = try monotonicNow();
        try resolveStep(&self.worker, try self.worker.handle(completion, self.sample));
    }

    pub fn driveUntilDecision(self: *Runtime, expected: u16) !void {
        for (0..completion_limit) |_| {
            if (self.state.decisions == expected) return;
            try self.step();
        }
        return error.DecisionNotObserved;
    }

    pub fn driveUntilReady(self: *Runtime) !void {
        for (0..completion_limit) |_| {
            if (try clientReady(self.client)) return;
            try self.step();
        }
        return error.ResponseNotObserved;
    }

    pub fn driveUntilAfter(self: *Runtime, expected: u16) !void {
        for (0..completion_limit) |_| {
            if (self.state.after_calls == expected) return;
            try self.step();
        }
        return error.AfterNotObserved;
    }

    pub fn driveUntilClosed(self: *Runtime, expected: u64) !void {
        for (0..completion_limit) |_| {
            if (self.worker.metricsSnapshot().connections_closed >= expected) return;
            try self.step();
        }
        return error.CloseNotObserved;
    }

    pub fn driveUntilActiveGzipUpload(self: *Runtime) !ActiveGzipUpload {
        for (0..completion_limit) |_| {
            for (self.storage.connections, 0..) |connection, connection_index| {
                if (connection.phase != .receiving_body or
                    !connection.receive_flags.upload_paused or
                    !connection.receive_flags.paused)
                {
                    continue;
                }
                const request_index = connection.active_request orelse continue;
                const request = self.storage.requests[request_index];
                if (request.gzip_lease == null or self.worker.driver.uploadPending() == 0) {
                    continue;
                }
                return .{
                    .connection_index = @intCast(connection_index),
                    .request_index = request_index,
                };
            }
            try self.step();
        }
        return error.ActiveGzipUploadNotObserved;
    }

    pub fn driveUntilPublished(self: *Runtime, directory: std.Io.Dir) !void {
        for (0..completion_limit) |_| {
            if (try fileExists(directory, "uploads/first.bin") and
                try fileExists(directory, "uploads/second.bin") and
                self.report().live_anonymous == 0) return;
            try self.step();
        }
        return error.PublicationNotObserved;
    }

    pub fn driveUntilStopped(self: *Runtime) !void {
        for (0..completion_limit) |_| {
            if (self.worker.cleanupStatus().quiescent()) return;
            try self.step();
        }
        return error.CompletionLimitExceeded;
    }

    pub fn reconnect(self: *Runtime) !void {
        self.closeClient();
        self.client = try connectClient(self.listener.bound_address);
    }

    pub fn closeClient(self: *Runtime) void {
        if (self.client < 0) return;
        _ = linux.close(self.client);
        self.client = -1;
    }

    pub fn resetClient(self: *Runtime) !void {
        const linger = linux.linger{ .onoff = 1, .linger = 0 };
        const result = linux.setsockopt(
            self.client,
            linux.SOL.SOCKET,
            linux.SO.LINGER,
            @ptrCast(&linger),
            @sizeOf(linux.linger),
        );
        if (linux.errno(result) != .SUCCESS) return error.SetLingerFailed;
        self.closeClient();
    }

    pub fn report(self: *Runtime) multipart.FileSinkReport {
        return Sink.report(self.storage.upload_registry.get(Sink).?);
    }
};

pub const Encoding = enum { identity, gzip };

pub const CloseOrder = enum { gzip_terminal_first, upload_cqes_first };

pub const DrainGoal = enum { response_ready, connection_released };

pub fn exerciseActiveGzipResponse(order: CloseOrder) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    const active = try forceActiveParserRejection(&runtime, .bad_request);
    try drainOrdered(&runtime, active, order, .response_ready);
    var received: [bad_request_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(bad_request_response, &received);
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);

    try std.testing.expectEqual(
        limits.connection_slots,
        runtime.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        limits.body_workspace_slots,
        runtime.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        limits.gzip.decoder_slots,
        runtime.storage.gzipPool().?.available(),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try expectParserRejectionMetrics(&runtime.worker);
    try runtime.stop();
}

pub fn exerciseActiveGzipClose(order: CloseOrder) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    const active = try forceActiveParserRejection(&runtime, .bad_request);
    try std.testing.expect(try runtime.worker.driver.stop(active.connection_index) == .retained);
    try flushBackend(&runtime.backend);
    try drainOrdered(&runtime, active, order, .connection_released);
    try expectClientClosedWithoutResponse(runtime.client);
    runtime.closeClient();

    try std.testing.expectEqual(
        limits.connection_slots,
        runtime.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        limits.body_workspace_slots,
        runtime.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        limits.gzip.decoder_slots,
        runtime.storage.gzipPool().?.available(),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    const metrics = runtime.worker.uploadMetricsSnapshot();
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.primary_failures[@intFromEnum(upload_metrics.PrimaryFailureClass.body)],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_metrics.FinalizationOutcome.failed)],
    );
    for (metrics.cleanup_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.completed);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.aborted);
    try runtime.stop();
}

pub fn forceActiveParserRejection(
    runtime: *Runtime,
    status: request_head.Status,
) !ActiveGzipUpload {
    try sendMultipart(runtime.client, invalid_after_first_body, .gzip);
    const active = try runtime.driveUntilActiveGzipUpload();
    try std.testing.expect(try runtime.worker.driver.uploads.beginRequestAbort(
        &runtime.storage,
        &runtime.backend,
        active.request_index,
        .body,
    ) == .none);
    runtime.storage.requests[active.request_index].flags.upload_parser_paused = false;
    try BodyTransport.rejectParser(
        &runtime.worker.driver,
        active.connection_index,
        status,
        runtime.sample.monotonic_ns,
    );
    try std.testing.expect(runtime.storage.requests[active.request_index]
        .flags.upload_rejection_pending);
    try flushBackend(&runtime.backend);
    return active;
}

pub fn drainOrdered(
    runtime: *Runtime,
    active: ActiveGzipUpload,
    order: CloseOrder,
    goal: DrainGoal,
) !void {
    var deferred: [limits.completion_entries]reactor.Completion = undefined;
    var deferred_count: u16 = 0;
    var deferred_cursor: u16 = 0;
    var deferred_wake: ?reactor.Completion = null;
    var terminal_delivered = false;
    for (0..completion_limit) |_| {
        switch (goal) {
            .connection_released => {
                if (runtime.storage.connections[active.connection_index].phase == .free) return;
            },
            .response_ready => if (try clientReady(runtime.client)) {
                const upload_settled = runtime.worker.driver.uploadPending() == 0 and
                    runtime.storage.requests[active.request_index].gzip_lease == null and
                    deferred_cursor == deferred_count and deferred_wake == null;
                if (!upload_settled) return error.ResponseBeforeUploadSettled;
                return;
            },
        }
        if (order == .upload_cqes_first and !terminal_delivered and
            runtime.worker.driver.uploadPending() == 0 and deferred_wake != null)
        {
            try deliverCompletion(runtime, deferred_wake.?);
            deferred_wake = null;
            terminal_delivered = runtime.storage.requests[active.request_index]
                .gzip_lease == null;
            continue;
        }
        if (order == .gzip_terminal_first and terminal_delivered and
            deferred_cursor < deferred_count)
        {
            try deliverCompletion(runtime, deferred[deferred_cursor]);
            deferred_cursor += 1;
            continue;
        }
        const completion = try waitCompletion(&runtime.backend);
        const kind = (try completion.token.fields()).kind;
        if (@intFromEnum(kind) > @intFromEnum(reactor.OperationKind.wake) and
            order == .gzip_terminal_first and !terminal_delivered)
        {
            if (deferred_count == deferred.len) return error.DeferredCompletionOverflow;
            deferred[deferred_count] = completion;
            deferred_count += 1;
            continue;
        }
        if (kind == .wake and order == .upload_cqes_first and
            !terminal_delivered and runtime.worker.driver.uploadPending() != 0)
        {
            if (deferred_wake != null) return error.DuplicateDeferredWake;
            deferred_wake = completion;
            continue;
        }
        try deliverCompletion(runtime, completion);
        if (kind == .wake) {
            terminal_delivered = runtime.storage.requests[active.request_index]
                .gzip_lease == null;
        }
    }
    return error.CompletionLimitExceeded;
}

pub fn deliverCompletion(runtime: *Runtime, completion: reactor.Completion) !void {
    try resolveStep(&runtime.worker, try runtime.worker.handle(completion, runtime.sample));
}

pub fn flushBackend(backend: *Backend) !void {
    for (0..8) |_| {
        _ = backend.flush() catch |problem| switch (problem) {
            error.SubmissionRetry => continue,
            else => return problem,
        };
        return;
    }
    return error.FlushRetryLimitExceeded;
}

pub fn expectClientClosedWithoutResponse(fd: linux.fd_t) !void {
    var descriptors = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const polled = linux.poll(&descriptors, descriptors.len, 2_000);
    if (linux.errno(polled) != .SUCCESS or polled != 1) return error.ClientCloseTimedOut;
    var byte: [1]u8 = undefined;
    const result = linux.recvfrom(fd, &byte, byte.len, 0, null, null);
    switch (linux.errno(result)) {
        .SUCCESS => if (result != 0) return error.UnexpectedResponse,
        .CONNRESET => {},
        else => return error.ClientReceiveFailed,
    }
}

pub fn expectParserRejectionMetrics(worker: *const Worker) !void {
    try std.testing.expectEqual(@as(u64, 0), worker.metricsSnapshot().fatal_transitions);
    const metrics = worker.uploadMetricsSnapshot();
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_metrics.FinalizationOutcome.failed)],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.primary_failures[@intFromEnum(upload_metrics.PrimaryFailureClass.body)],
    );
}

pub fn exercisePublication(encoding: Encoding) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, valid_body, encoding);
    try runtime.driveUntilDecision(1);
    try std.testing.expect(!try clientReady(runtime.client));
    try expectFileAbsent(temporary.dir, "uploads/second.bin");
    const pending = runtime.report();
    try std.testing.expectEqual(@as(u32, 2), pending.live_anonymous);
    try std.testing.expectEqual(@as(u32, 0), pending.live_named);

    try runtime.driveUntilReady();
    try expectStoredFiles(temporary.dir);
    var received: [success_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(success_response, &received);
    try runtime.driveUntilAfter(1);
    try std.testing.expect(runtime.state.order_valid);
    try std.testing.expect(runtime.state.summaries_valid);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.completed);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.aborted);
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try runtime.stop();
}

pub fn sendMultipart(fd: linux.fd_t, bytes: []const u8, encoding: Encoding) !void {
    var encoded_storage: [1_024]u8 = undefined;
    var workspace: gzip_encoder.Workspace = undefined;
    const body_bytes = switch (encoding) {
        .identity => bytes,
        .gzip => try gzip_encoder.compress(
            &workspace,
            bytes,
            &encoded_storage,
            .fastest,
        ),
    };
    var head_storage: [384]u8 = undefined;
    const encoding_head = if (encoding == .gzip) "Content-Encoding: gzip\r\n" else "";
    const head = try std.fmt.bufPrint(
        &head_storage,
        "POST /upload HTTP/1.1\r\nHost: files.test\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\n{s}" ++
            "Content-Length: {d}\r\n\r\n",
        .{ boundary, encoding_head, body_bytes.len },
    );
    try sendAll(fd, head);
    const split = body_bytes.len / 2;
    try sendAll(fd, body_bytes[0..split]);
    try sendAll(fd, body_bytes[split..]);
}

pub fn expectStoredFiles(directory: std.Io.Dir) !void {
    try expectFile(directory, "uploads/first.bin", first_bytes);
    try expectFile(directory, "uploads/second.bin", second_bytes);
}

pub fn expectFile(directory: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    var storage: [64]u8 = undefined;
    const contents = try directory.readFile(std.testing.io, path, &storage);
    try std.testing.expectEqualStrings(expected, contents);
}

pub fn expectFileAbsent(directory: std.Io.Dir, path: []const u8) !void {
    if (try fileExists(directory, path)) return error.ExpectedFileAbsent;
}

pub fn fileExists(directory: std.Io.Dir, path: []const u8) !bool {
    var file = directory.openFile(std.testing.io, path, .{}) catch |problem| switch (problem) {
        error.FileNotFound => return false,
        else => return problem,
    };
    file.close(std.testing.io);
    return true;
}

pub fn discardLiveSockets(backend: *Backend, storage: *const Storage) void {
    for (storage.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed) continue;
        backend.discard(connection.socket) catch {};
    }
}

pub fn resolveStep(worker: anytype, first: worker_runtime.Step) !void {
    var step = first;
    var retries: u8 = 0;
    while (step == .flush_retry) : (retries += 1) {
        if (retries == 8) return error.FlushRetryLimitExceeded;
        step = try worker.retryFlush();
    }
}

pub fn waitCompletion(backend: anytype) !reactor.Completion {
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

pub fn clientReady(fd: linux.fd_t) !bool {
    var descriptors = [1]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    const count = linux.poll(&descriptors, descriptors.len, 0);
    if (linux.errno(count) != .SUCCESS) return error.ClientPollFailed;
    return count == 1 and descriptors[0].revents != 0;
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

pub fn enterTemporary(directory: linux.fd_t) !linux.fd_t {
    const opened = linux.open(".", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.SaveCurrentDirectoryFailed;
    const original: linux.fd_t = @intCast(opened);
    if (linux.errno(linux.fchdir(directory)) != .SUCCESS) {
        _ = linux.close(original);
        return error.EnterTemporaryDirectoryFailed;
    }
    return original;
}

pub fn restoreCwd(original: linux.fd_t) void {
    if (linux.errno(linux.fchdir(original)) != .SUCCESS) {
        @panic("failed to restore test working directory");
    }
    if (linux.errno(linux.close(original)) != .SUCCESS) {
        @panic("failed to close saved working directory");
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

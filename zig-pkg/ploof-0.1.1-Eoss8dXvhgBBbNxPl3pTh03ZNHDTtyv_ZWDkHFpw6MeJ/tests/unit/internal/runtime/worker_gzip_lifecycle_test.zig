const std = @import("std");
const builtin = @import("builtin");

const application = @import("../../../../src/application.zig");
const body = @import("../../../../src/body.zig");
const response = @import("../../../../src/response.zig");
const route = @import("../../../../src/route.zig");
const accept_controller = @import("../../../../src/internal/runtime/accept_controller.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const gzip_decoder_pool = @import("../../../../src/internal/runtime/gzip/decoder_pool.zig");
const gzip_request_jobs = @import("../../../../src/internal/runtime/gzip/request_jobs.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const worker = @import("../../../../src/internal/runtime/worker.zig");
const worker_gzip_lifecycle = @import("../../../../src/internal/runtime/worker/gzip_lifecycle.zig");
const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

const TestPool = gzip_decoder_pool.FixedPool(1, 512, 128, 2);
const test_thread_stack_bytes = if (builtin.sanitize_thread)
    8 * 1024 * 1024
else
    256 * 1024;
const EnabledStorage = struct {
    pub const gzip_decoder_thread_count = 1;
    pub const GzipDecoderPool = TestPool;
    pub const runtime_limits = .{
        .gzip = .{ .thread_stack_bytes = test_thread_stack_bytes },
    };

    gzip_decoders: TestPool = undefined,
    gzip_slots: [1]TestPool.Slot = undefined,

    fn init(self: *EnabledStorage) void {
        self.gzip_decoders.init(&self.gzip_slots);
    }

    pub fn gzipPool(self: *EnabledStorage) ?*TestPool {
        return &self.gzip_decoders;
    }
};

const DisabledStorage = struct {
    pub const gzip_decoder_thread_count = 0;
};

const TestIo = deterministic_reactor.DeterministicReactor(8);
const Lifecycle = worker_gzip_lifecycle.Lifecycle(EnabledStorage);

const BodyState = struct {
    handled: u16 = 0,
    aborted: u16 = 0,
};
const BodyContext = application.Context(BodyState, response.standard_head_limits);
const ObserveAbort = struct {
    pub const State = void;

    pub fn init(_: ObserveAbort) void {}

    pub fn after(
        _: ObserveAbort,
        context: *const BodyContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        if (outcome.transport == .aborted) context.state.aborted += 1;
    }
};

fn upload(context: *BodyContext, _: body.Bytes) BodyContext.ResponseType {
    context.state.handled += 1;
    return context.empty(.ok);
}

const BodyApp = application.Application(.{
    .State = BodyState,
    .middleware = .{ObserveAbort{}},
    .routes = .{route.post("/upload", body.bytes(.{
        .encoded_wire_bytes_max = 64,
        .decoded_bytes_max = 64,
    }, upload))},
});

const body_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 16,
    .completion_entries = 32,
    .gzip = .{
        .decoder_slots = 1,
        .input_chunks_per_slot = 2,
        .members_max = 2,
        .thread_stack_bytes = test_thread_stack_bytes,
    },
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});
const BodyStorage = worker_storage.Storage(BodyApp, body_limits);
const BodyIo = deterministic_reactor.DeterministicReactor(64);
const BodyWorker = worker.Worker(BodyApp, BodyStorage, BodyIo);
const gzip_request_head =
    "POST /upload HTTP/1.1\r\n" ++
    "Host: lifecycle.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 32\r\n\r\n";

const BodyHarness = struct {
    slab: [BodyStorage.required_bytes]u8 align(BodyStorage.slab_alignment) = undefined,
    storage: BodyStorage = undefined,
    io: BodyIo = .{},
    state: BodyState = .{},
    runtime: BodyWorker = undefined,
    sample: worker.ClockSample = .{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 },

    fn init(self: *BodyHarness) !void {
        self.io = .{};
        self.state = .{};
        self.sample = .{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 };
        try self.storage.init(&self.slab);
        try self.runtime.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .value = 4 },
            null,
        );
        try std.testing.expectEqual(worker.Step.progressed, try self.runtime.start(self.sample));
    }

    fn findToken(self: *const BodyHarness, kind: reactor.OperationKind) ?reactor.OperationToken {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if ((submission.token.fields() catch unreachable).kind == kind) {
                return submission.token;
            }
        }
        return null;
    }

    fn complete(
        self: *BodyHarness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
        more: bool,
    ) !void {
        try self.io.complete(token, result, more);
        _ = try self.runtime.handle(self.io.nextCompletion().?, self.sample);
    }

    fn beginGzipRequest(self: *BodyHarness) !struct { connection: u16, request: u16 } {
        const accept = self.findToken(.accept) orelse return error.TestUnexpectedResult;
        try self.complete(
            accept,
            .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 10 }) } },
            false,
        );
        const connection: u16 = 0;
        const receive = self.storage.connections[connection].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        try self.complete(receive, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try receive.slot(),
                .buffer_index = 0,
                .buffer_generation = 1,
            },
            .bytes = gzip_request_head,
        } } } }, false);
        const request = self.storage.connections[connection].active_request orelse {
            return error.TestUnexpectedResult;
        };
        if (self.storage.requests[request].gzip_lease == null) {
            const acquired = try gzip_request_jobs.acquire(
                &self.storage,
                connection,
                request,
                .{ .encoded_max = 32, .decoded_max = 64 },
            );
            if (acquired != .acquired) return error.TestUnexpectedResult;
        }
        return .{ .connection = connection, .request = request };
    }

    fn completeConnectionCleanupBeforeWake(self: *BodyHarness) !void {
        var count: u16 = 0;
        while (count < 64) : (count += 1) {
            if (self.findToken(.cancel)) |token| {
                try self.complete(
                    token,
                    .{ .success = .{ .cancel = .canceled } },
                    false,
                );
                continue;
            }
            if (self.findToken(.receive)) |token| {
                try self.complete(token, .{ .failure = .canceled }, false);
                continue;
            }
            if (self.findToken(.send)) |token| {
                try self.complete(token, .{ .failure = .canceled }, false);
                continue;
            }
            if (self.findToken(.timeout)) |token| {
                try self.complete(token, .{ .failure = .canceled }, false);
                continue;
            }
            if (self.findToken(.close)) |token| {
                try self.complete(token, .{ .success = .{ .close = {} } }, false);
                continue;
            }
            return;
        }
        return error.TestUnexpectedResult;
    }
};

fn settleBodyJob(
    storage: *BodyStorage,
    slot_index: u16,
    signals: worker_gzip_lifecycle.Signals,
) error{SettlementFailed}!void {
    if (!signals.terminal) return error.SettlementFailed;
    const event = gzip_request_jobs.consumeSlot(storage, slot_index, signals) catch {
        return error.SettlementFailed;
    };
    if (event != .terminal) return error.SettlementFailed;
}

const SignalLog = struct {
    count: u16 = 0,
    slot_index: u16 = 0,
    signals: worker_gzip_lifecycle.Signals = .{},

    fn record(
        self: *SignalLog,
        slot_index: u16,
        signals: worker_gzip_lifecycle.Signals,
    ) error{}!void {
        self.count += 1;
        self.slot_index = slot_index;
        self.signals = signals;
    }
};

const FatalJobLog = struct {
    pool: *TestPool,
    count: u16 = 0,

    fn settle(
        self: *FatalJobLog,
        slot_index: u16,
        signals: worker_gzip_lifecycle.Signals,
    ) error{SettlementFailed}!void {
        if (!signals.terminal) return error.SettlementFailed;
        const lease = self.pool.leaseAt(slot_index) orelse return error.SettlementFailed;
        const result = self.pool.result(lease) catch return error.SettlementFailed;
        if (result == null or result.? != .canceled) return error.SettlementFailed;
        self.pool.ack(lease) catch return error.SettlementFailed;
        self.count += 1;
    }
};

fn findToken(io: *const TestIo, kind: reactor.OperationKind) ?reactor.OperationToken {
    var index: u16 = 0;
    while (index < io.activeCount()) : (index += 1) {
        const submission = io.activeSubmission(index).?;
        const fields = submission.token.fields() catch unreachable;
        if (fields.kind == kind) return submission.token;
    }
    return null;
}

fn handle(
    lifecycle: *Lifecycle,
    storage: *EnabledStorage,
    io: *TestIo,
    token: reactor.OperationToken,
    result: reactor.CompletionResult,
    log: *SignalLog,
) !void {
    try io.complete(token, result, false);
    try lifecycle.handle(storage, io, io.nextCompletion().?, log, SignalLog.record);
}

fn runCanceledStop(cancel_first: bool) !void {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(0);
    try lifecycle.start(&storage, &io);
    const poll = findToken(&io, .wake).?;
    try lifecycle.beginStop(&storage, &io);
    const cancel = findToken(&io, .cancel).?;
    var log = SignalLog{};

    if (cancel_first) {
        try handle(
            &lifecycle,
            &storage,
            &io,
            cancel,
            .{ .success = .{ .cancel = .canceled } },
            &log,
        );
        try handle(&lifecycle, &storage, &io, poll, .{ .failure = .canceled }, &log);
    } else {
        try handle(&lifecycle, &storage, &io, poll, .{ .failure = .canceled }, &log);
        try handle(
            &lifecycle,
            &storage,
            &io,
            cancel,
            .{ .success = .{ .cancel = .canceled } },
            &log,
        );
    }

    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

fn runReadyStop(cancel_first: bool) !void {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(0);
    try lifecycle.start(&storage, &io);
    const poll = findToken(&io, .wake).?;
    try lifecycle.beginStop(&storage, &io);
    const cancel = findToken(&io, .cancel).?;
    var log = SignalLog{};

    if (cancel_first) {
        try handle(
            &lifecycle,
            &storage,
            &io,
            cancel,
            .{ .success = .{ .cancel = .not_found } },
            &log,
        );
        try handle(
            &lifecycle,
            &storage,
            &io,
            poll,
            .{ .success = .{ .wake = {} } },
            &log,
        );
    } else {
        try handle(
            &lifecycle,
            &storage,
            &io,
            poll,
            .{ .success = .{ .wake = {} } },
            &log,
        );
        try handle(
            &lifecycle,
            &storage,
            &io,
            cancel,
            .{ .success = .{ .cancel = .not_found } },
            &log,
        );
    }

    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

test "bodyless gzip lifecycle erases all worker-local state" {
    const DisabledLifecycle = worker_gzip_lifecycle.Lifecycle(DisabledStorage);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledLifecycle));

    var storage = DisabledStorage{};
    var io = TestIo{};
    var lifecycle = try DisabledLifecycle.init(0);
    try lifecycle.start(&storage, &io);
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
    try std.testing.expectEqual(
        worker_gzip_lifecycle.Phase.disabled,
        lifecycle.status(&storage).phase,
    );
}

test "gzip lifecycle rolls back threads and eventfd when initial arm fails" {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    io.injectSubmitFailure();
    var lifecycle = try Lifecycle.init(0);

    try std.testing.expectError(
        error.WakeControlFailed,
        lifecycle.start(&storage, &io),
    );
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

test "gzip lifecycle consumes every ready signal before one-shot rearm" {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(3);
    try lifecycle.start(&storage, &io);
    const first = findToken(&io, .wake).?;
    try std.testing.expectEqual(reactor.wake_control_slot, (try first.fields()).slot_index);

    TestPool.TestAccess.publishSpace(&storage.gzip_decoders, 0);
    var log = SignalLog{};
    try handle(
        &lifecycle,
        &storage,
        &io,
        first,
        .{ .success = .{ .wake = {} } },
        &log,
    );
    const second = findToken(&io, .wake).?;
    try std.testing.expect(!first.eql(second));
    try std.testing.expectEqual(@as(u16, 1), log.count);
    try std.testing.expectEqual(@as(u16, 0), log.slot_index);
    try std.testing.expect(log.signals.space);

    try lifecycle.beginStop(&storage, &io);
    const cancel = findToken(&io, .cancel).?;
    try handle(
        &lifecycle,
        &storage,
        &io,
        cancel,
        .{ .success = .{ .cancel = .canceled } },
        &log,
    );
    try handle(&lifecycle, &storage, &io, second, .{ .failure = .canceled }, &log);
    try std.testing.expect(lifecycle.isStopped());
}

test "gzip lifecycle settles canceled stop in both completion orders" {
    try runCanceledStop(true);
    try runCanceledStop(false);
}

test "gzip lifecycle drains ready stop in both completion orders" {
    try runReadyStop(true);
    try runReadyStop(false);
}

test "gzip lifecycle fatal cleanup waits for backend ownership proof" {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(0);
    try lifecycle.start(&storage, &io);
    lifecycle.beginFatal(&storage);
    io.injectUnprovenAbort();
    const abort_status = try io.abort();
    try std.testing.expect(!abort_status.ownership_proven);

    const pending = lifecycle.status(&storage);
    try std.testing.expectEqual(worker_gzip_lifecycle.Phase.stopping, pending.phase);
    try std.testing.expectEqual(@as(u8, 1), pending.operations);
    try std.testing.expectEqual(
        TestPool.Lifecycle.quiesced,
        storage.gzip_decoders.lifecycleStatus(),
    );

    var log = SignalLog{};
    try std.testing.expect(lifecycle.finishFatalAfterBackend(
        &storage,
        &log,
        SignalLog.record,
    ));
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
}

test "gzip lifecycle fatal cleanup retires wake only after proven abort" {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(0);
    try lifecycle.start(&storage, &io);
    lifecycle.beginFatal(&storage);
    const abort_status = try io.abort();
    try std.testing.expect(abort_status.ownership_proven);

    var log = SignalLog{};
    try std.testing.expect(lifecycle.finishFatalAfterBackend(
        &storage,
        &log,
        SignalLog.record,
    ));
    const status = lifecycle.status(&storage);
    try std.testing.expectEqual(worker_gzip_lifecycle.Phase.stopped, status.phase);
    try std.testing.expectEqual(@as(u8, 0), status.operations);
    try std.testing.expectEqual(@as(u16, 0), status.active_jobs);
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
}

test "gzip lifecycle proven fatal settles preserved job after an earlier signal drain" {
    var storage: EnabledStorage = undefined;
    storage.init();
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(0);
    try lifecycle.start(&storage, &io);

    var output = [_]u8{0xa5} ** 32;
    const lease = storage.gzip_decoders.acquire(
        .{ .connection_index = 0, .request_index = 0, .generation = 1 },
        &output,
        .{ .encoded_max = 32, .decoded_max = 32 },
    ).?;
    try std.testing.expectEqual(@as(u16, 1), storage.gzip_decoders.activeJobs());
    lifecycle.beginFatal(&storage);
    try std.testing.expectEqual(
        TestPool.Lifecycle.quiesced,
        storage.gzip_decoders.lifecycleStatus(),
    );
    try std.testing.expectEqual(@as(u16, 1), storage.gzip_decoders.activeJobs());

    const abort_status = try io.abort();
    try std.testing.expect(abort_status.ownership_proven);
    const drained = storage.gzip_decoders.consumeWake();
    switch (drained) {
        .consumed => |batch| try std.testing.expect(batch.slots[lease.index].terminal),
        .failed => return error.TestUnexpectedResult,
    }

    var log = FatalJobLog{ .pool = &storage.gzip_decoders };
    try std.testing.expect(lifecycle.finishFatalAfterBackend(
        &storage,
        &log,
        FatalJobLog.settle,
    ));
    try std.testing.expectEqual(@as(u16, 1), log.count);
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(@as(u16, 0), storage.gzip_decoders.activeJobs());
    try std.testing.expectEqual(
        TestPool.Lifecycle.stopped,
        storage.gzip_decoders.lifecycleStatus(),
    );
}

test "body worker arms gzip wake before accept and settles active job on proven fatal" {
    var harness: BodyHarness = undefined;
    try harness.init();
    try std.testing.expectEqual(
        reactor.OperationKind.wake,
        (try harness.io.activeSubmission(0).?.token.fields()).kind,
    );
    try std.testing.expectEqual(
        reactor.OperationKind.accept,
        (try harness.io.activeSubmission(1).?.token.fields()).kind,
    );

    _ = try harness.beginGzipRequest();
    try std.testing.expectEqual(@as(u16, 1), harness.storage.gzip_decoders.activeJobs());
    try std.testing.expectEqual(error.BackendFailure, harness.runtime.failBackend());

    const status = harness.runtime.cleanupStatus();
    try std.testing.expectEqual(worker.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(worker_gzip_lifecycle.Phase.stopped, status.gzip_phase);
    try std.testing.expectEqual(@as(u16, 0), status.gzip_active_jobs);
    try std.testing.expectEqual(@as(u16, 1), status.workspace_abort_attempts);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
}

test "body worker unproven fatal retains app storage and gzip ownership" {
    var harness: BodyHarness = undefined;
    try harness.init();
    const indices = try harness.beginGzipRequest();
    const response_buffer = harness.storage.responseWritable(indices.request);
    @memset(response_buffer[0..16], 0x5a);
    const head = harness.storage.connections[indices.connection].head_decoder.bytes();
    var head_before: [body_limits.pipeline_bytes_per_connection]u8 = undefined;
    @memcpy(head_before[0..head.len], head);
    harness.io.injectUnprovenAbort();

    try std.testing.expectEqual(error.BackendFailure, harness.runtime.failBackend());
    const status = harness.runtime.cleanupStatus();
    try std.testing.expect(status.requiresProcessExit());
    try std.testing.expectEqual(worker.Phase.failed, status.phase);
    try std.testing.expectEqual(worker_gzip_lifecycle.Phase.stopping, status.gzip_phase);
    try std.testing.expectEqual(@as(u16, 1), status.gzip_active_jobs);
    try std.testing.expectEqual(@as(u8, 1), status.gzip_operations);
    try std.testing.expectEqual(@as(u16, 1), status.live_connections);
    try std.testing.expectEqual(@as(u16, 1), status.live_requests);
    try std.testing.expectEqual(@as(u16, 0), status.workspace_abort_attempts);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0x5a} ** 16),
        harness.storage.responseReadable(indices.request)[0..16],
    );
    try std.testing.expectEqualSlices(
        u8,
        head_before[0..head.len],
        harness.storage.connections[indices.connection].head_decoder.bytes(),
    );
    try std.testing.expect(harness.storage.requests[indices.request].gzip_lease != null);

    try std.testing.expect(harness.runtime.gzip.finishFatalAfterBackend(
        &harness.storage,
        &harness.storage,
        settleBodyJob,
    ));
}

test "gzip terminal returns accept capacity after close completions reap first" {
    var harness: BodyHarness = undefined;
    try harness.init();
    const indices = try harness.beginGzipRequest();
    const lease = harness.storage.requests[indices.request].gzip_lease.?;
    try std.testing.expectEqual(
        accept_controller.Phase.paused,
        harness.runtime.controller.phase,
    );

    try std.testing.expectEqual(
        connection_driver.Disposition.retained,
        try harness.runtime.driver.stop(indices.connection),
    );
    try harness.completeConnectionCleanupBeforeWake();
    try std.testing.expectEqual(@as(u16, 0), harness.storage.connection_pool.available());
    try std.testing.expect(harness.storage.connections[indices.connection].socket_closed);
    try std.testing.expectEqual(
        @as(?u16, indices.request),
        harness.storage.connections[indices.connection].active_request,
    );

    var spins: u32 = 0;
    while (spins < 100_000) : (spins += 1) {
        const bits = harness.storage.gzip_decoders.slots[lease.index].signals.load(.acquire);
        const signals: worker_gzip_lifecycle.Signals = @bitCast(bits);
        if (signals.terminal) break;
        std.Thread.yield() catch {};
    }
    if (spins == 100_000) return error.TestUnexpectedResult;

    const wake = harness.findToken(.wake) orelse return error.TestUnexpectedResult;
    try harness.complete(wake, .{ .success = .{ .wake = {} } }, false);
    try std.testing.expectEqual(@as(u16, 1), harness.storage.connection_pool.available());
    try std.testing.expectEqual(@as(u16, 1), harness.storage.request_pool.available());
    try std.testing.expect(harness.findToken(.accept) != null);
    const metrics = harness.runtime.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), metrics.live_connections);

    try std.testing.expectEqual(error.BackendFailure, harness.runtime.failBackend());
    try std.testing.expect(harness.runtime.cleanupStatus().quiescent());
}

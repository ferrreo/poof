const std = @import("std");

const application = @import("../../../src/application.zig");
const response = @import("../../../src/response.zig");
const response_stream = @import("../../../src/response/stream.zig");
const route = @import("../../../src/route.zig");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
const config = @import("../../../src/internal/runtime/config.zig");
const connection_driver = @import("../../../src/internal/runtime/connection/driver.zig");
const deterministic_reactor = @import("../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../src/internal/runtime/reactor.zig");
const worker_storage = @import("../../../src/internal/runtime/worker/storage.zig");
const worker_stream_wake = @import("../../../src/internal/runtime/worker/stream_wake.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const unknown_request =
    "GET /unknown HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "TE: trailers\r\n\r\n";
const exact_request = "GET /exact HTTP/1.1\r\nHost: example.test\r\n\r\n";
const trailer_names = [_][]const u8{"x-check"};
const trailer_fields = [_]response_stream.TrailerField{
    .{ .name = "x-check", .value = "done" },
};

const Scenario = enum(u8) {
    unknown_pending,
    unknown_poll_ready,
    unknown_terminal,
    producer_failure,
    exact_ok,
    exact_underrun,
    exact_overrun,
    exact_zero,
};

const Coverage = struct {
    const scenarios: u64 = 0xff;
    const partial_send: u64 = 1 << 8;
    const send_error: u64 = 1 << 9;
    const timeout: u64 = 1 << 10;
    const wake_publish: u64 = 1 << 11;
    const wake_dispatch: u64 = 1 << 12;
    const poll_ready: u64 = 1 << 13;
    const cancellation: u64 = 1 << 14;
    const stale_wake: u64 = 1 << 15;
    const chunk_terminal: u64 = 1 << 16;
    const exact_success: u64 = 1 << 17;
    const exact_failure: u64 = 1 << 18;
    const required: u64 = scenarios | partial_send | send_error | timeout |
        wake_publish | wake_dispatch | poll_ready | cancellation | stale_wake |
        chunk_terminal | exact_success | exact_failure;
};

const ProducerControl = struct {
    scenario: Scenario = .unknown_pending,
    step: u8 = 0,
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
    wake: ?response_stream.Wake = null,
    runtime_wake: ?worker_stream_wake.StreamWake = null,
    wake_published: bool = false,

    fn reset(self: *ProducerControl, scenario: Scenario) void {
        self.* = .{ .scenario = scenario };
    }
};

const TestState = struct {
    producer: ProducerControl = .{},
    after_calls: u8 = 0,
    last_transport: application.TransportOutcome = .aborted,
};

const TestContext = application.Context(TestState, response.standard_head_limits);
const StreamResponse = TestContext.StreamResponse(Producer);

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
        return switch (self.control.scenario) {
            .unknown_pending => switch (step) {
                0 => progress(output, "abc"),
                1 => self.wait(wake),
                else => .{ .done = &.{} },
            },
            .unknown_poll_ready => switch (step) {
                0 => self.notifyThenWait(wake),
                1 => progress(output, "xy"),
                else => .{ .done = &.{} },
            },
            .unknown_terminal => if (step == 0)
                progress(output, "z")
            else
                .{ .done = &trailer_fields },
            .producer_failure => error.ProducerFailed,
            .exact_ok => switch (step) {
                0 => progress(output, "ab"),
                1 => progress(output, "cde"),
                else => .{ .done = &.{} },
            },
            .exact_underrun => if (step == 0)
                progress(output, "ab")
            else
                .{ .done = &.{} },
            .exact_overrun => if (step == 0)
                progress(output, "abcde")
            else
                progress(output, "x"),
            .exact_zero => .{ .done = &.{} },
        };
    }

    pub fn abort(self: *Producer) void {
        self.control.aborts += 1;
    }

    pub fn join(self: *Producer) void {
        self.control.joins += 1;
    }

    fn wait(self: *Producer, wake: response_stream.Wake) response_stream.PollResult {
        self.control.wake = wake;
        return .pending;
    }

    fn notifyThenWait(self: *Producer, wake: response_stream.Wake) response_stream.PollResult {
        self.control.wake = wake;
        const runtime_wake = self.control.runtime_wake orelse {
            wake.notify();
            return .pending;
        };
        const before = runtime_wake.markPending();
        wake.notify();
        self.control.wake_published = before == .pending;
        return .pending;
    }
};

fn progress(output: []u8, value: []const u8) response_stream.PollResult {
    std.debug.assert(value.len <= output.len);
    @memcpy(output[0..value.len], value);
    return .{ .progress = value.len };
}

const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const TestContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.last_transport = outcome.transport;
    }
};

fn unknown(context: *TestContext) StreamResponse {
    const names: []const []const u8 = if (context.state.producer.scenario == .unknown_terminal)
        &trailer_names
    else
        &.{};
    return context.streamUnknown(
        .ok,
        response.media.text,
        Producer{ .control = &context.state.producer },
        names,
    );
}

fn exact(context: *TestContext) StreamResponse {
    const length: u64 = if (context.state.producer.scenario == .exact_zero) 0 else 5;
    return context.streamExact(
        .ok,
        response.media.text,
        length,
        Producer{ .control = &context.state.producer },
    );
}

const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{
        route.get("/unknown", unknown),
        route.get("/exact", exact),
    },
});

const test_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 32,
    .completion_entries = 64,
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});

const TestStorage = worker_storage.Storage(TestApp, test_limits);
const TestReactor = deterministic_reactor.DeterministicReactor(128);
const TestDriver = connection_driver.Driver(TestApp, TestStorage, TestReactor);

const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    driver: TestDriver = undefined,
    now_ns: u64 = 1,
    buffer_generation: u16 = 1,
    runtime_wake: ?worker_stream_wake.StreamWake = null,
    wake_signaled: bool = false,
    coverage: u64 = 0,

    fn init(self: *Harness) !void {
        self.io = .{};
        self.state = .{};
        try self.storage.init(&self.slab);
        self.storage.stream_wakes = try TestStorage.StreamWakeLifecycle.init(0);
        try self.storage.stream_wakes.start(&self.io);
        self.driver = try TestDriver.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
        );
        self.now_ns = 1;
        self.buffer_generation = 1;
        self.runtime_wake = null;
        self.wake_signaled = false;
        self.coverage = 0;
    }

    fn prepare(self: *Harness, scenario: Scenario) !u16 {
        try self.expectBaseline();
        self.state = .{};
        self.state.producer.reset(scenario);
        self.now_ns = 1;
        self.runtime_wake = null;
        self.wake_signaled = false;
        self.coverage |= @as(u64, 1) << @as(u6, @intCast(@intFromEnum(scenario)));

        const connection = self.storage.acquireConnection(.{ .value = 70 }) orelse {
            return error.FuzzConnectionExhausted;
        };
        try self.driver.start(connection, self.now_ns);
        try self.receive(connection, if (isExact(scenario)) exact_request else unknown_request);
        const request = self.storage.connections[connection].active_request.?;
        self.runtime_wake = self.storage.requests[request].stream_transport.state.wake();
        self.state.producer.runtime_wake = self.runtime_wake;
        return connection;
    }

    fn finish(self: *Harness, connection: u16, scenario: Scenario) !void {
        if (self.storage.connections[connection].phase != .free) {
            _ = try self.driver.stop(connection);
            try self.drainConnection(connection);
        }
        if (self.runtime_wake) |wake| {
            try std.testing.expectEqual(worker_stream_wake.NotifyResult.stale, wake.notify());
            self.coverage |= Coverage.stale_wake;
        }
        try self.drainInventory();
        try std.testing.expectEqual(@as(u8, 1), self.state.after_calls);
        try std.testing.expectEqual(@as(u8, 1), self.state.producer.joins);
        try std.testing.expect(self.state.producer.aborts <= 1);
        if (isExact(scenario)) self.recordExactOutcome();
        try self.expectBaseline();
    }

    fn forceFinish(self: *Harness, connection: u16, scenario: Scenario) void {
        self.finish(connection, scenario) catch @panic("stream driver fuzz cleanup failed");
    }

    fn deinit(self: *Harness) !void {
        try self.expectBaseline();
        try self.storage.stream_wakes.confirmPublishersJoined();
        const poll = self.storage.stream_wakes.currentPollToken().?;
        try self.storage.stream_wakes.beginStop(&self.io);
        const cancel = self.storage.stream_wakes.currentCancelToken().?;
        try self.completeWake(cancel, .{ .success = .{ .cancel = .canceled } });
        try self.completeWake(poll, .{ .failure = .canceled });
        try std.testing.expect(self.storage.stream_wakes.isStopped());
        try std.testing.expectEqual(@as(u16, 0), self.io.activeCount());
    }

    fn step(self: *Harness, connection: u16, action: u8) !void {
        self.now_ns +%= @as(u64, action) + 1;
        const variant: u4 = @truncate(action >> 4);
        switch (action & 0x0f) {
            0 => try self.completeSend(connection, .all),
            1 => try self.completeSend(connection, .one),
            2 => try self.completeSend(connection, .half),
            3 => try self.failSend(connection, variant),
            4 => try self.completeTimeout(connection, true),
            5 => try self.completeTimeout(connection, false),
            6 => self.notifyProducer(connection),
            7 => try self.dispatchWake(),
            8 => try self.handleReady(connection),
            9 => try self.stop(connection),
            10 => try self.completeCancel(connection, variant),
            11 => try self.completeClose(connection),
            12 => try self.completeReceive(connection),
            13 => self.notifyRuntime(),
            14 => try self.completeFirst(connection, variant),
            15 => {},
            else => unreachable,
        }
        self.syncNotification();
    }

    fn receive(self: *Harness, connection: u16, bytes: []const u8) !void {
        const token = self.storage.connections[connection].receive_token.?;
        const generation = self.buffer_generation;
        self.buffer_generation = reactor.nextGeneration(generation);
        try self.io.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try token.slot(),
                .buffer_index = 0,
                .buffer_generation = generation,
            },
            .bytes = bytes,
        } } } }, false);
        _ = try self.handleConnectionCompletion();
    }

    fn completeSend(self: *Harness, connection: u16, mode: SendMode) !void {
        const token = self.storage.connections[connection].send_token orelse return;
        const bytes = self.io.operation(token).?.send.bytes;
        if (std.mem.startsWith(u8, bytes, "0\r\n")) {
            self.coverage |= Coverage.chunk_terminal;
        }
        const count = switch (mode) {
            .all => bytes.len,
            .one => 1,
            .half => @max(1, bytes.len / 2),
        };
        if (count < bytes.len) self.coverage |= Coverage.partial_send;
        try self.io.complete(token, .{ .success = .{ .send = @intCast(count) } }, false);
        _ = try self.handleConnectionCompletion();
    }

    fn failSend(self: *Harness, connection: u16, variant: u4) !void {
        const token = self.storage.connections[connection].send_token orelse return;
        const problem: reactor.CompletionError = switch (variant & 0x03) {
            0 => .broken_pipe,
            1 => .connection_reset,
            2 => .canceled,
            3 => .backend_failure,
            else => unreachable,
        };
        self.coverage |= Coverage.send_error;
        try self.io.complete(token, .{ .failure = problem }, false);
        _ = try self.handleConnectionCompletion();
    }

    fn completeTimeout(self: *Harness, connection: u16, expire: bool) !void {
        const token = self.storage.connections[connection].timeout_token orelse
            self.findConnectionToken(connection, .timeout) orelse return;
        if (expire) {
            self.coverage |= Coverage.timeout;
            const deadline = self.io.operation(token).?.timeout.deadline_ns;
            self.now_ns = @max(self.now_ns, deadline);
            try self.io.complete(token, .{ .success = .{ .timeout = {} } }, false);
        } else {
            try self.io.complete(token, .{ .failure = .canceled }, false);
        }
        _ = try self.handleConnectionCompletion();
    }

    fn notifyProducer(self: *Harness, connection: u16) void {
        const request = self.activeRequest(connection) orelse return;
        if (self.storage.requests[request].stream_transport.state.phase() != .waiting) return;
        const wake = self.state.producer.wake orelse return;
        const runtime_wake = self.runtime_wake orelse return;
        // Public Wake erases NotifyResult; observe retained readiness before its callback.
        const before = runtime_wake.markPending();
        wake.notify();
        switch (before) {
            .pending => {
                self.wake_signaled = true;
                self.coverage |= Coverage.wake_publish;
            },
            .ready => {},
            .stale => self.coverage |= Coverage.stale_wake,
        }
    }

    fn notifyRuntime(self: *Harness) void {
        const wake = self.runtime_wake orelse return;
        switch (wake.notify()) {
            .published => {
                self.wake_signaled = true;
                self.coverage |= Coverage.wake_publish;
            },
            .coalesced => {},
            .stale => self.coverage |= Coverage.stale_wake,
        }
    }

    fn dispatchWake(self: *Harness) !void {
        if (!self.wake_signaled) return;
        self.wake_signaled = false;
        const poll = self.storage.stream_wakes.currentPollToken().?;
        try self.io.complete(poll, .{ .success = .{ .wake = {} } }, false);
        const event = try self.storage.stream_wakes.handle(
            &self.io,
            self.io.nextCompletion().?,
        );
        var request: u16 = 0;
        while (request < self.storage.requests.len) : (request += 1) {
            if (event.ready.contains(request)) {
                try self.driver.handleStreamReady(request, self.now_ns);
            }
        }
        self.coverage |= Coverage.wake_dispatch;
        self.syncNotification();
    }

    fn handleReady(self: *Harness, connection: u16) !void {
        const request = self.activeRequest(connection) orelse return;
        try self.driver.handleStreamReady(request, self.now_ns);
    }

    fn stop(self: *Harness, connection: u16) !void {
        if (self.storage.connections[connection].phase == .free) return;
        self.coverage |= Coverage.cancellation;
        _ = try self.driver.stop(connection);
    }

    fn completeCancel(self: *Harness, connection: u16, variant: u4) !void {
        const token = self.findCurrentTimeoutCancel(connection) orelse
            self.findConnectionToken(connection, .cancel) orelse return;
        const target = self.io.operation(token).?.cancel.target;
        if (variant & 1 != 0 and self.io.operation(target) != null) {
            try self.io.complete(target, .{ .failure = .canceled }, false);
            _ = try self.handleConnectionCompletion();
        }
        const canceled = self.io.operation(target) != null;
        try self.io.complete(token, .{ .success = .{ .cancel = if (canceled)
            .canceled
        else
            .not_found } }, false);
        _ = try self.handleConnectionCompletion();
        self.coverage |= Coverage.cancellation;
    }

    fn completeClose(self: *Harness, connection: u16) !void {
        const token = self.findConnectionToken(connection, .close) orelse return;
        try self.io.complete(token, .{ .success = .{ .close = {} } }, false);
        _ = try self.handleConnectionCompletion();
    }

    fn completeReceive(self: *Harness, connection: u16) !void {
        const token = self.findConnectionToken(connection, .receive) orelse return;
        try self.io.complete(token, .{ .failure = .canceled }, false);
        _ = try self.handleConnectionCompletion();
    }

    fn completeFirst(self: *Harness, connection: u16, variant: u4) !void {
        const submission = self.findConnectionSubmission(connection) orelse return;
        switch (submission.operation) {
            .send => try self.completeSend(connection, if (variant & 1 == 0) .one else .all),
            .timeout => try self.completeTimeout(connection, variant & 1 == 0),
            .cancel => try self.completeCancel(connection, variant),
            .close => try self.completeClose(connection),
            .receive => try self.completeReceive(connection),
            .accept,
            .wake,
            .file_open,
            .file_write,
            .file_close,
            .file_link,
            .file_unlink,
            .file_rename_no_replace,
            .file_sync,
            .upload_cancel,
            .file_read,
            .file_stat,
            .file_cancel,
            => return error.FuzzUnexpectedOperation,
        }
    }

    fn drainConnection(self: *Harness, connection: u16) !void {
        var attempts: u16 = 0;
        while (self.storage.connections[connection].phase != .free) {
            if (attempts == 256) return error.FuzzDrainBoundExceeded;
            attempts += 1;
            const submission = self.findConnectionSubmission(connection) orelse {
                return error.FuzzCompletionMissing;
            };
            switch (submission.operation) {
                .cancel => try self.completeCancel(connection, 0),
                .close => try self.completeClose(connection),
                .receive => try self.completeReceive(connection),
                .send, .timeout => {
                    try self.io.complete(submission.token, .{ .failure = .canceled }, false);
                    _ = try self.handleConnectionCompletion();
                },
                .accept,
                .wake,
                .file_open,
                .file_write,
                .file_close,
                .file_link,
                .file_unlink,
                .file_rename_no_replace,
                .file_sync,
                .upload_cancel,
                .file_read,
                .file_stat,
                .file_cancel,
                => return error.FuzzUnexpectedOperation,
            }
            self.syncNotification();
        }
    }

    fn drainInventory(self: *Harness) !void {
        if (!self.wake_signaled) return;
        self.wake_signaled = false;
        const poll = self.storage.stream_wakes.currentPollToken().?;
        try self.io.complete(poll, .{ .success = .{ .wake = {} } }, false);
        _ = try self.storage.stream_wakes.handle(&self.io, self.io.nextCompletion().?);
    }

    fn handleConnectionCompletion(self: *Harness) !connection_driver.Disposition {
        const completion = self.io.nextCompletion() orelse {
            return error.FuzzCompletionMissing;
        };
        const disposition = try self.driver.handle(completion, self.now_ns);
        self.syncNotification();
        return disposition;
    }

    fn completeWake(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
    ) !void {
        try self.io.complete(token, result, false);
        _ = try self.storage.stream_wakes.handle(&self.io, self.io.nextCompletion().?);
    }

    fn findConnectionToken(
        self: *const Harness,
        connection: u16,
        kind: reactor.OperationKind,
    ) ?reactor.OperationToken {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.slot_index == connection and fields.kind == kind) {
                return submission.token;
            }
        }
        return null;
    }

    fn findConnectionSubmission(self: *const Harness, connection: u16) ?reactor.Submission {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.slot_index == connection and fields.kind != .wake) return submission;
        }
        return null;
    }

    fn findCurrentTimeoutCancel(
        self: *const Harness,
        connection: u16,
    ) ?reactor.OperationToken {
        const timeout = self.storage.connections[connection].timeout_token orelse return null;
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if (submission.operation != .cancel) continue;
            if (submission.operation.cancel.target.eql(timeout)) return submission.token;
        }
        return null;
    }

    fn activeRequest(self: *const Harness, connection: u16) ?u16 {
        if (self.storage.connections[connection].phase == .free) return null;
        return self.storage.connections[connection].active_request;
    }

    fn syncNotification(self: *Harness) void {
        if (self.state.producer.wake_published) {
            self.state.producer.wake_published = false;
            self.wake_signaled = true;
            self.coverage |= Coverage.wake_publish;
        }
        if (self.state.producer.scenario == .unknown_poll_ready and
            self.state.producer.polls >= 2)
        {
            self.coverage |= Coverage.poll_ready;
        }
    }

    fn recordExactOutcome(self: *Harness) void {
        switch (self.state.last_transport) {
            .completed => self.coverage |= Coverage.exact_success,
            .exact_overrun, .exact_underrun => self.coverage |= Coverage.exact_failure,
            else => {},
        }
    }

    fn expectBaseline(self: *const Harness) !void {
        try std.testing.expectEqual(@as(u16, 1), self.io.activeCount());
        try std.testing.expectEqual(@as(u16, 0), self.io.pendingCompletionCount());
        try std.testing.expectEqual(@as(u16, 0), self.io.borrowedCount());
        try std.testing.expectEqual(
            test_limits.connection_slots,
            self.storage.connection_pool.available(),
        );
        try std.testing.expectEqual(
            test_limits.request_slots,
            self.storage.request_pool.available(),
        );
        const wake = self.storage.stream_wakes.status();
        try std.testing.expectEqual(@as(u16, 0), wake.active_publishers);
        try std.testing.expectEqual(@as(u8, 1), wake.operations);
    }

    fn expectCoverage(self: *const Harness) !void {
        try std.testing.expectEqual(Coverage.required, self.coverage & Coverage.required);
    }
};

const SendMode = enum { all, one, half };

fn isExact(scenario: Scenario) bool {
    return switch (scenario) {
        .unknown_pending, .unknown_poll_ready, .unknown_terminal, .producer_failure => false,
        .exact_ok, .exact_underrun, .exact_overrun, .exact_zero => true,
    };
}

fn fuzzDriver(harness: *Harness, smith: *std.testing.Smith) !void {
    const value = smith.valueRangeAtMost(u8, 0, @intFromEnum(Scenario.exact_zero));
    const scenario: Scenario = @enumFromInt(value);
    var action_storage: [64]u8 = undefined;
    const actions = action_storage[0..smith.slice(&action_storage)];
    const connection = try harness.prepare(scenario);
    var cleanup = true;
    defer if (cleanup) harness.forceFinish(connection, scenario);
    for (actions) |action| {
        if (harness.storage.connections[connection].phase == .free) break;
        try harness.step(connection, action);
    }
    try harness.finish(connection, scenario);
    cleanup = false;
}

test "stream driver bounded send wake cancellation schedule fuzz" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit() catch @panic("stream driver fuzz lifecycle cleanup failed");
    try std.testing.fuzz(&harness, fuzzDriver, .{ .corpus = &fuzz_corpus });
    try harness.expectCoverage();
}

fn fuzzCase(
    comptime scenario: u64,
    comptime actions: []const u8,
) [12 + actions.len]u8 {
    const encoded = fuzz_support.smithInput(actions);
    var input: [12 + actions.len]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], scenario, .little);
    @memcpy(input[8..], &encoded);
    return input;
}

const fuzz_corpus = struct {
    const pending = fuzzCase(0, &.{ 0, 1, 0, 6, 7, 1, 0 });
    const poll_ready = fuzzCase(1, &.{ 0, 7, 10, 5, 0, 0 });
    const terminal = fuzzCase(2, &.{ 0, 0, 1, 0 });
    const producer_failure = fuzzCase(3, &.{ 1, 0 });
    const exact_ok = fuzzCase(4, &.{ 0, 1, 0, 0, 0 });
    const exact_underrun = fuzzCase(5, &.{ 0, 0 });
    const exact_overrun = fuzzCase(6, &.{ 0, 0 });
    const exact_zero = fuzzCase(7, &.{ 1, 0 });
    const timeout = fuzzCase(0, &.{ 4, 10, 14 });
    const send_error = fuzzCase(0, &.{3});
    const cancellation = fuzzCase(0, &.{ 9, 10, 14 });
    const coalesced_producer_wake_replay = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x33, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x06, 0x07, 0x01, 0x00, 0x27,
        0xab, 0x56, 0x22, 0x47, 0x24, 0xef, 0x2c, 0xa5,
        0x45, 0xa9, 0x6d, 0x5f, 0x96, 0xef, 0x9b, 0xf5,
        0x05, 0xaa, 0xbd, 0xe5, 0xa9, 0x44, 0xef, 0xa0,
        0xc3, 0xc6, 0x68, 0x3b, 0x61, 0xbe, 0x4f, 0x54,
        0x04, 0x4a, 0x56, 0x0b, 0x56, 0xcb, 0x0b,
    };
    const poll_ready_cleanup_replay = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x18, 0x00, 0x00, 0x00, 0xeb, 0xfc, 0xcd, 0x81,
        0xc7, 0x6f, 0x85, 0xf0, 0xac, 0xdd, 0x7a, 0x4e,
        0xf4, 0x51, 0x2b, 0x07, 0xea, 0x53, 0xeb, 0xfc,
        0xcd, 0x81, 0xc7, 0x6f,
    };

    const values = [_][]const u8{
        &pending,
        &poll_ready,
        &terminal,
        &producer_failure,
        &exact_ok,
        &exact_underrun,
        &exact_overrun,
        &exact_zero,
        &timeout,
        &send_error,
        &cancellation,
        &coalesced_producer_wake_replay,
        &poll_ready_cleanup_replay,
    };
}.values;

const std = @import("std");

const application = @import("../../../../src/application.zig");
const response = @import("../../../../src/response.zig");
const response_stream = @import("../../../../src/response/stream.zig");
const route = @import("../../../../src/route.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const worker_module = @import("../../../../src/internal/runtime/worker.zig");
const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

const fixed_epoch_second: i64 = 1_784_030_400;
const stream_request = "GET /stream HTTP/1.1\r\nHost: example.test\r\n\r\n";

const Mode = enum { wake_then_body, immediate_body };

const ProducerControl = struct {
    mode: Mode = .wake_then_body,
    step: u8 = 0,
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
    wake: ?response_stream.Wake = null,
    backend_aborted: ?*const bool = null,
    abort_after_backend: bool = false,
    join_after_backend: bool = false,
    events: [8]u8 = undefined,
    events_len: u8 = 0,

    fn mark(self: *ProducerControl, value: u8) void {
        self.events[self.events_len] = value;
        self.events_len += 1;
    }

    fn written(self: *const ProducerControl) []const u8 {
        return self.events[0..self.events_len];
    }
};

const TestState = struct {
    producer: ProducerControl = .{},
    after_calls: u8 = 0,
    last_transport: application.TransportOutcome = .completed,
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
        return switch (self.control.mode) {
            .wake_then_body => switch (step) {
                0 => self.wait(wake),
                1 => progress(output, "ok"),
                else => .{ .done = &.{} },
            },
            .immediate_body => switch (step) {
                0 => progress(output, "payload"),
                else => self.wait(wake),
            },
        };
    }

    pub fn abort(self: *Producer) void {
        self.control.aborts += 1;
        self.control.abort_after_backend = self.backendAborted();
        self.control.mark('A');
    }

    pub fn join(self: *Producer) void {
        self.control.joins += 1;
        self.control.join_after_backend = self.backendAborted();
        self.control.mark('J');
    }

    fn wait(self: *Producer, wake: response_stream.Wake) response_stream.PollResult {
        self.control.wake = wake;
        return .pending;
    }

    fn backendAborted(self: *const Producer) bool {
        return if (self.control.backend_aborted) |aborted| aborted.* else false;
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
        context.state.producer.mark('O');
    }
};

fn stream(context: *TestContext) StreamResponse {
    return context.streamUnknown(
        .ok,
        response.media.text,
        Producer{ .control = &context.state.producer },
        &.{},
    );
}

const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{route.get("/stream", stream)},
});

const test_limits = config.Limits.validate(.{
    .connection_slots = 2,
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
const TestWorker = worker_module.Worker(TestApp, TestStorage, TestReactor);

const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    worker: TestWorker = undefined,
    sample: worker_module.ClockSample = .{
        .monotonic_ns = 1,
        .epoch_second = fixed_epoch_second,
    },
    buffer_generation: u16 = 1,

    fn init(self: *Harness, mode: Mode) !void {
        self.io = .{};
        self.state = .{ .producer = .{ .mode = mode } };
        self.state.producer.backend_aborted = &self.io.aborted;
        try self.storage.init(&self.slab);
        self.sample = .{ .monotonic_ns = 1, .epoch_second = fixed_epoch_second };
        self.buffer_generation = 1;
        try self.worker.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .value = 4 },
            null,
        );
    }

    fn start(self: *Harness) !void {
        try std.testing.expectEqual(
            worker_module.Step.progressed,
            try self.worker.start(self.sample),
        );
    }

    fn findToken(
        self: *const Harness,
        kind: reactor.OperationKind,
        slot_index: ?u16,
    ) ?reactor.OperationToken {
        var active_index: u16 = 0;
        while (active_index < self.io.activeCount()) : (active_index += 1) {
            const submission = self.io.activeSubmission(active_index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.kind == kind and
                (slot_index == null or fields.slot_index == slot_index.?))
            {
                return submission.token;
            }
        }
        return null;
    }

    fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
    ) !worker_module.Step {
        try self.io.complete(token, result, false);
        const completion = self.io.nextCompletion() orelse {
            return error.TestUnexpectedResult;
        };
        return self.worker.handle(completion, self.sample);
    }

    fn accept(self: *Harness, socket: u64) !u16 {
        const token = self.findToken(.accept, std.math.maxInt(u16)) orelse {
            return error.TestUnexpectedResult;
        };
        _ = try self.complete(token, .{ .success = .{
            .accept = reactor.Accepted.loopback(.{ .value = socket }),
        } });
        for (self.storage.connections, 0..) |connection, index| {
            if (connection.phase != .free and connection.socket.value == socket) {
                return @intCast(index);
            }
        }
        return error.TestUnexpectedResult;
    }

    fn receive(self: *Harness, connection_index: u16, bytes: []const u8) !void {
        const token = self.storage.connections[connection_index].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        const generation = self.buffer_generation;
        self.buffer_generation = reactor.nextGeneration(generation);
        _ = try self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try token.slot(),
                .buffer_index = 0,
                .buffer_generation = generation,
            },
            .bytes = bytes,
        } } } });
    }

    fn completeSend(self: *Harness, connection_index: u16) !void {
        const token = self.storage.connections[connection_index].send_token orelse {
            return error.TestUnexpectedResult;
        };
        const bytes = self.io.operation(token).?.send.bytes;
        _ = try self.complete(token, .{ .success = .{ .send = @intCast(bytes.len) } });
    }

    fn dispatchStreamWake(self: *Harness) !void {
        self.state.producer.wake.?.notify();
        const token = self.findToken(.wake, reactor.stream_wake_control_slot) orelse {
            return error.TestUnexpectedResult;
        };
        _ = try self.complete(token, .{ .success = .{ .wake = {} } });
    }

    fn retireParkedTimeout(self: *Harness, connection_index: u16) !void {
        const timeout = self.storage.connections[connection_index].timeout_token orelse {
            return error.TestUnexpectedResult;
        };
        var cancel: ?reactor.OperationToken = null;
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if (submission.operation != .cancel) continue;
            if (submission.operation.cancel.target.eql(timeout)) cancel = submission.token;
        }
        _ = try self.complete(
            cancel orelse return error.TestUnexpectedResult,
            .{ .success = .{ .cancel = .canceled } },
        );
        _ = try self.complete(timeout, .{ .failure = .canceled });
    }

    fn stopAndDrain(self: *Harness) !void {
        var step = try self.worker.stop();
        var iterations: u16 = 0;
        while (step != .stopped) {
            if (iterations == 256) return error.TestUnexpectedResult;
            iterations += 1;
            if (step == .flush_retry) {
                step = try self.worker.retryFlush();
                continue;
            }
            const submission = self.io.activeSubmission(0) orelse {
                return error.TestUnexpectedResult;
            };
            const kind = (try submission.token.fields()).kind;
            step = try self.complete(submission.token, completionFor(kind));
        }
    }
};

fn completionFor(kind: reactor.OperationKind) reactor.CompletionResult {
    return switch (kind) {
        .accept,
        .receive,
        .send,
        .timeout,
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
        => .{ .failure = .canceled },
        .close => .{ .success = .{ .close = {} } },
        .cancel => .{ .success = .{ .cancel = .canceled } },
    };
}

test "worker routes stream wake and stops lifecycle at exact quiescence" {
    var harness: Harness = undefined;
    try harness.init(.wake_then_body);
    try std.testing.expectEqual(.initialized, harness.worker.cleanupStatus().stream_phase);
    try harness.start();
    const started = harness.worker.cleanupStatus();
    try std.testing.expectEqual(.running, started.stream_phase);
    try std.testing.expectEqual(@as(u8, 1), started.stream_operations);
    try std.testing.expect(
        harness.findToken(.wake, reactor.stream_wake_control_slot) != null,
    );

    const connection = try harness.accept(10);
    try harness.receive(connection, stream_request);
    try harness.completeSend(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.state.producer.polls);
    try std.testing.expect(harness.state.producer.wake != null);

    try harness.dispatchStreamWake();
    try harness.retireParkedTimeout(connection);
    try std.testing.expectEqual(@as(u8, 2), harness.state.producer.polls);
    try std.testing.expectEqualStrings("2\r\nok\r\n", harness.worker.driver
        .storage.responseReadable(0)[0..7]);
    try harness.completeSend(connection);
    try std.testing.expectEqualStrings("0\r\n\r\n", harness.worker.driver
        .storage.responseReadable(0)[0..5]);
    try harness.completeSend(connection);
    try std.testing.expectEqualStrings("JO", harness.state.producer.written());

    try harness.stopAndDrain();
    const stopped = harness.worker.cleanupStatus();
    try std.testing.expect(stopped.quiescent());
    try std.testing.expectEqual(.stopped, stopped.stream_phase);
    try std.testing.expectEqual(@as(u8, 0), stopped.stream_operations);
    try std.testing.expectEqual(@as(u16, 0), stopped.stream_active_publishers);
}

test "fatal active send settles producer only after backend ownership" {
    var harness: Harness = undefined;
    try harness.init(.immediate_body);
    try harness.start();
    const connection = try harness.accept(20);
    try harness.receive(connection, stream_request);
    try harness.completeSend(connection);

    const send = harness.storage.connections[connection].send_token.?;
    try std.testing.expect(harness.io.operation(send) != null);
    try std.testing.expectEqualStrings(
        "7\r\npayload\r\n",
        harness.io.operation(send).?.send.bytes,
    );
    try std.testing.expect(!harness.io.aborted);
    try std.testing.expectEqualStrings("", harness.state.producer.written());

    try std.testing.expectEqual(error.BackendFailure, harness.worker.failBackend());
    const status = harness.worker.cleanupStatus();
    try std.testing.expect(harness.io.aborted);
    try std.testing.expect(harness.state.producer.abort_after_backend);
    try std.testing.expect(harness.state.producer.join_after_backend);
    try std.testing.expectEqualStrings("AJO", harness.state.producer.written());
    try std.testing.expectEqual(application.TransportOutcome.aborted, harness.state.last_transport);
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(.stopped, status.stream_phase);
    try std.testing.expectEqual(@as(u8, 0), status.stream_operations);
    try std.testing.expectEqual(@as(u16, 0), status.stream_active_publishers);
}

test {
    std.testing.refAllDecls(@This());
}

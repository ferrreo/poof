pub const std = @import("std");

pub const application = @import("../../../../src/application.zig");
pub const cors = @import("../../../../src/cors.zig");
pub const response = @import("../../../../src/response.zig");
pub const response_stream = @import("../../../../src/response/stream.zig");
pub const route = @import("../../../../src/route.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
pub const connection_response_transport = @import(
    "../../../../src/internal/runtime/connection/response_transport.zig",
);
pub const deterministic_reactor = @import(
    "../../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_stream_wake = @import("../../../../src/internal/runtime/worker/stream_wake.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
pub const unknown_request =
    "GET /unknown HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "TE: trailers\r\n\r\n";
pub const exact_request = "GET /exact HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const failure_request = "GET /failure HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const cancel_request = "GET /cancel HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const cors_request =
    "GET /cors HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Origin: https://app.example\r\n" ++
    "TE: trailers\r\n\r\n";
pub const head_request = "HEAD /unknown HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const trailer_names = [_][]const u8{"x-checksum"};
pub const trailer_fields = [_]response_stream.TrailerField{
    .{ .name = "x-checksum", .value = "done" },
};

pub const Mode = enum { unknown, exact_zero, failure, waiting, cycling, large };

pub const WakeRace = struct {
    wake: response_stream.Wake,
    go: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    notifications: std.atomic.Value(u32) = .init(0),
    abort_after_invalidation: bool = false,
    join_after_invalidation: bool = false,

    pub fn run(self: *WakeRace) void {
        while (!self.go.load(.acquire)) std.Thread.yield() catch {};
        while (!self.stop.load(.acquire)) {
            self.wake.notify();
            _ = self.notifications.fetchAdd(1, .release);
            std.Thread.yield() catch {};
        }
        self.done.store(true, .release);
    }
};

pub const ProducerControl = struct {
    mode: Mode = .unknown,
    step: u8 = 0,
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
    wake: ?response_stream.Wake = null,
    race: ?*WakeRace = null,
    events: [8]u8 = undefined,
    events_len: u8 = 0,

    pub fn mark(self: *ProducerControl, value: u8) void {
        self.events[self.events_len] = value;
        self.events_len += 1;
    }

    pub fn written(self: *const ProducerControl) []const u8 {
        return self.events[0..self.events_len];
    }
};

pub const TestState = struct {
    producer: ProducerControl = .{},
    after_calls: u8 = 0,
    last_transport: application.TransportOutcome = .aborted,
};

pub const TestContext = application.Context(TestState, response.standard_head_limits);
pub const StreamResponse = TestContext.StreamResponse(Producer);

pub const Producer = struct {
    control: *ProducerControl,

    pub fn poll(
        self: *Producer,
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.control.polls += 1;
        return switch (self.control.mode) {
            .unknown => self.pollUnknown(output, wake),
            .exact_zero => .{ .done = &.{} },
            .failure => error.ProducerFailed,
            .waiting => self.wait(wake),
            .cycling => self.pollCycling(output, wake),
            .large => self.pollLarge(output),
        };
    }

    pub fn abort(self: *Producer) void {
        if (self.control.race) |race| {
            race.abort_after_invalidation = wakeInvalidated(race.wake);
            race.stop.store(true, .release);
        }
        self.control.aborts += 1;
        self.control.mark('A');
    }

    pub fn join(self: *Producer) void {
        if (self.control.race) |race| {
            race.join_after_invalidation = wakeInvalidated(race.wake);
            while (!race.done.load(.acquire)) std.Thread.yield() catch {};
        }
        self.control.joins += 1;
        self.control.mark('J');
    }

    pub fn pollUnknown(
        self: *Producer,
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollResult {
        const step = self.control.step;
        self.control.step += 1;
        return switch (step) {
            0 => progress(output, "hello"),
            1 => self.wait(wake),
            else => .{ .done = &trailer_fields },
        };
    }

    pub fn wait(self: *Producer, wake: response_stream.Wake) response_stream.PollResult {
        self.control.wake = wake;
        return .pending;
    }

    pub fn pollCycling(
        self: *Producer,
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollResult {
        const step = self.control.step;
        self.control.step += 1;
        if (step == 64) return .{ .done = &.{} };
        if (step & 1 == 0) {
            @memset(output, 'p');
            return self.wait(wake);
        }
        return progress(output, "x");
    }

    pub fn pollLarge(self: *Producer, output: []u8) response_stream.PollResult {
        const step = self.control.step;
        self.control.step += 1;
        if (step != 0) {
            @memset(output, 's');
            return .{ .done = &.{} };
        }
        @memset(output[0..256], 'x');
        return .{ .progress = 256 };
    }
};

pub fn progress(output: []u8, value: []const u8) response_stream.PollResult {
    std.debug.assert(value.len <= output.len);
    @memcpy(output[0..value.len], value);
    return .{ .progress = value.len };
}

pub fn wakeInvalidated(wake: response_stream.Wake) bool {
    const runtime: *worker_stream_wake.StreamWake = @ptrCast(@alignCast(wake.context));
    return runtime.notify() == .stale;
}

pub const Observe = struct {
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

pub fn unknown(context: *TestContext) StreamResponse {
    return context.streamUnknown(
        .ok,
        response.media.text,
        Producer{ .control = &context.state.producer },
        &trailer_names,
    );
}

pub fn exactZero(context: *TestContext) StreamResponse {
    return context.streamExact(
        .ok,
        response.media.text,
        0,
        Producer{ .control = &context.state.producer },
    );
}

pub fn failure(context: *TestContext) StreamResponse {
    return context.streamUnknown(
        .ok,
        response.media.text,
        Producer{ .control = &context.state.producer },
        &.{},
    );
}

pub const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{
        route.get("/unknown", unknown),
        route.get("/exact", exactZero),
        route.get("/failure", failure),
        route.get("/cancel", failure),
        route.get("/cors", unknown).withCors(cors.allow_any),
    },
});

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 2,
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

pub const TestStorage = worker_storage.Storage(TestApp, test_limits);
pub const TestReactor = deterministic_reactor.DeterministicReactor(128);
pub const TestDriver = connection_driver.Driver(TestApp, TestStorage, TestReactor);
pub const TestResponseTransport = connection_response_transport.Transport(
    TestApp,
    TestStorage,
    connection_driver.Error,
);

pub const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    driver: TestDriver = undefined,
    wire: [4096]u8 = undefined,
    wire_len: usize = 0,
    now_ns: u64 = 1,
    buffer_generation: u16 = 1,

    pub fn init(self: *Harness, mode: Mode) !void {
        self.io = .{};
        self.state = .{ .producer = .{ .mode = mode } };
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
        self.wire_len = 0;
        self.now_ns = 1;
        self.buffer_generation = 1;
    }

    pub fn deinit(self: *Harness) void {
        self.storage.stream_wakes.confirmPublishersJoined() catch unreachable;
        self.storage.stream_wakes.beginFatalAfterPublishersJoined() catch unreachable;
        const status = self.io.abort() catch unreachable;
        std.debug.assert(status.ownership_proven);
        self.storage.stream_wakes.finishFatalAfterBackend() catch unreachable;
    }

    pub fn addConnection(self: *Harness, socket: u64) !u16 {
        const index = self.storage.acquireConnection(.{ .value = socket }) orelse {
            return error.TestUnexpectedResult;
        };
        try self.driver.start(index, self.now_ns);
        return index;
    }

    pub fn receive(self: *Harness, connection_index: u16, bytes: []const u8) !void {
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

    pub fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
    ) !connection_driver.Disposition {
        try self.io.complete(token, result, false);
        const completion = self.io.nextCompletion() orelse {
            return error.TestUnexpectedResult;
        };
        return self.driver.handle(completion, self.now_ns);
    }

    pub fn drainSends(self: *Harness, connection_index: u16, part: usize) !void {
        var iterations: u16 = 0;
        while (self.storage.connections[connection_index].send_token != null) {
            if (iterations == 512) return error.TestUnexpectedResult;
            iterations += 1;
            const bytes = self.sendBytes(connection_index);
            const count = @min(part, bytes.len);
            try self.appendWire(bytes[0..count]);
            const token = self.storage.connections[connection_index].send_token.?;
            _ = try self.complete(token, .{ .success = .{ .send = @intCast(count) } });
        }
    }

    pub fn dispatchWake(self: *Harness, request_index: u16) !void {
        try self.publishWake(request_index);
        try self.retireParkedTimeout(request_index);
    }

    pub fn publishWake(self: *Harness, request_index: u16) !void {
        self.state.producer.wake.?.notify();
        const token = self.storage.stream_wakes.currentPollToken() orelse {
            return error.TestUnexpectedResult;
        };
        try self.io.complete(token, .{ .success = .{ .wake = {} } }, false);
        const completion = self.io.nextCompletion() orelse {
            return error.TestUnexpectedResult;
        };
        const event = try self.storage.stream_wakes.handle(&self.io, completion);
        try std.testing.expect(event.ready.contains(request_index));
        try self.driver.handleStreamReady(request_index, self.now_ns);
    }

    pub fn retireParkedTimeout(self: *Harness, request_index: u16) !void {
        const connection_index = self.storage.requests[request_index].connection_index;
        const timeout = self.storage.connections[connection_index].timeout_token orelse {
            return error.TestUnexpectedResult;
        };
        const cancel = self.findCancel(timeout) orelse return error.TestUnexpectedResult;
        _ = try self.complete(cancel, .{ .success = .{ .cancel = .canceled } });
        _ = try self.complete(timeout, .{ .failure = .canceled });
    }

    pub fn findCancel(
        self: *const Harness,
        target: reactor.OperationToken,
    ) ?reactor.OperationToken {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if (submission.operation != .cancel) continue;
            if (submission.operation.cancel.target.eql(target)) return submission.token;
        }
        return null;
    }

    pub fn cancelCountFor(
        self: *const Harness,
        target: reactor.OperationToken,
    ) u16 {
        var count: u16 = 0;
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if (submission.operation != .cancel) continue;
            count += @intFromBool(submission.operation.cancel.target.eql(target));
        }
        return count;
    }

    pub fn expireCurrentTimeout(self: *Harness, connection_index: u16) !void {
        const connection = &self.storage.connections[connection_index];
        const timeout = connection.timeout_token orelse return error.TestUnexpectedResult;
        self.now_ns = connection.timeout_deadline_ns;
        _ = try self.complete(timeout, .{ .success = .{ .timeout = {} } });
    }

    pub fn sendBytes(self: *const Harness, connection_index: u16) []const u8 {
        const token = self.storage.connections[connection_index].send_token.?;
        return self.io.operation(token).?.send.bytes;
    }

    pub fn appendWire(self: *Harness, bytes: []const u8) !void {
        const end = self.wire_len + bytes.len;
        if (end > self.wire.len) return error.TestUnexpectedResult;
        @memcpy(self.wire[self.wire_len..end], bytes);
        self.wire_len = end;
    }

    pub fn written(self: *const Harness) []const u8 {
        return self.wire[0..self.wire_len];
    }
};

pub fn expectCorsHead(bytes: []const u8) !void {
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "access-control-allow-origin: *\r\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, bytes, "vary: Origin\r\n") != null);
}

pub fn expectBodyFirstCause(
    receive_more: bool,
    expected: application.TransportOutcome,
) !void {
    var harness: Harness = undefined;
    try harness.init(.unknown);
    defer harness.deinit();
    const connection = try harness.addConnection(if (receive_more) 64 else 63);
    try harness.receive(connection, unknown_request);
    const head = harness.storage.connections[connection].send_token.?;
    const head_bytes = harness.sendBytes(connection).len;
    _ = try harness.complete(head, .{ .success = .{ .send = @intCast(head_bytes) } });
    const body_send = harness.storage.connections[connection].send_token.?;
    const body_bytes_count = harness.sendBytes(connection).len;

    if (receive_more) {
        try TestResponseTransport.cancelStream(
            &harness.driver,
            connection,
            .peer_aborted,
            harness.now_ns,
        );
        _ = try harness.driver.stop(connection);
        try harness.expireCurrentTimeout(connection);
    } else {
        try harness.expireCurrentTimeout(connection);
        _ = try harness.driver.stop(connection);
    }
    _ = try harness.complete(
        body_send,
        .{ .success = .{ .send = @intCast(body_bytes_count) } },
    );
    try std.testing.expectEqual(expected, harness.state.last_transport);
    try std.testing.expectEqualStrings("AJO", harness.state.producer.written());
}

pub fn expectLargeChunkScrub(send_failure: bool) !void {
    var harness: Harness = undefined;
    try harness.init(.large);
    defer harness.deinit();
    const connection = try harness.addConnection(if (send_failure) 66 else 65);
    try harness.receive(connection, failure_request);
    const request_index = harness.storage.connections[connection].active_request.?;
    if (send_failure) {
        const head = harness.storage.connections[connection].send_token.?;
        const head_bytes = harness.sendBytes(connection).len;
        _ = try harness.complete(head, .{ .success = .{ .send = @intCast(head_bytes) } });
        const body_send = harness.storage.connections[connection].send_token.?;
        _ = try harness.complete(body_send, .{ .failure = .broken_pipe });
    } else {
        try harness.drainSends(connection, 4096);
    }
    const region = harness.storage.responseRegion(request_index);
    const cleared = if (send_failure) region[0..263] else region;
    for (cleared) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub const RaceEnd = enum { stop, timeout };

pub fn expectWakeCancellationRace(end: RaceEnd) !void {
    var harness: Harness = undefined;
    try harness.init(if (end == .stop) .waiting else .cycling);
    defer harness.deinit();
    const connection = try harness.addConnection(if (end == .stop) 67 else 68);
    try harness.receive(connection, if (end == .stop) cancel_request else failure_request);
    try harness.drainSends(connection, 4096);
    const request = harness.storage.connections[connection].active_request.?;
    if (end == .timeout) try harness.dispatchWake(request);

    var race = WakeRace{ .wake = harness.state.producer.wake.? };
    harness.state.producer.race = &race;
    const thread = try std.Thread.spawn(.{}, WakeRace.run, .{&race});
    defer {
        race.stop.store(true, .release);
        thread.join();
    }
    race.go.store(true, .release);
    while (race.notifications.load(.acquire) == 0) std.Thread.yield() catch {};

    if (end == .stop) {
        _ = try harness.driver.stop(connection);
    } else {
        const send_token = harness.storage.connections[connection].send_token.?;
        const send_len = harness.sendBytes(connection).len;
        try harness.expireCurrentTimeout(connection);
        _ = try harness.complete(send_token, .{ .success = .{ .send = @intCast(send_len) } });
    }
    try std.testing.expect(race.done.load(.acquire));
    try std.testing.expect(race.abort_after_invalidation);
    try std.testing.expect(race.join_after_invalidation);
    try std.testing.expectEqualStrings("AJO", harness.state.producer.written());
    const polls = harness.state.producer.polls;
    const aborts = harness.state.producer.aborts;
    const joins = harness.state.producer.joins;

    const poll = harness.storage.stream_wakes.currentPollToken().?;
    try harness.io.complete(poll, .{ .success = .{ .wake = {} } }, false);
    const completion = harness.io.nextCompletion().?;
    const event = try harness.storage.stream_wakes.handle(&harness.io, completion);
    try std.testing.expect(event.ready.contains(request));
    for (0..8) |_| try harness.driver.handleStreamReady(request, harness.now_ns);
    try std.testing.expectEqual(polls, harness.state.producer.polls);
    try std.testing.expectEqual(aborts, harness.state.producer.aborts);
    try std.testing.expectEqual(joins, harness.state.producer.joins);
    try std.testing.expectEqual(
        if (end == .stop) application.TransportOutcome.framework_canceled else .write_stalled,
        harness.state.last_transport,
    );
}

test {
    _ = @import("connection_stream_driver_test_part_1.zig");
}

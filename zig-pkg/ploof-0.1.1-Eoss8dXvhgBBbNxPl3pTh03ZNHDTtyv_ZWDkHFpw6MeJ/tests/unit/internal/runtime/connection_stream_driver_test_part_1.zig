const source = @import("connection_stream_driver_test.zig");
const std = source.std;
const application = source.application;
const cors = source.cors;
const response = source.response;
const response_stream = source.response_stream;
const route = source.route;
const config = source.config;
const connection_driver = source.connection_driver;
const connection_response_transport = source.connection_response_transport;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_stream_wake = source.worker_stream_wake;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const unknown_request = source.unknown_request;
const exact_request = source.exact_request;
const failure_request = source.failure_request;
const cancel_request = source.cancel_request;
const cors_request = source.cors_request;
const head_request = source.head_request;
const trailer_names = source.trailer_names;
const trailer_fields = source.trailer_fields;
const Mode = source.Mode;
const WakeRace = source.WakeRace;
const ProducerControl = source.ProducerControl;
const TestState = source.TestState;
const TestContext = source.TestContext;
const StreamResponse = source.StreamResponse;
const Producer = source.Producer;
const progress = source.progress;
const wakeInvalidated = source.wakeInvalidated;
const Observe = source.Observe;
const unknown = source.unknown;
const exactZero = source.exactZero;
const failure = source.failure;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const TestDriver = source.TestDriver;
const TestResponseTransport = source.TestResponseTransport;
const Harness = source.Harness;
const expectCorsHead = source.expectCorsHead;
const expectBodyFirstCause = source.expectBodyFirstCause;
const expectLargeChunkScrub = source.expectLargeChunkScrub;
const RaceEnd = source.RaceEnd;
const expectWakeCancellationRace = source.expectWakeCancellationRace;

test "unknown stream preserves partial head body wake and terminal ordering" {
    var harness: Harness = undefined;
    try harness.init(.unknown);
    defer harness.deinit();
    const connection = try harness.addConnection(10);
    try harness.receive(connection, unknown_request);
    const request = harness.storage.connections[connection].active_request.?;

    try harness.drainSends(connection, 3);
    try std.testing.expectEqual(@as(u8, 2), harness.state.producer.polls);
    try std.testing.expect(harness.state.producer.wake != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.written(), "5\r\nhello\r\n"));
    try std.testing.expect(
        std.mem.indexOf(u8, harness.written(), "transfer-encoding: chunked\r\n") != null,
    );

    try harness.dispatchWake(request);
    try harness.drainSends(connection, 2);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.written(),
        "0\r\nx-checksum: done\r\n\r\n",
    ));
    try std.testing.expectEqual(
        @as(?u16, null),
        harness.storage.connections[connection].active_request,
    );
    try std.testing.expectEqual(@as(u8, 3), harness.state.producer.polls);
    try std.testing.expectEqualStrings("JO", harness.state.producer.written());
    try std.testing.expectEqual(
        application.TransportOutcome.completed,
        harness.state.last_transport,
    );
    for (harness.storage.responseRegion(request)) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "stream CORS head survives completion and abort lifecycle" {
    var completed: Harness = undefined;
    try completed.init(.unknown);
    defer completed.deinit();
    const completed_connection = try completed.addConnection(11);
    try completed.receive(completed_connection, cors_request);
    try expectCorsHead(completed.sendBytes(completed_connection));
    const request = completed.storage.connections[completed_connection].active_request.?;
    try completed.drainSends(completed_connection, 7);
    try completed.dispatchWake(request);
    try completed.drainSends(completed_connection, 7);
    try std.testing.expectEqual(@as(u8, 1), completed.state.after_calls);
    try std.testing.expectEqual(
        application.TransportOutcome.completed,
        completed.state.last_transport,
    );

    var aborted: Harness = undefined;
    try aborted.init(.waiting);
    defer aborted.deinit();
    const aborted_connection = try aborted.addConnection(12);
    try aborted.receive(aborted_connection, cors_request);
    try expectCorsHead(aborted.sendBytes(aborted_connection));
    try aborted.drainSends(aborted_connection, 7);
    _ = try aborted.driver.stop(aborted_connection);
    try std.testing.expectEqual(@as(u8, 1), aborted.state.after_calls);
    try std.testing.expectEqual(
        application.TransportOutcome.framework_canceled,
        aborted.state.last_transport,
    );
}

test "exact zero polls canary and completes without body send" {
    var harness: Harness = undefined;
    try harness.init(.exact_zero);
    defer harness.deinit();
    const connection = try harness.addConnection(20);
    try harness.receive(connection, exact_request);
    try harness.drainSends(connection, 5);

    try std.testing.expect(
        std.mem.indexOf(u8, harness.written(), "content-length: 0\r\n") != null,
    );
    try std.testing.expectEqual(@as(u8, 1), harness.state.producer.polls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.producer.joins);
    try std.testing.expectEqual(@as(u8, 0), harness.state.producer.aborts);
    try std.testing.expectEqualStrings("JO", harness.state.producer.written());
}

test "HEAD suppresses producer without activating stream wake" {
    var harness: Harness = undefined;
    try harness.init(.unknown);
    defer harness.deinit();
    const connection = try harness.addConnection(30);
    try harness.receive(connection, head_request);

    try std.testing.expectEqual(
        @as(u16, 0),
        harness.storage.stream_wakes.status().active_publishers,
    );
    try harness.drainSends(connection, 4);
    try std.testing.expectEqual(@as(u8, 0), harness.state.producer.polls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.producer.joins);
    try std.testing.expectEqualStrings("JO", harness.state.producer.written());
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        harness.state.last_transport,
    );
}

test "producer failure retains detailed outcome before close" {
    var harness: Harness = undefined;
    try harness.init(.failure);
    defer harness.deinit();
    const connection = try harness.addConnection(40);
    try harness.receive(connection, failure_request);
    try harness.drainSends(connection, 7);

    try std.testing.expectEqual(
        application.TransportOutcome.producer_failed,
        harness.state.last_transport,
    );
    try std.testing.expectEqualStrings("AJO", harness.state.producer.written());
    try std.testing.expectEqual(
        @as(?u16, null),
        harness.storage.connections[connection].active_request,
    );
    try std.testing.expectEqual(.closing, harness.storage.connections[connection].phase);
    try std.testing.expect(harness.storage.connections[connection].close_token != null);
}

test "stop invalidates aborts joins and reports before close submission" {
    var harness: Harness = undefined;
    try harness.init(.waiting);
    defer harness.deinit();
    const connection = try harness.addConnection(50);
    try harness.receive(connection, cancel_request);
    try harness.drainSends(connection, 6);
    try std.testing.expect(harness.state.producer.wake != null);

    _ = try harness.driver.stop(connection);
    try std.testing.expectEqualStrings("AJO", harness.state.producer.written());
    try std.testing.expectEqual(
        application.TransportOutcome.framework_canceled,
        harness.state.last_transport,
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        harness.storage.stream_wakes.status().active_publishers,
    );
    try std.testing.expectEqual(
        @as(?u16, null),
        harness.storage.connections[connection].active_request,
    );
    try std.testing.expect(harness.storage.connections[connection].close_token != null);
}

test "wake pending cycles keep one tracked timeout cancellation" {
    var harness: Harness = undefined;
    try harness.init(.cycling);
    defer harness.deinit();
    const connection = try harness.addConnection(60);
    try harness.receive(connection, failure_request);
    const request_index = harness.storage.connections[connection].active_request.?;
    try harness.drainSends(connection, 4096);

    for (0..32) |cycle| {
        const timeout = harness.storage.connections[connection].timeout_token.?;
        const inflight = harness.storage.connections[connection].inflight_operations;
        try std.testing.expectEqual(@as(u16, 1), harness.cancelCountFor(timeout));
        try harness.publishWake(request_index);
        for (0..32) |_| {
            try harness.driver.handleStreamReady(request_index, harness.now_ns);
        }
        try std.testing.expectEqual(
            inflight,
            harness.storage.connections[connection].inflight_operations,
        );
        try std.testing.expectEqual(@as(u16, 1), harness.cancelCountFor(timeout));
        try harness.retireParkedTimeout(request_index);
        try harness.drainSends(connection, 4096);
        if (cycle != 31) {
            try std.testing.expectEqual(
                request_index,
                harness.storage.connections[connection].active_request.?,
            );
            try std.testing.expect(
                harness.storage.connections[connection].inflight_operations <= 4,
            );
        }
    }

    try std.testing.expectEqual(@as(u8, 65), harness.state.producer.polls);
    try std.testing.expectEqualStrings("JO", harness.state.producer.written());
    try std.testing.expectEqual(
        application.TransportOutcome.completed,
        harness.state.last_transport,
    );
    for (harness.storage.responseRegion(request_index)) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "full terminal and suppressed HEAD sends win an earlier timeout" {
    var terminal: Harness = undefined;
    try terminal.init(.unknown);
    defer terminal.deinit();
    const terminal_connection = try terminal.addConnection(61);
    try terminal.receive(terminal_connection, unknown_request);
    const request_index = terminal.storage.connections[terminal_connection].active_request.?;
    try terminal.drainSends(terminal_connection, 4096);
    try terminal.dispatchWake(request_index);
    const terminal_send = terminal.storage.connections[terminal_connection].send_token.?;
    const terminal_bytes = terminal.sendBytes(terminal_connection).len;
    try terminal.expireCurrentTimeout(terminal_connection);
    _ = try terminal.complete(
        terminal_send,
        .{ .success = .{ .send = @intCast(terminal_bytes) } },
    );
    try std.testing.expectEqual(
        application.TransportOutcome.completed,
        terminal.state.last_transport,
    );
    try std.testing.expectEqualStrings("JO", terminal.state.producer.written());

    var head: Harness = undefined;
    try head.init(.unknown);
    defer head.deinit();
    const head_connection = try head.addConnection(62);
    try head.receive(head_connection, head_request);
    const head_send = head.storage.connections[head_connection].send_token.?;
    const head_bytes = head.sendBytes(head_connection).len;
    try head.expireCurrentTimeout(head_connection);
    _ = try head.complete(head_send, .{ .success = .{ .send = @intCast(head_bytes) } });
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        head.state.last_transport,
    );
    try std.testing.expectEqualStrings("JO", head.state.producer.written());
}

test "active body send retains first timeout or peer failure" {
    try expectBodyFirstCause(false, .write_stalled);
    try expectBodyFirstCause(true, .peer_aborted);
}

test "stream release scrubs largest successful and failed chunk" {
    try expectLargeChunkScrub(false);
    try expectLargeChunkScrub(true);
}

test "producer wake racing timeout or stop is ThreadSanitizer clean" {
    try expectWakeCancellationRace(.stop);
    try expectWakeCancellationRace(.timeout);
}

test {
    std.testing.refAllDecls(@This());
}

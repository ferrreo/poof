const source = @import("connection_driver_test.zig");
const std = source.std;
const builtin = source.builtin;
const application = source.application;
const address = source.address;
const forwarding = source.forwarding;
const response = source.response;
const route = source.route;
const buffer_ring = source.buffer_ring;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const io_uring_backend = source.io_uring_backend;
const reactor = source.reactor;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const ping_request = source.ping_request;
const proxy_signature = source.proxy_signature;
const proxy_tcp4_payload = source.proxy_tcp4_payload;
const proxy_tcp4 = source.proxy_tcp4;
const proxy_tcp6_payload = source.proxy_tcp6_payload;
const proxy_tcp6 = source.proxy_tcp6;
const proxy_local = source.proxy_local;
const request_timeout_response = source.request_timeout_response;
const TestState = source.TestState;
const TestContext = source.TestContext;
const Observe = source.Observe;
const ping = source.ping;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const test_forwarding_limits = source.test_forwarding_limits;
const TestForwardingProfile = source.TestForwardingProfile;
const TestDriver = source.TestDriver;
const undersized_limits = source.undersized_limits;
const UndersizedStorage = source.UndersizedStorage;
const UndersizedDriver = source.UndersizedDriver;
const Harness = source.Harness;
const initRequiredProxy = source.initRequiredProxy;
const expectSilentClosing = source.expectSilentClosing;

test "one-shot malformed rejection has no receive open for racing ingress" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(70);
    const malformed =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Length: nope\r\n\r\n";
    _ = try harness.receive(connection_index, malformed, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    const response_length = harness.sendBytes(connection_index).len;
    const pipeline_write = harness.storage.connections[connection_index].pipeline_write;
    try std.testing.expect(harness.storage.connections[connection_index].receive_token == null);
    try std.testing.expectEqual(
        pipeline_write,
        harness.storage.connections[connection_index].pipeline_write,
    );
    try std.testing.expectEqual(response_length, harness.sendBytes(connection_index).len);
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(response_length) } },
        false,
    );
    try std.testing.expect(harness.storage.connections[connection_index].send_token == null);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
}

test "partial send completion after timeout cannot restart closing response" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(80);
    _ = try harness.receive(connection_index, ping_request, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );

    _ = try harness.complete(send, .{ .success = .{ .send = 7 } }, false);
    try std.testing.expect(harness.storage.connections[connection_index].send_token == null);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
}

test "full send success racing timeout still completes application lifecycle" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(81);
    _ = try harness.receive(connection_index, ping_request, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    const response_length = harness.sendBytes(connection_index).len;
    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(response_length) } },
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
}

test "bytes delivered after full send become next keepalive request" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(90);
    _ = try harness.receive(connection_index, ping_request, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try std.testing.expect(
        harness.storage.connections[connection_index].active_request == null,
    );

    try harness.cancelCurrentTimeout(connection_index);
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
    try harness.drainRetirements(connection_index);
    _ = try harness.receive(connection_index, ping_request, false);
    try std.testing.expectEqual(@as(u16, 2), harness.state.calls);
    try std.testing.expect(
        harness.storage.connections[connection_index].send_token != null,
    );
}

test "retargeted keepalive timeout rearms when original deadline expires" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(93);
    const original = harness.storage.connections[connection_index].timeout_token.?;
    const original_deadline = harness.io.operation(original).?.timeout.deadline_ns;
    _ = try harness.receive(connection_index, ping_request, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    const extended_deadline = harness.storage.connections[connection_index].timeout_deadline_ns;
    try std.testing.expect(original_deadline < extended_deadline);
    try std.testing.expect(
        harness.storage.connections[connection_index].timeout_token.?.eql(original),
    );

    harness.now_ns = original_deadline;
    _ = try harness.complete(original, .{ .success = .{ .timeout = {} } }, false);
    const rearmed = harness.storage.connections[connection_index].timeout_token.?;
    try std.testing.expect(!rearmed.eql(original));
    try std.testing.expectEqual(
        extended_deadline,
        harness.io.operation(rearmed).?.timeout.deadline_ns,
    );
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expect(harness.storage.connections[connection_index].close_token == null);
}

test "partial send progress keeps one timer and rearms only when it expires" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(91);
    _ = try harness.receive(connection_index, ping_request, false);
    const write_timeout = harness.storage.connections[connection_index].timeout_token.?;
    const active_count = harness.io.activeCount();
    harness.now_ns = 50;
    for (0..8) |_| {
        const send = harness.storage.connections[connection_index].send_token.?;
        _ = try harness.complete(send, .{ .success = .{ .send = 1 } }, false);
        try std.testing.expectEqual(active_count, harness.io.activeCount());
        try std.testing.expect(
            harness.storage.connections[connection_index].timeout_token.?
                .eql(write_timeout),
        );
    }
    try std.testing.expectEqual(
        @as(u64, 150),
        harness.storage.connections[connection_index].timeout_deadline_ns,
    );

    harness.now_ns = 101;
    _ = try harness.complete(write_timeout, .{ .success = .{ .timeout = {} } }, false);
    const rearmed = harness.storage.connections[connection_index].timeout_token.?;
    try std.testing.expect(!rearmed.eql(write_timeout));
    try std.testing.expectEqual(
        @as(u64, 150),
        harness.io.operation(rearmed).?.timeout.deadline_ns,
    );
    try std.testing.expectEqual(active_count, harness.io.activeCount());
}

test "stop is idempotent and aborts only after active send retires" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(92);
    _ = try harness.receive(connection_index, ping_request, false);
    try std.testing.expectEqual(
        connection_driver.Disposition.retained,
        try harness.driver.stop(connection_index),
    );
    try std.testing.expectEqual(
        connection_driver.Disposition.retained,
        try harness.driver.stop(connection_index),
    );
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
    try std.testing.expectEqual(
        connection_driver.Disposition.released,
        try harness.driver.stop(connection_index),
    );
}

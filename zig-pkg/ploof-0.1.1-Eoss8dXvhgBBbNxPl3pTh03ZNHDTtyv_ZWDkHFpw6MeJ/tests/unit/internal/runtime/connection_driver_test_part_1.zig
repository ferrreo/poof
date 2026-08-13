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

test "required PROXY v2 TCP4 handles every preface split before HTTP" {
    const wire = proxy_tcp4 ++ ping_request.*;
    const transport = address.Endpoint.initIpv4(.{ 10, 1, 2, 3 }, 40_000);
    const claimed = address.Endpoint.initIpv4(.{ 203, 0, 113, 9 }, 54_321);
    for (0..proxy_tcp4.len + 1) |split| {
        var harness: Harness = undefined;
        try initRequiredProxy(&harness, &.{"10.0.0.0/8"});
        const connection_index = try harness.addAcceptedConnection(100, transport);
        if (split != 0) {
            _ = try harness.receive(connection_index, wire[0..split], false);
            try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
        }
        _ = try harness.receive(connection_index, wire[split..], false);
        const connection = harness.storage.connections[connection_index];
        try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
        try std.testing.expect(connection.transport_peer.eql(transport));
        try std.testing.expect(connection.connection_peer.eql(claimed));
        try std.testing.expect(connection.proxy_destination.?.eql(
            address.Endpoint.initIpv4(.{ 198, 51, 100, 7 }, 80),
        ));
        try std.testing.expectEqual(
            forwarding.ConnectionSource.proxy_protocol_v2,
            connection.connection_source,
        );
        try std.testing.expect(harness.state.client.?.eql(claimed));
        try std.testing.expectEqual(
            forwarding.ConnectionSource.proxy_protocol_v2,
            harness.state.connection_source.?,
        );
    }
}

test "PROXY v2 transport applies trusted origin fields before absolute-form dispatch" {
    var harness: Harness = undefined;
    try harness.initForwarding(.{
        .proxy_protocol = .v2_required,
        .family = .forwarded,
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    const connection_index = try harness.addAcceptedConnection(
        110,
        address.Endpoint.initIpv4(.{ 10, 3, 4, 5 }, 40_008),
    );
    const request =
        "GET https://public.test/ping HTTP/1.1\r\nHost: internal.test\r\n" ++
        "Forwarded: for=198.51.100.7;proto=https;host=public.test\r\n\r\n";
    _ = try harness.receive(connection_index, &(proxy_tcp4 ++ request.*), false);
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
    try std.testing.expectEqual(forwarding.Scheme.https, harness.state.scheme.?);
    try std.testing.expectEqual(
        forwarding.ConnectionSource.proxy_protocol_v2,
        harness.state.connection_source.?,
    );
    try std.testing.expect(harness.state.client.?.eql(
        address.Endpoint.initIpv4(.{ 203, 0, 113, 9 }, 54_321),
    ));
}

test "required PROXY v2 accepts coalesced TCP6 and opaque LOCAL" {
    const transport6 = address.Endpoint.initIpv6(
        .{ 0x20, 1, 0x0d, 0xb8, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        40_001,
    );
    var ipv6: Harness = undefined;
    try initRequiredProxy(&ipv6, &.{"2001:db8:ffff::/48"});
    const ipv6_index = try ipv6.addAcceptedConnection(101, transport6);
    _ = try ipv6.receive(ipv6_index, &(proxy_tcp6 ++ ping_request.*), false);
    try std.testing.expect(ipv6.storage.connections[ipv6_index].connection_peer.eql(
        address.Endpoint.initIpv6(proxy_tcp6_payload[0..16].*, 443),
    ));
    try std.testing.expectEqual(
        forwarding.ConnectionSource.proxy_protocol_v2,
        ipv6.storage.connections[ipv6_index].connection_source,
    );

    const transport4 = address.Endpoint.initIpv4(.{ 10, 9, 8, 7 }, 40_002);
    var local: Harness = undefined;
    try initRequiredProxy(&local, &.{"10.0.0.0/8"});
    const local_index = try local.addAcceptedConnection(102, transport4);
    _ = try local.receive(local_index, &(proxy_local ++ ping_request.*), false);
    const local_connection = local.storage.connections[local_index];
    try std.testing.expect(local_connection.connection_peer.eql(transport4));
    try std.testing.expectEqual(
        forwarding.ConnectionSource.proxy_protocol_v2_local,
        local_connection.connection_source,
    );
    try std.testing.expectEqual(@as(u16, 1), local.state.calls);
}

test "required PROXY v2 rejects untrusted transport before reading claims" {
    var harness: Harness = undefined;
    try initRequiredProxy(&harness, &.{"10.0.0.0/8"});
    const connection_index = try harness.addAcceptedConnection(
        103,
        address.Endpoint.initIpv4(.{ 192, 0, 2, 44 }, 40_003),
    );
    const connection = harness.storage.connections[connection_index];
    try expectSilentClosing(&harness, connection_index);
    try std.testing.expect(connection.receive_token == null);
    try std.testing.expect(connection.timeout_token == null);
    try std.testing.expect(connection.close_token != null);

    var disabled: Harness = undefined;
    try disabled.initForwarding(.{
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    const disabled_index = try disabled.addAcceptedConnection(
        109,
        address.Endpoint.initIpv4(.{ 192, 0, 2, 45 }, 40_007),
    );
    try expectSilentClosing(&disabled, disabled_index);
    try std.testing.expect(disabled.storage.connections[disabled_index].receive_token == null);
}

test "required PROXY v2 malformed EOF and timeout paths close silently" {
    const transport = address.Endpoint.initIpv4(.{ 10, 1, 1, 1 }, 40_004);

    var malformed: Harness = undefined;
    try initRequiredProxy(&malformed, &.{"10.0.0.0/8"});
    const malformed_index = try malformed.addAcceptedConnection(104, transport);
    _ = try malformed.receive(malformed_index, "X", false);
    try expectSilentClosing(&malformed, malformed_index);

    var eof: Harness = undefined;
    try initRequiredProxy(&eof, &.{"10.0.0.0/8"});
    const eof_index = try eof.addAcceptedConnection(105, transport);
    _ = try eof.receive(eof_index, proxy_signature[0..5], false);
    const eof_receive = eof.storage.connections[eof_index].receive_token.?;
    _ = try eof.complete(
        eof_receive,
        .{ .success = .{ .receive = .end_of_stream } },
        false,
    );
    try expectSilentClosing(&eof, eof_index);

    var timeout: Harness = undefined;
    try initRequiredProxy(&timeout, &.{"10.0.0.0/8"});
    const timeout_index = try timeout.addAcceptedConnection(106, transport);
    _ = try timeout.receive(timeout_index, proxy_signature[0..5], false);
    const timeout_token = timeout.storage.connections[timeout_index].timeout_token.?;
    timeout.now_ns = timeout.storage.connections[timeout_index].timeout_deadline_ns;
    _ = try timeout.complete(timeout_token, .{ .success = .{ .timeout = {} } }, false);
    try expectSilentClosing(&timeout, timeout_index);
}

test "disabled PROXY v2 never sniffs a signature" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addAcceptedConnection(
        107,
        address.Endpoint.initIpv4(.{ 192, 0, 2, 10 }, 40_005),
    );
    _ = try harness.receive(connection_index, &(proxy_tcp4 ++ ping_request.*), false);
    const connection = harness.storage.connections[connection_index];
    try std.testing.expectEqual(
        forwarding.ConnectionSource.transport,
        connection.connection_source,
    );
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
    try std.testing.expect(connection.send_token != null);
}

test "PROXY v2 connection identity survives keepalive without another preface" {
    var harness: Harness = undefined;
    try initRequiredProxy(&harness, &.{"10.0.0.0/8"});
    const connection_index = try harness.addAcceptedConnection(
        108,
        address.Endpoint.initIpv4(.{ 10, 2, 3, 4 }, 40_006),
    );
    _ = try harness.receive(connection_index, &(proxy_tcp4 ++ ping_request.*), false);
    const expected_peer = harness.storage.connections[connection_index].connection_peer;
    const expected_destination = harness.storage.connections[connection_index].proxy_destination;
    const send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try harness.cancelCurrentTimeout(connection_index);
    try harness.drainRetirements(connection_index);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[connection_index].phase,
    );
    _ = try harness.receive(connection_index, ping_request, false);
    const connection = harness.storage.connections[connection_index];
    try std.testing.expectEqual(@as(u16, 2), harness.state.calls);
    try std.testing.expect(connection.connection_peer.eql(expected_peer));
    try std.testing.expect(connection.proxy_destination.?.eql(expected_destination.?));
    try std.testing.expectEqual(
        forwarding.ConnectionSource.proxy_protocol_v2,
        connection.connection_source,
    );
}

test "fragmented pipeline reuses timeout and recycles every receive buffer" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(10);
    const receive_token = harness.storage.connections[connection_index].receive_token.?;
    const first_timeout = harness.storage.connections[connection_index].timeout_token.?;

    try std.testing.expect(!harness.io.operation(receive_token).?.receive.multishot);
    _ = try harness.receive(connection_index, "GET /pi", false);
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
    _ = try harness.receive(
        connection_index,
        "ng HTTP/1.1\r\nHost: example.test\r\n\r\n" ++ ping_request,
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
    try std.testing.expectEqual(@as(u64, 2), harness.io.recycledCount());
    try std.testing.expect(std.mem.endsWith(u8, harness.sendBytes(connection_index), "pong"));

    const first_send = harness.storage.connections[connection_index].send_token.?;
    const first_wire = harness.sendBytes(connection_index);
    _ = try harness.complete(first_send, .{ .success = .{ .send = 7 } }, false);
    try std.testing.expectEqualStrings(first_wire[7..], harness.sendBytes(connection_index));
    try std.testing.expectEqual(@as(u16, 0), harness.state.completed);
    const rest_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        rest_send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u16, 2), harness.state.calls);
    try std.testing.expectEqual(
        first_timeout,
        harness.storage.connections[connection_index].timeout_token.?,
    );
    const second_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        second_send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try harness.cancelCurrentTimeout(connection_index);
    try harness.drainRetirements(connection_index);
    try std.testing.expectEqual(@as(u16, 2), harness.state.completed);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[connection_index].phase,
    );

    try std.testing.expect(harness.io.operation(first_timeout) == null);
    try std.testing.expect(harness.io.operation(receive_token) == null);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
}

test "transport failure waits for reordered terminals and aborts exactly once" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(20);
    _ = try harness.receive(connection_index, ping_request, false);
    const send_token = harness.storage.connections[connection_index].send_token.?;

    _ = try harness.complete(send_token, .{ .failure = .broken_pipe }, false);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );

    const close_token = harness.storage.connections[connection_index].close_token.?;
    _ = try harness.complete(close_token, .{ .success = .{ .close = {} } }, false);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);

    const stale = reactor.OperationToken.init(.{
        .kind = .cancel,
        .worker_index = 0,
        .slot_index = connection_index,
        .slot_generation = 1,
        .sequence = 33,
    }) catch unreachable;
    const disposition = try harness.driver.handle(.{
        .token = stale,
        .result = .{ .success = .{ .cancel = .not_found } },
        .more = false,
    }, harness.now_ns);
    try std.testing.expectEqual(connection_driver.Disposition.ignored_stale, disposition);
}

test "failed cancel retires only itself and reports backend failure" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(21);
    _ = try harness.receive(connection_index, ping_request, false);
    _ = try harness.driver.stop(connection_index);
    const cancel = harness.findToken(connection_index, .cancel).?;
    const target = harness.io.operation(cancel).?.cancel.target;
    try std.testing.expect(harness.io.operation(target) != null);

    try std.testing.expectError(
        error.BackendFailure,
        harness.complete(cancel, .{ .failure = .backend_failure }, false),
    );
    try std.testing.expect(harness.io.operation(cancel) == null);
    try std.testing.expect(harness.io.operation(target) != null);
}

test "partial first head timeout sends exact 408 then closes and reaps" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(30);
    _ = try harness.receive(connection_index, "GET /pi", false);
    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.responding,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expectEqualStrings(
        request_timeout_response,
        harness.sendBytes(connection_index),
    );
    const send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(request_timeout_response.len) } },
        false,
    );
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.free,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
}

test "terminal receive with a partial head rearms before the deadline" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(31);
    const first_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(first_receive).?.receive.multishot);
    _ = try harness.receive(connection_index, "GET ", false);
    const second_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!second_receive.eql(first_receive));
    try std.testing.expect(!harness.io.operation(second_receive).?.receive.multishot);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.first_head,
        harness.storage.connections[connection_index].phase,
    );

    _ = try harness.receive(
        connection_index,
        "/ping HTTP/1.1\r\nHost: example.test\r\n\r\n",
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
    try std.testing.expect(std.mem.endsWith(u8, harness.sendBytes(connection_index), "pong"));
}

test "receive buffer exhaustion pauses until the worker reports recycled capacity" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(32);
    const receive_token = harness.storage.connections[connection_index].receive_token.?;
    _ = try harness.complete(receive_token, .{ .failure = .buffer_exhausted }, false);
    try std.testing.expect(harness.storage.connections[connection_index].receive_flags.paused);
    try std.testing.expect(
        harness.storage.connections[connection_index].receive_token == null,
    );
    try std.testing.expect(try harness.driver.resumeReceive(connection_index));
    try std.testing.expect(
        harness.storage.connections[connection_index].receive_token != null,
    );
    try std.testing.expect(!harness.storage.connections[connection_index].receive_flags.paused);
}

test "semantic 400 wins over exhausted request storage and valid request gets exact 503" {
    var harness: Harness = undefined;
    try harness.init();
    const occupied = try harness.addConnection(40);
    _ = try harness.receive(occupied, ping_request, false);
    try std.testing.expect(harness.storage.connections[occupied].active_request != null);

    const malformed = try harness.addConnection(41);
    const bad_framing =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Length: nope\r\n\r\n";
    _ = try harness.receive(malformed, bad_framing, false);
    const expected_bad_request =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "content-length: 0\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "connection: close\r\n\r\n";
    try std.testing.expectEqualStrings(
        expected_bad_request,
        harness.sendBytes(malformed),
    );

    const exhausted = try harness.addConnection(42);
    const escaped_ping = "GET /p%69ng HTTP/1.1\r\nHost: example.test\r\n\r\n";
    _ = try harness.receive(exhausted, escaped_ping, false);
    const expected_unavailable =
        "HTTP/1.1 503 Service Unavailable\r\n" ++
        "content-length: 0\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "connection: close\r\n\r\n";
    try std.testing.expectEqualStrings(
        expected_unavailable,
        harness.sendBytes(exhausted),
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 5),
        harness.storage.decodedPath(exhausted)[0..5],
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
}

test "reused partial head timeout sends 408 and write timeout closes silently" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(50);
    _ = try harness.receive(connection_index, ping_request, false);
    const send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try harness.cancelCurrentTimeout(connection_index);
    try harness.drainRetirements(connection_index);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[connection_index].phase,
    );

    _ = try harness.receive(connection_index, "GET ", false);
    const progress_timeout = harness.storage.connections[connection_index].timeout_token.?;
    _ = try harness.receive(connection_index, "/pi", false);
    try std.testing.expect(harness.storage.connections[connection_index]
        .timeout_token.?.eql(progress_timeout));

    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(progress_timeout, .{ .success = .{ .timeout = {} } }, false);
    try std.testing.expectEqualStrings(
        request_timeout_response,
        harness.sendBytes(connection_index),
    );
    const write_timeout = harness.storage.connections[connection_index].timeout_token.?;
    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(write_timeout, .{ .success = .{ .timeout = {} } }, false);
    const close = harness.storage.connections[connection_index].close_token.?;
    try harness.io.complete(close, .{ .failure = .backend_failure }, false);
    const completion = harness.io.nextCompletion().?;
    try std.testing.expectError(
        error.BackendFailure,
        harness.driver.handle(completion, harness.now_ns),
    );
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expect(harness.storage.connections[connection_index].close_token != null);
}

test "stale and closing head timeout races never overwrite or start a response" {
    var stale_harness: Harness = undefined;
    try stale_harness.init();
    const stale_index = try stale_harness.addConnection(51);
    const head_timeout = stale_harness.storage.connections[stale_index].timeout_token.?;
    const malformed =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Length: nope\r\n\r\n";
    const expected_bad_request =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "content-length: 0\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "connection: close\r\n\r\n";
    _ = try stale_harness.receive(stale_index, malformed, false);
    try std.testing.expectEqualStrings(
        expected_bad_request,
        stale_harness.sendBytes(stale_index),
    );
    _ = try stale_harness.complete(
        head_timeout,
        .{ .success = .{ .timeout = {} } },
        false,
    );
    try std.testing.expectEqualStrings(
        expected_bad_request,
        stale_harness.sendBytes(stale_index),
    );

    var closing_harness: Harness = undefined;
    try closing_harness.init();
    const closing_index = try closing_harness.addConnection(52);
    const closing_timeout = closing_harness.storage.connections[closing_index].timeout_token.?;
    _ = try closing_harness.driver.stop(closing_index);
    _ = try closing_harness.complete(
        closing_timeout,
        .{ .success = .{ .timeout = {} } },
        false,
    );
    try std.testing.expect(
        closing_harness.storage.connections[closing_index].send_token == null,
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        closing_harness.storage.connections[closing_index].pipeline_write,
    );
    try closing_harness.drainClosing(closing_index);
}

test "production backend satisfies connection driver method surface" {
    const ReceiveBuffers = buffer_ring.BufferRing(
        test_limits.receive_buffers,
        test_limits.receive_buffer_bytes,
        31,
    );
    const Backend = io_uring_backend.IoUringBackend(test_limits, ReceiveBuffers);
    const ProductionDriver = connection_driver.Driver(TestApp, TestStorage, Backend);
    std.testing.refAllDecls(ProductionDriver);
}

test "driver rejects a config-valid undersized rejection buffer before serving" {
    var slab: [UndersizedStorage.required_bytes]u8 align(UndersizedStorage.slab_alignment) =
        undefined;
    var storage: UndersizedStorage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = TestState{};
    try std.testing.expectError(
        error.RejectionBufferTooSmall,
        UndersizedDriver.init(
            &state,
            &storage,
            &io,
            0,
            .{ .date = fixed_date },
        ),
    );
}

test "unexpected MORE on one-shot head fails closed and recycles its loan" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(60);
    const receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(receive).?.receive.multishot);
    _ = try harness.receive(connection_index, ping_request, true);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expect(harness.storage.connections[connection_index].receive_token.?
        .eql(receive));
    try std.testing.expectEqual(@as(u64, 1), harness.io.recycledCount());
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.free,
        harness.storage.connections[connection_index].phase,
    );
}

test "ReleaseFast rejects corrupt pipeline cursors before reuse lifecycle mutation" {
    if (builtin.mode != .ReleaseFast) return;

    var reuse_harness: Harness = undefined;
    try reuse_harness.init();
    const reuse_index = try reuse_harness.addConnection(63);
    _ = try reuse_harness.receive(reuse_index, ping_request, false);
    const reuse_connection = &reuse_harness.storage.connections[reuse_index];
    reuse_connection.pipeline_read = 2;
    reuse_connection.pipeline_write = 1;
    const send = reuse_connection.send_token.?;
    try std.testing.expectError(error.StateInvariant, reuse_harness.complete(
        send,
        .{ .success = .{ .send = @intCast(reuse_harness.sendBytes(reuse_index).len) } },
        false,
    ));
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.responding,
        reuse_connection.phase,
    );
}

test "fragmented reused head keeps one-shot operations bounded" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(61);
    _ = try harness.receive(connection_index, ping_request, false);
    const first_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        first_send,
        .{ .success = .{ .send = @intCast(harness.sendBytes(connection_index).len) } },
        false,
    );
    try harness.cancelCurrentTimeout(connection_index);
    try harness.drainRetirements(connection_index);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[connection_index].phase,
    );

    _ = try harness.receive(connection_index, "GET ", false);
    const receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(receive).?.receive.multishot);
    _ = try harness.receive(connection_index, ping_request["GET ".len..], false);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.responding,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expect(
        harness.io.activeCount() <= reactor.connection_operation_capacity,
    );
    try std.testing.expectEqual(@as(u16, 2), harness.state.calls);
}

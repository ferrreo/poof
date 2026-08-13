const source = @import("connection_body_driver_test.zig");
const std = source.std;
const address = source.address;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const forwarding = source.forwarding;
const multipart = source.multipart;
const response = source.response;
const route = source.route;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const continue_response = source.continue_response;
const ping_request = source.ping_request;
const echo_head = source.echo_head;
const expect_echo_head = source.expect_echo_head;
const large_body_encoded_bytes_max = source.large_body_encoded_bytes_max;
const large_body_decoded_bytes_max = source.large_body_decoded_bytes_max;
const head_json_secret = source.head_json_secret;
const multipart_boundary = source.multipart_boundary;
const multipart_total_bytes_max = source.multipart_total_bytes_max;
const multipart_count_part = source.multipart_count_part;
const multipart_upload_head = source.multipart_upload_head;
const multipart_close = source.multipart_close;
const multipart_body = source.multipart_body;
const multipart_large_body = source.multipart_large_body;
const multipart_invalid_body = source.multipart_invalid_body;
const multipart_field_limit_body = source.multipart_field_limit_body;
const multipart_file_limit_body = source.multipart_file_limit_body;
const multipart_total_limit_body = source.multipart_total_limit_body;
const multipart_unsupported_body = source.multipart_unsupported_body;
const multipart_fixed_head = source.multipart_fixed_head;
const multipart_chunked_head = source.multipart_chunked_head;
const multipart_chunked_wire = source.multipart_chunked_wire;
const TestState = source.TestState;
const TestContext = source.TestContext;
const TestResponse = source.TestResponse;
const Observe = source.Observe;
const ShortCircuit = source.ShortCircuit;
const HeadJsonTaint = source.HeadJsonTaint;
const echo = source.echo;
const hasExpectedTrailers = source.hasExpectedTrailers;
const ping = source.ping;
const checkForwardingHandler = source.checkForwardingHandler;
const forwardingMatches = source.forwardingMatches;
const text = source.text;
const MultipartBody = source.MultipartBody;
const MultipartEndpoint = source.MultipartEndpoint;
const MultipartSpec = source.MultipartSpec;
const MultipartConsumer = source.MultipartConsumer;
const TaintedEndpoint = source.TaintedEndpoint;
const tainted = source.tainted;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const TestProfile = source.TestProfile;
const TestDriver = source.TestDriver;
const Harness = source.Harness;
const expectMultipartRejection = source.expectMultipartRejection;
const expectFinalWithoutContinue = source.expectFinalWithoutContinue;

test "fixed identity body waits for every fragmented byte" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(10);
    const head_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(head_receive).?.receive.multishot);

    _ = try harness.receive(connection_index, echo_head ++ "ab", false);
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
    try std.testing.expect(harness.storage.connections[connection_index].send_token == null);
    const body_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(harness.io.operation(body_receive).?.receive.multishot);
    _ = try harness.complete(
        body_receive,
        .{ .failure = .buffer_exhausted },
        false,
    );
    try std.testing.expect(harness.storage.connections[connection_index].receive_flags.paused);
    try std.testing.expect(try harness.driver.resumeReceive(connection_index));
    const resumed_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(harness.io.operation(resumed_receive).?.receive.multishot);

    _ = try harness.receive(connection_index, "cdef", false);
    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(usize, 6), harness.state.body_length);
    try std.testing.expect(harness.state.body_is_abcdef);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nbody-ok",
    ));
}

test "fixed multipart request streams every byte through full HTTP admission" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(12);

    _ = try harness.receive(connection_index, multipart_fixed_head, false);
    for (0..multipart_body.len) |index| {
        _ = try harness.receive(
            connection_index,
            multipart_body[index .. index + 1],
            false,
        );
    }

    try std.testing.expectEqual(@as(u8, 1), harness.state.multipart_calls);
    try std.testing.expectEqual(@as(u16, 23), harness.state.multipart_count);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nmultipart-ok",
    ));
    const request_index = harness.storage.connections[connection_index]
        .active_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), harness.storage.requests[request_index].body.used);
}

test "chunked multipart request streams framing and body through full driver" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(13);

    _ = try harness.receive(connection_index, multipart_chunked_head, false);
    for (0..multipart_chunked_wire.len) |index| {
        _ = try harness.receive(
            connection_index,
            multipart_chunked_wire[index .. index + 1],
            false,
        );
    }

    try std.testing.expectEqual(@as(u8, 1), harness.state.multipart_calls);
    try std.testing.expectEqual(@as(u16, 23), harness.state.multipart_count);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nmultipart-ok",
    ));
    const request_index = harness.storage.connections[connection_index]
        .active_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), harness.storage.requests[request_index].body.used);
}

test "identity multipart rejection maps status and returns every workspace" {
    const invalid_wire = std.fmt.comptimePrint(
        "POST /multipart HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ multipart_boundary, multipart_invalid_body.len, multipart_invalid_body },
    );
    const field_limit_wire = multipart_chunked_head ++ std.fmt.comptimePrint(
        "{x}\r\n{s}\r\n0\r\n\r\n",
        .{ multipart_field_limit_body.len, multipart_field_limit_body },
    );
    const unsupported_wire = std.fmt.comptimePrint(
        "POST /multipart HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\n" ++
            "Content-Length: {d}\r\n\r\n{s}",
        .{ multipart_boundary, multipart_unsupported_body.len, multipart_unsupported_body },
    );
    const cases = .{
        .{ invalid_wire, "HTTP/1.1 400 Bad Request\r\n" },
        .{ field_limit_wire, "HTTP/1.1 413 Payload Too Large\r\n" },
        .{ unsupported_wire, "HTTP/1.1 415 Unsupported Media Type\r\n" },
    };
    inline for (cases, 14..) |case, socket| {
        try expectMultipartRejection(case[0], case[1], socket);
    }
}

test "borrowed forwarding identity survives fragmented body and keepalive reuse" {
    const first_head =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: origin.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Length: 6\r\n" ++
        "X-Forwarded-For: 192.0.2.7\r\n" ++
        "X-Forwarded-Host: body.example\r\n" ++
        "X-Forwarded-Proto: https\r\n\r\n";
    const second_request =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: origin.test\r\n" ++
        "X-Forwarded-For: 198.51.100.9\r\n" ++
        "X-Forwarded-Host: next.example\r\n" ++
        "X-Forwarded-Proto: https\r\n\r\n";

    var harness: Harness = undefined;
    try harness.initForwarding(.{
        .family = .x_forwarded,
        .trusted = &.{"127.0.0.1"},
    });
    harness.state.expected_authority = try source.authority.parse(
        "body.example",
        .https,
    );
    harness.state.expected_client = address.Endpoint.initIpv4(.{ 192, 0, 2, 7 }, 0);
    const connection_index = try harness.addConnection(11);

    const head_split = first_head.len - 17;
    _ = try harness.receive(connection_index, first_head[0..head_split], false);
    _ = try harness.receive(connection_index, first_head[head_split..] ++ "ab", false);
    _ = try harness.receive(connection_index, "cd", false);
    _ = try harness.receive(connection_index, "ef", false);
    try std.testing.expectEqual(@as(u8, 1), harness.state.forwarding_head_checks);
    try std.testing.expectEqual(@as(u8, 1), harness.state.forwarding_handler_checks);
    try std.testing.expect(harness.state.forwarding_valid);

    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.forwarding_after_checks);
    try harness.retireResponse(connection_index);

    harness.state.expected_authority = try source.authority.parse(
        "next.example",
        .https,
    );
    harness.state.expected_client = address.Endpoint.initIpv4(.{ 198, 51, 100, 9 }, 0);
    _ = try harness.receive(connection_index, second_request, false);
    try std.testing.expectEqual(@as(u8, 2), harness.state.forwarding_head_checks);
    try std.testing.expectEqual(@as(u8, 2), harness.state.forwarding_handler_checks);
    try std.testing.expect(harness.state.forwarding_valid);

    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 2), harness.state.forwarding_after_checks);
    try std.testing.expect(harness.state.forwarding_valid);
}

test "coalesced body leaves pipelined request behind first final response" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(20);

    _ = try harness.receive(
        connection_index,
        echo_head ++ "abcdef" ++ ping_request,
        false,
    );
    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.ping_calls);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nbody-ok",
    ));

    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completed);
    try harness.retireResponse(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\npong",
    ));
}

test "partial continue send stays ahead of completed body response" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(30);

    _ = try harness.receive(connection_index, expect_echo_head, false);
    try std.testing.expectEqualStrings(
        continue_response,
        harness.sendBytes(connection_index),
    );
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);

    try harness.completeSend(connection_index, 7);
    try std.testing.expectEqualStrings(
        continue_response[7..],
        harness.sendBytes(connection_index),
    );
    _ = try harness.receive(connection_index, "abcdef", false);
    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqualStrings(
        continue_response[7..],
        harness.sendBytes(connection_index),
    );

    try harness.completeSendAll(connection_index);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.sendBytes(connection_index),
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "zero wire body skips continue and invokes handler once" {
    const request =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Length: 0\r\n" ++
        "Expect: 100-continue\r\n\r\n";
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(40);
    _ = try harness.receive(connection_index, request, false);

    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(usize, 0), harness.state.body_length);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.sendBytes(connection_index),
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "bodyless response closes over unread body and never dispatches tail" {
    const request =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Length: 4\r\n\r\n" ++
        "junk" ++ ping_request;
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(50);
    _ = try harness.receive(connection_index, request, false);

    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
    try std.testing.expect(
        std.mem.indexOf(u8, harness.sendBytes(connection_index), "connection: close\r\n") != null,
    );
    try harness.completeSendAll(connection_index);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
}

test "head short response closes over unread body and never dispatches tail" {
    const request =
        "POST /short HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Length: 4\r\n" ++
        "Expect: 100-continue\r\n\r\n" ++
        "junk" ++ ping_request;
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(51);
    _ = try harness.receive(connection_index, request, false);

    try std.testing.expectEqual(@as(u8, 1), harness.state.short_head_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.ping_calls);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.sendBytes(connection_index),
        "HTTP/1.1 403 Forbidden\r\n",
    ));
    try harness.completeSendAll(connection_index);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 0), harness.state.ping_calls);
}

test "bad media and known length rejection never send continue" {
    const Case = struct {
        wire: []const u8,
        status_line: []const u8,
    };
    const cases = [_]Case{
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Type: text/plain\r\nContent-Length: 6\r\n" ++
                "Expect: 100-continue\r\n\r\n",
            .status_line = "HTTP/1.1 415 Unsupported Media Type\r\n",
        },
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Type: application/octet-stream\r\nContent-Length: 9\r\n" ++
                "Expect: 100-continue\r\n\r\n",
            .status_line = "HTTP/1.1 413 Payload Too Large\r\n",
        },
    };
    for (cases, 60..) |case, socket| {
        var harness: Harness = undefined;
        try harness.init();
        const connection_index = try harness.addConnection(socket);
        _ = try harness.receive(connection_index, case.wire, false);
        try expectFinalWithoutContinue(&harness, connection_index, case.status_line);
        try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
    }
}

test "body workspace exhaustion returns final 503 without continue" {
    var harness: Harness = undefined;
    try harness.init();
    const occupied = try harness.addConnection(70);
    _ = try harness.receive(occupied, echo_head ++ "ab", false);
    try std.testing.expectEqual(@as(u16, 0), harness.storage.bodyWorkspaceAvailable());

    const exhausted = try harness.addConnection(71);
    _ = try harness.receive(exhausted, expect_echo_head, false);
    try expectFinalWithoutContinue(
        &harness,
        exhausted,
        "HTTP/1.1 503 Service Unavailable\r\n",
    );
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
}

test "premature body eof sends 400 and completes lifecycle once" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(80);
    _ = try harness.receive(connection_index, echo_head ++ "ab", false);
    _ = try harness.endOfStream(connection_index);
    try expectFinalWithoutContinue(
        &harness,
        connection_index,
        "HTTP/1.1 400 Bad Request\r\n",
    );

    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u8, 0), harness.state.aborted);
    try std.testing.expectEqual(response.Status.bad_request, harness.state.last_status.?);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
}

test "body inactivity timeout sends 408 and completes lifecycle once" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(81);
    _ = try harness.receive(connection_index, echo_head ++ "ab", false);
    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    harness.now_ns = harness.storage.connections[connection_index].timeout_deadline_ns;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    try expectFinalWithoutContinue(
        &harness,
        connection_index,
        "HTTP/1.1 408 Request Timeout\r\n",
    );

    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u8, 0), harness.state.aborted);
    try std.testing.expectEqual(response.Status.request_timeout, harness.state.last_status.?);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
}

test "delayed continue control completions leave close operation capacity" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(82);
    _ = try harness.receive(connection_index, expect_echo_head, false);
    try harness.completeSendAll(connection_index);
    _ = try harness.receive(connection_index, "abcdef", true);

    try std.testing.expectEqual(@as(u16, 5), harness.io.activeCount());
    _ = try harness.driver.stop(connection_index);
    try std.testing.expectEqual(@as(u16, 9), harness.io.activeCount());
    try std.testing.expect(
        harness.io.activeCount() <= reactor.connection_operation_capacity,
    );
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.aborted);
}

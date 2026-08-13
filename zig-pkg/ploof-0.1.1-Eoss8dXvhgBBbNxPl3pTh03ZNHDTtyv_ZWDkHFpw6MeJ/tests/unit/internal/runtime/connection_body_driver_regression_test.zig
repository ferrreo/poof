const std = @import("std");
const response = @import("../../../../src/response.zig");
const driver_test = @import("connection_body_driver_test.zig");

const Harness = driver_test.Harness;
const zero_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 0\r\n\r\n";
const invalid_text_request =
    "POST /text HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 2\r\n\r\n" ++
    "\xc3\x28";

test "body driver regression preserves zero fixed borrowed pipeline tail" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(100);
    _ = try harness.receive(
        connection_index,
        zero_echo_head ++ driver_test.ping_request,
        false,
    );

    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(usize, 0), harness.state.body_length);
    try std.testing.expectEqual(@as(u8, 0), harness.state.ping_calls);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nbody-ok",
    ));
    try harness.completeSendAll(connection_index);
    try harness.retireResponse(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\npong",
    ));
}

test "body driver regression rejects invalid utf8 once" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(101);
    _ = try harness.receive(connection_index, invalid_text_request, false);

    try std.testing.expectEqual(@as(u8, 0), harness.state.text_calls);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.sendBytes(connection_index),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try harness.completeSendAll(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u8, 0), harness.state.aborted);
    try std.testing.expectEqual(response.Status.bad_request, harness.state.last_status.?);
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
}

test "body driver regression preserves pipeline sourced fragmented ingress" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(102);
    _ = try harness.receive(
        connection_index,
        driver_test.ping_request ++ driver_test.echo_head ++ "ab",
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
    try harness.completeSendAll(connection_index);
    try harness.retireResponse(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
    _ = try harness.receive(connection_index, "cdef", false);
    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expect(harness.state.body_is_abcdef);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.sendBytes(connection_index),
        "\r\n\r\nbody-ok",
    ));
}

test "body driver regression handles continue timeout failure reorder" {
    try expectContinueFailureOrder(true, 103);
    try expectContinueFailureOrder(false, 104);
}

fn expectContinueFailureOrder(timeout_first: bool, socket: u64) !void {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(socket);
    _ = try harness.receive(connection_index, driver_test.expect_echo_head, false);
    const connection = &harness.storage.connections[connection_index];
    const send = connection.send_token.?;
    const timeout = connection.timeout_token.?;
    harness.now_ns = connection.timeout_deadline_ns;

    if (timeout_first) {
        _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
        _ = try harness.complete(send, .{ .failure = .broken_pipe }, false);
    } else {
        _ = try harness.complete(send, .{ .failure = .broken_pipe }, false);
        _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    }
    try harness.drainClosing(connection_index);
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.completed);
    try std.testing.expectEqual(@as(u8, 1), harness.state.aborted);
    try std.testing.expectEqual(@as(?response.Status, null), harness.state.last_status);
}

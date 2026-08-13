const std = @import("std");
const connection_chunked_body = @import(
    "../../../../src/internal/runtime/connection/chunked_body.zig",
);
const fixture = @import("connection_body_driver_test.zig");

const Harness = fixture.Harness;
const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
const chunk_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
const trailer_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
const expect_chunk_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Expect: 100-continue\r\n\r\n";
const duplicate_trailer_wire =
    "2\r\nab\r\n" ++
    "4\r\ncdef\r\n" ++
    "0\r\n" ++
    "X-Check:  first \t\r\n" ++
    "x-CHECK:\tsecond\r\n\r\n";
const simple_wire = "6\r\nabcdef\r\n0\r\n\r\n";
const tainted_chunk_head =
    "POST /tainted HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";

test "chunked body is accepted contiguously and one byte at a time" {
    try expectAccepted(false);
    try expectAccepted(true);
}

test "runtime applies its nonstandard chunked profile" {
    const ChunkedState = connection_chunked_body.Receiver(fixture.test_limits.chunked);
    try std.testing.expectEqual(
        @sizeOf(ChunkedState),
        fixture.TestStorage.chunked_workspace_bytes_per_slot,
    );
    try std.testing.expect(@sizeOf(ChunkedState) < @sizeOf(connection_chunked_body.State));

    const declaration_limit_head =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Trailer: X-One, X-Two, X-Three\r\n\r\n";
    const cases = [_]struct { head: []const u8, wire: []const u8 }{
        .{
            .head = chunk_head,
            .wire = "1\r\na\r\n1\r\nb\r\n1\r\nc\r\n1\r\nd\r\n",
        },
        .{
            .head = trailer_head,
            .wire = "0\r\nX-Check:a\r\nX-Check:b\r\nX-Check:c\r\nX-Check:d\r\n\r\n",
        },
        .{ .head = declaration_limit_head, .wire = "" },
    };
    for (cases, 90..) |case, socket| {
        var harness: Harness = undefined;
        try harness.init();
        const connection_index = try harness.addConnection(socket);
        _ = try harness.receive(connection_index, case.head, false);
        if (case.wire.len != 0) {
            _ = try harness.receive(connection_index, case.wire, false);
        }
        try expectClosedFinal(&harness, connection_index, "HTTP/1.1 400 Bad Request\r\n");
        try expectAllWorkspacesAvailable(&harness);
    }
}

test "zero chunk dispatches empty body and releases both workspaces" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(100);
    _ = try harness.receive(connection_index, chunk_head ++ "0\r\n\r\n", false);

    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(usize, 0), harness.state.body_length);
    try expectStatus(&harness, connection_index, "HTTP/1.1 200 OK\r\n");
    try finishSuccess(&harness, connection_index);
}

test "chunked body preserves an exact pipelined request behind its response" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(101);
    _ = try harness.receive(
        connection_index,
        chunk_head ++ simple_wire ++ fixture.ping_request,
        false,
    );

    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.ping_calls);
    try expectResponseBody(&harness, connection_index, "body-ok");
    try expectPipeline(&harness, connection_index, fixture.ping_request);

    try harness.completeSendAll(connection_index);
    try harness.retireResponse(connection_index);
    try std.testing.expectEqual(@as(u8, 1), harness.state.ping_calls);
    try expectResponseBody(&harness, connection_index, "pong");
    try finishSuccess(&harness, connection_index);
}

test "chunked expect sends continue only when its tail is incomplete" {
    var waiting: Harness = undefined;
    try waiting.init();
    const waiting_index = try waiting.addConnection(102);
    _ = try waiting.receive(waiting_index, expect_chunk_head, false);
    try std.testing.expectEqualStrings(continue_response, waiting.sendBytes(waiting_index));
    try std.testing.expectEqual(@as(u8, 0), waiting.state.body_calls);

    try waiting.completeSendAll(waiting_index);
    _ = try waiting.receive(waiting_index, simple_wire, false);
    try expectStatus(&waiting, waiting_index, "HTTP/1.1 200 OK\r\n");
    try finishSuccess(&waiting, waiting_index);

    var optimistic: Harness = undefined;
    try optimistic.init();
    const optimistic_index = try optimistic.addConnection(103);
    _ = try optimistic.receive(
        optimistic_index,
        expect_chunk_head ++ simple_wire,
        false,
    );
    try expectFinalWithoutContinue(
        &optimistic,
        optimistic_index,
        "HTTP/1.1 200 OK\r\n",
    );
    try finishSuccess(&optimistic, optimistic_index);
}

test "malformed chunk framing and invalid trailers return 400 and close" {
    const Case = struct {
        head: []const u8,
        wire: []const u8,
    };
    const cases = [_]Case{
        .{ .head = chunk_head, .wire = "z\r\n" },
        .{ .head = chunk_head, .wire = "1\r\naX" },
        .{ .head = trailer_head, .wire = "0\r\nX-Other: value\r\n\r\n" },
        .{ .head = trailer_head, .wire = "0\r\nHost: example.test\r\n\r\n" },
    };
    for (cases, 110..) |case, socket| {
        var harness: Harness = undefined;
        try harness.init();
        const connection_index = try harness.addConnection(socket);
        _ = try harness.receive(connection_index, case.head, false);
        _ = try harness.receive(connection_index, case.wire, false);
        try expectClosedFinal(&harness, connection_index, "HTTP/1.1 400 Bad Request\r\n");
        try expectAllWorkspacesAvailable(&harness);
    }
}

test "malformed chunk clears head JSON beyond committed body prefix" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(119);
    _ = try harness.receive(connection_index, tainted_chunk_head, false);
    _ = try harness.receive(connection_index, "1\r\na\r\n", false);

    const request_index = harness.storage.connections[connection_index].active_request.?;
    const request = harness.storage.requests[request_index];
    try std.testing.expectEqual(@as(u32, 1), request.body.used);
    try std.testing.expect(!request.body.dirty_full);
    try std.testing.expect(request.body.tainted_full);
    const workspace = harness.storage.body_workspaces.storage;
    const secret_offset = std.mem.indexOf(
        u8,
        workspace,
        fixture.head_json_secret,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(secret_offset >= request.body.used);

    _ = try harness.receive(connection_index, "z\r\n", false);
    try expectClosedFinal(&harness, connection_index, "HTTP/1.1 400 Bad Request\r\n");
    try std.testing.expectEqual(@as(u8, 1), harness.state.head_json_calls);
    try std.testing.expect(std.mem.allEqual(u8, workspace, 0));
    try expectAllWorkspacesAvailable(&harness);
}

test "abort clears head JSON before body workspace reuse" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(120);
    _ = try harness.receive(connection_index, tainted_chunk_head, false);
    _ = try harness.receive(connection_index, "1\r\na\r\n", false);
    const workspace = harness.storage.body_workspaces.storage;
    try std.testing.expect(std.mem.indexOf(
        u8,
        workspace,
        fixture.head_json_secret,
    ) != null);

    _ = try harness.driver.stop(connection_index);
    try harness.drainClosing(connection_index);
    try std.testing.expect(std.mem.allEqual(u8, workspace, 0));

    const reused = try harness.addConnection(121);
    _ = try harness.receive(reused, chunk_head, false);
    try std.testing.expect(std.mem.allEqual(u8, workspace, 0));
    _ = try harness.driver.stop(reused);
    try harness.drainClosing(reused);
    try expectAllWorkspacesAvailable(&harness);
}

test "encoded and decoded chunked limits return 413 and close" {
    const oversized_trailer =
        "1\r\na\r\n0\r\nX-Check: " ++ ("a" ** 112) ++ "\r\n\r\n";
    const Case = struct {
        head: []const u8,
        wire: []const u8,
    };
    const cases = [_]Case{
        .{ .head = trailer_head, .wire = oversized_trailer },
        .{ .head = chunk_head, .wire = "9\r\nabcdefghi\r\n" },
    };
    for (cases, 120..) |case, socket| {
        var harness: Harness = undefined;
        try harness.init();
        const connection_index = try harness.addConnection(socket);
        _ = try harness.receive(connection_index, case.head, false);
        _ = try harness.receive(connection_index, case.wire, false);
        try expectClosedFinal(
            &harness,
            connection_index,
            "HTTP/1.1 413 Payload Too Large\r\n",
        );
        try expectAllWorkspacesAvailable(&harness);
    }
}

test "premature chunked eof returns 400" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(130);
    _ = try harness.receive(connection_index, chunk_head ++ "3\r\nab", false);
    _ = try harness.endOfStream(connection_index);
    try expectClosedFinal(&harness, connection_index, "HTTP/1.1 400 Bad Request\r\n");
    try expectAllWorkspacesAvailable(&harness);
}

test "chunked inactivity timeout returns 408" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(131);
    _ = try harness.receive(connection_index, chunk_head ++ "3\r\nab", false);
    const connection = &harness.storage.connections[connection_index];
    const timeout = connection.timeout_token.?;
    harness.now_ns = connection.timeout_deadline_ns;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    try expectClosedFinal(
        &harness,
        connection_index,
        "HTTP/1.1 408 Request Timeout\r\n",
    );
    try expectAllWorkspacesAvailable(&harness);
}

test "chunked pool exhaustion returns 503 without continue" {
    var harness: Harness = undefined;
    try harness.init();
    const occupied = try occupyChunked(&harness, 140);
    const exhausted = try harness.addConnection(141);
    _ = try harness.receive(exhausted, expect_chunk_head, false);
    try expectClosedFinal(
        &harness,
        exhausted,
        "HTTP/1.1 503 Service Unavailable\r\n",
    );
    try std.testing.expectEqual(@as(u16, 0), harness.storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 0), harness.storage.chunkedWorkspaceAvailable());

    _ = try harness.endOfStream(occupied);
    try expectClosedFinal(&harness, occupied, "HTTP/1.1 400 Bad Request\r\n");
    try expectAllWorkspacesAvailable(&harness);
}

test "bodyless and head-short chunked requests do not reserve body workspaces" {
    const bodyless_head =
        "GET /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n";
    const short_head =
        "POST /short HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Expect: 100-continue\r\n\r\n";
    var harness: Harness = undefined;
    try harness.init();
    const occupied = try occupyChunked(&harness, 150);

    const bodyless = try harness.addConnection(151);
    _ = try harness.receive(bodyless, bodyless_head, false);
    try expectStatus(&harness, bodyless, "HTTP/1.1 200 OK\r\n");
    try expectResponseBody(&harness, bodyless, "pong");
    try expectConnectionClose(&harness, bodyless);
    try harness.completeSendAll(bodyless);
    try harness.drainClosing(bodyless);

    const short = try harness.addConnection(152);
    _ = try harness.receive(short, short_head, false);
    try expectFinalWithoutContinue(&harness, short, "HTTP/1.1 403 Forbidden\r\n");
    try expectConnectionClose(&harness, short);
    try harness.completeSendAll(short);
    try harness.drainClosing(short);
    try std.testing.expectEqual(@as(u8, 1), harness.state.short_head_calls);
    try std.testing.expectEqual(@as(u8, 0), harness.state.body_calls);

    _ = try harness.endOfStream(occupied);
    try expectClosedFinal(&harness, occupied, "HTTP/1.1 400 Bad Request\r\n");
    try expectAllWorkspacesAvailable(&harness);
}

test "stop abort observes trailers before releasing chunked workspace" {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(153);
    _ = try harness.receive(
        connection_index,
        trailer_head ++ duplicate_trailer_wire,
        false,
    );

    try std.testing.expect(harness.state.body_saw_trailers);
    try std.testing.expectEqual(@as(u16, 0), harness.storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 0), harness.storage.chunkedWorkspaceAvailable());
    _ = try harness.driver.stop(connection_index);
    try harness.drainClosing(connection_index);

    try std.testing.expect(harness.state.after_saw_trailers);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.aborted);
    try std.testing.expectEqual(@as(u8, 0), harness.state.completed);
    try expectAllWorkspacesAvailable(&harness);
}

fn expectAccepted(one_byte: bool) !void {
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(if (one_byte) 91 else 90);
    if (one_byte) {
        _ = try harness.receive(connection_index, trailer_head, false);
        for (duplicate_trailer_wire, 0..) |byte, index| {
            const input = [_]u8{byte};
            const more = index + 1 != duplicate_trailer_wire.len;
            _ = try harness.receive(connection_index, &input, more);
        }
    } else {
        _ = try harness.receive(
            connection_index,
            trailer_head ++ duplicate_trailer_wire,
            false,
        );
    }
    try std.testing.expectEqual(@as(u8, 1), harness.state.body_calls);
    try std.testing.expectEqual(@as(usize, 6), harness.state.body_length);
    try std.testing.expect(harness.state.body_is_abcdef);
    try std.testing.expect(harness.state.body_saw_trailers);
    try expectResponseBody(&harness, connection_index, "body-ok");
    try harness.completeSendAll(connection_index);
    try std.testing.expect(harness.state.after_saw_trailers);
    try finishAfterCompletedSend(&harness, connection_index);
}

fn occupyChunked(harness: *Harness, socket: u64) !u16 {
    const connection_index = try harness.addConnection(socket);
    _ = try harness.receive(connection_index, chunk_head ++ "1\r\na\r\n", false);
    try std.testing.expectEqual(@as(u16, 0), harness.storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 0), harness.storage.chunkedWorkspaceAvailable());
    return connection_index;
}

fn expectPipeline(harness: *Harness, connection_index: u16, expected: []const u8) !void {
    const connection = harness.storage.connections[connection_index];
    const bytes = harness.storage.pipeline(connection_index);
    try std.testing.expectEqualStrings(
        expected,
        bytes[connection.pipeline_read..connection.pipeline_write],
    );
}

fn expectResponseBody(harness: *const Harness, connection_index: u16, expected: []const u8) !void {
    const bytes = harness.sendBytes(connection_index);
    const separator = std.mem.lastIndexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(expected, bytes[separator + 4 ..]);
}

fn expectStatus(harness: *const Harness, connection_index: u16, status: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, harness.sendBytes(connection_index), status));
}

fn expectFinalWithoutContinue(
    harness: *const Harness,
    connection_index: u16,
    status: []const u8,
) !void {
    const bytes = harness.sendBytes(connection_index);
    try std.testing.expect(!std.mem.startsWith(u8, bytes, continue_response));
    try std.testing.expect(std.mem.startsWith(u8, bytes, status));
}

fn expectConnectionClose(harness: *const Harness, connection_index: u16) !void {
    try std.testing.expect(std.mem.indexOf(
        u8,
        harness.sendBytes(connection_index),
        "connection: close\r\n",
    ) != null);
}

fn expectClosedFinal(harness: *Harness, connection_index: u16, status: []const u8) !void {
    try expectFinalWithoutContinue(harness, connection_index, status);
    try expectConnectionClose(harness, connection_index);
    try harness.completeSendAll(connection_index);
    try harness.drainClosing(connection_index);
}

fn finishSuccess(harness: *Harness, connection_index: u16) !void {
    try harness.completeSendAll(connection_index);
    try finishAfterCompletedSend(harness, connection_index);
}

fn finishAfterCompletedSend(harness: *Harness, connection_index: u16) !void {
    try harness.retireResponse(connection_index);
    try expectAllWorkspacesAvailable(harness);
    _ = try harness.driver.stop(connection_index);
    try harness.drainClosing(connection_index);
}

fn expectAllWorkspacesAvailable(harness: *const Harness) !void {
    try std.testing.expectEqual(
        fixture.test_limits.body_workspace_slots,
        harness.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        fixture.test_limits.chunked_workspace_slots,
        harness.storage.chunkedWorkspaceAvailable(),
    );
}

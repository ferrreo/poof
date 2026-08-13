const source = @import("connection_gzip_driver_test.zig");
const std = source.std;
const builtin = source.builtin;
const fixture = source.fixture;
const gzip_decoder_pool = source.gzip_decoder_pool;
const reactor = source.reactor;
const TestPool = source.TestPool;
const stack_size = source.stack_size;
const storedGzip = source.storedGzip;
const gzip_abcdef = source.gzip_abcdef;
const gzip_twelve = source.gzip_twelve;
const gzip_multipart = source.gzip_multipart;
const gzip_multipart_large = source.gzip_multipart_large;
const gzip_multipart_bad_footer = source.gzip_multipart_bad_footer;
const gzip_multipart_invalid = source.gzip_multipart_invalid;
const gzip_multipart_field_limit = source.gzip_multipart_field_limit;
const gzip_multipart_file_limit = source.gzip_multipart_file_limit;
const gzip_multipart_total_limit = source.gzip_multipart_total_limit;
const gzip_multipart_unsupported = source.gzip_multipart_unsupported;
const Framing = source.Framing;
const gzip_head = source.gzip_head;
const expect_gzip_head = source.expect_gzip_head;
const chunked_gzip_head = source.chunked_gzip_head;
const large_gzip_head = source.large_gzip_head;
const GzipHarness = source.GzipHarness;
const expectMultipartResponse = source.expectMultipartResponse;
const submitMultipart = source.submitMultipart;
const beginMultipart = source.beginMultipart;
const feedMultipartWire = source.feedMultipartWire;
const drainNetwork = source.drainNetwork;
const waitBatch = source.waitBatch;
const waitDecodePaused = source.waitDecodePaused;
const consumedBatch = source.consumedBatch;

test "gzip fixed body is one-shot fragmented and preserves pipeline tail" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(90);

    _ = try harness.base.receive(
        connection,
        gzip_head ++ gzip_abcdef[0..10].*,
        false,
    );
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    const receive = harness.base.storage.connections[connection].receive_token.?;
    try std.testing.expect(!harness.base.io.operation(receive).?.receive.multishot);

    _ = try harness.base.receive(
        connection,
        gzip_abcdef[10..].* ++ fixture.ping_request,
        false,
    );
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    try std.testing.expect(
        harness.base.storage.connections[connection].receive_flags.gzip_paused,
    );
    try std.testing.expect(
        harness.base.storage.connections[connection].receive_token == null,
    );

    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.body_calls);
    try std.testing.expect(harness.base.state.body_is_abcdef);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.base.sendBytes(connection),
        "\r\n\r\nbody-ok",
    ));

    try harness.base.completeSendAll(connection);
    try harness.base.retireResponse(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.ping_calls);
}

test "gzip chunked feeds data only and retains declared trailers" {
    const wire = chunked_gzip_head ++ "1a\r\n" ++ gzip_abcdef ++
        "\r\n0\r\nX-Check:  first \t\r\nx-CHECK:\tsecond\r\n\r\n";
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(91);

    for (wire) |byte| {
        const one = [1]u8{byte};
        _ = try harness.base.receive(connection, &one, false);
    }
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.body_calls);
    try std.testing.expect(harness.base.state.body_is_abcdef);
    try std.testing.expect(harness.base.state.body_saw_trailers);
}

test "gzip fixed multipart streams decoded output into typed consumer" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(122);

    try submitMultipart(&harness, connection, &gzip_multipart, .fixed, false);
    try harness.dispatchUntilIdle();
    try expectMultipartResponse(&harness, connection);
}

test "gzip chunked multipart separates wire framing from decoded parser bytes" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(123);

    try submitMultipart(&harness, connection, &gzip_multipart, .chunked, false);
    try harness.dispatchUntilIdle();
    try expectMultipartResponse(&harness, connection);
}

test "gzip multipart crosses output mailbox and acknowledges every chunk" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(124);

    try submitMultipart(&harness, connection, &gzip_multipart_large, .fixed, false);
    try harness.dispatchUntilIdle();
    try std.testing.expect(harness.output_dispatches >= 2);
    try expectMultipartResponse(&harness, connection);
}

test "gzip multipart limits and media failures preserve exact statuses" {
    const Case = struct {
        encoded: []const u8,
        framing: Framing,
        status: []const u8,
    };
    const cases = [_]Case{
        .{
            .encoded = &gzip_multipart_field_limit,
            .framing = .fixed,
            .status = "HTTP/1.1 413 Payload Too Large\r\n",
        },
        .{
            .encoded = &gzip_multipart_file_limit,
            .framing = .chunked,
            .status = "HTTP/1.1 413 Payload Too Large\r\n",
        },
        .{
            .encoded = &gzip_multipart_total_limit,
            .framing = .fixed,
            .status = "HTTP/1.1 413 Payload Too Large\r\n",
        },
        .{
            .encoded = &gzip_multipart_unsupported,
            .framing = .chunked,
            .status = "HTTP/1.1 415 Unsupported Media Type\r\n",
        },
    };
    for (cases, 125..) |case, socket| {
        var harness: GzipHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const connection = try harness.base.addConnection(socket);
        try submitMultipart(&harness, connection, case.encoded, case.framing, false);
        try harness.dispatchUntilIdle();
        try std.testing.expect(std.mem.startsWith(
            u8,
            harness.base.sendBytes(connection),
            case.status,
        ));
        try std.testing.expect(harness.output_dispatches != 0);
        try std.testing.expectEqual(@as(u8, 0), harness.base.state.multipart_calls);
        try harness.base.completeSendAll(connection);
        try harness.base.drainClosing(connection);
        try std.testing.expectEqual(@as(u16, 0), harness.pool().activeJobs());
        try std.testing.expectEqual(
            fixture.test_limits.gzip.decoder_slots,
            harness.pool().available(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.body_workspace_slots,
            harness.base.storage.bodyWorkspaceAvailable(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.chunked_workspace_slots,
            harness.base.storage.chunkedWorkspaceAvailable(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.request_slots,
            harness.base.storage.request_pool.available(),
        );
    }
}

test "gzip multipart bad footer after decoded prefix never completes consumer" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(129);

    try submitMultipart(&harness, connection, &gzip_multipart_bad_footer, .chunked, false);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u64, 1), harness.output_dispatches);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.base.sendBytes(connection),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.multipart_calls);
}

test "gzip multipart parser rejection stays behind outstanding continue" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(130);

    try beginMultipart(&harness, connection, gzip_multipart_invalid.len, .fixed, true);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 100 Continue\r\n\r\n",
        harness.base.sendBytes(connection),
    );
    try feedMultipartWire(&harness, connection, &gzip_multipart_invalid, .fixed);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqualStrings(
        "HTTP/1.1 100 Continue\r\n\r\n",
        harness.base.sendBytes(connection),
    );
    try std.testing.expect(harness.output_dispatches != 0);
    try harness.base.completeSendAll(connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.base.sendBytes(connection),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.multipart_calls);
}

test "gzip chunked rejection cancels decoder and preserves protocol status" {
    const Case = struct { tail: []const u8, status: []const u8 };
    const cases = [_]Case{
        .{ .tail = "80\r\n", .status = "HTTP/1.1 413 Payload Too Large\r\n" },
        .{ .tail = "z\r\n", .status = "HTTP/1.1 400 Bad Request\r\n" },
    };
    for (cases, 92..) |case, socket| {
        var harness: GzipHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const connection = try harness.base.addConnection(socket);
        _ = try harness.base.receive(connection, chunked_gzip_head, false);
        _ = try harness.base.receive(connection, case.tail, false);
        try std.testing.expect(
            harness.base.storage.connections[connection].send_token == null,
        );
        try harness.dispatchUntilIdle();
        try std.testing.expect(std.mem.startsWith(
            u8,
            harness.base.sendBytes(connection),
            case.status,
        ));
        try std.testing.expect(harness.base.storage.connections[connection]
            .close_after_response);
        try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    }
}

test "gzip coalesced chunk rejection skips continue" {
    const wire =
        "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n" ++
        "Expect: 100-continue\r\n\r\nz\r\n";
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(131);

    _ = try harness.base.receive(connection, wire, false);
    try std.testing.expect(
        harness.base.storage.connections[connection].send_token == null,
    );
    try harness.dispatchUntilIdle();
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.base.sendBytes(connection),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
}

test "gzip chunk rejection status survives timeout before decoder terminal" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    TestPool.TestAccess.pauseDecode(true);
    defer TestPool.TestAccess.pauseDecode(false);
    const connection = try harness.base.addConnection(120);
    _ = try harness.base.receive(connection, chunked_gzip_head, false);
    try waitDecodePaused();
    _ = try harness.base.receive(connection, "z\r\n", false);

    const record = &harness.base.storage.connections[connection];
    const timeout = record.timeout_token.?;
    harness.base.now_ns = record.timeout_deadline_ns;
    _ = try harness.base.complete(
        timeout,
        .{ .success = .{ .timeout = {} } },
        false,
    );
    try std.testing.expect(record.phase == .receiving_body);
    try std.testing.expect(record.send_token == null);

    TestPool.TestAccess.pauseDecode(false);
    try harness.dispatchUntilIdle();
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.base.sendBytes(connection),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try std.testing.expect(record.close_after_response);
}

test "gzip malformed and decoded limit terminals map to 400 and 413" {
    const Case = struct { wire: []const u8, status: []const u8 };
    const cases = [_]Case{
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Encoding: gzip\r\nContent-Length: 4\r\n\r\nnope",
            .status = "HTTP/1.1 400 Bad Request\r\n",
        },
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++ gzip_twelve,
            .status = "HTTP/1.1 413 Payload Too Large\r\n",
        },
    };
    for (cases, 93..) |case, socket| {
        var harness: GzipHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const connection = try harness.base.addConnection(socket);
        _ = try harness.base.receive(connection, case.wire, false);
        try harness.dispatchUntilIdle();
        try std.testing.expect(std.mem.startsWith(
            u8,
            harness.base.sendBytes(connection),
            case.status,
        ));
        try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    }
}

test "gzip pool exhaustion returns 503 before continue" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var output: [8]u8 = undefined;
    const raw = harness.pool().acquire(
        .{ .connection_index = 99, .request_index = 99, .generation = 1 },
        &output,
        .{ .encoded_max = 1, .decoded_max = output.len },
    ) orelse return error.TestUnexpectedResult;
    const connection = try harness.base.addConnection(95);

    _ = try harness.base.receive(connection, expect_gzip_head, false);
    const response = harness.base.sendBytes(connection);
    try std.testing.expect(!std.mem.startsWith(u8, response, "HTTP/1.1 100 Continue\r\n"));
    try std.testing.expect(std.mem.startsWith(
        u8,
        response,
        "HTTP/1.1 503 Service Unavailable\r\n",
    ));

    try harness.pool().cancel(raw);
    while (true) {
        const batch = try waitBatch(harness.pool());
        if (!batch.slots[raw.index].terminal) continue;
        try harness.pool().ack(raw);
        break;
    }
}

test "gzip expect sends continue before decoding body" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(96);
    _ = try harness.base.receive(connection, expect_gzip_head, false);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 100 Continue\r\n\r\n",
        harness.base.sendBytes(connection),
    );
    try harness.base.completeSendAll(connection);
    _ = try harness.base.receive(connection, &gzip_abcdef, false);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.body_calls);
}

test "gzip queue threshold pauses until space signal resumes one-shot receive" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    TestPool.TestAccess.pauseDecode(true);
    defer TestPool.TestAccess.pauseDecode(false);
    const connection = try harness.base.addConnection(97);
    _ = try harness.base.receive(connection, large_gzip_head, false);
    try waitDecodePaused();

    var prefix = [_]u8{0} ** 2048;
    const gzip_header = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    };
    const stored_header = [_]u8{ 0x01, 0x1d, 0x08, 0xe2, 0xf7 };
    @memcpy(prefix[0..10], &gzip_header);
    @memcpy(prefix[10..15], &stored_header);
    var offset: usize = 0;
    const receive_bytes: usize = fixture.test_limits.receive_buffer_bytes;
    while (offset < prefix.len) : (offset += receive_bytes) {
        const end = offset + receive_bytes;
        _ = try harness.base.receive(connection, prefix[offset..end], false);
    }
    const record = &harness.base.storage.connections[connection];
    try std.testing.expect(record.receive_flags.gzip_paused);
    try std.testing.expect(!try harness.base.driver.resumeReceive(connection));
    try std.testing.expect(record.receive_token == null);

    TestPool.TestAccess.pauseDecode(false);
    try harness.dispatchOne();
    try std.testing.expect(record.receive_token != null);
    try std.testing.expect(!harness.base.io.operation(record.receive_token.?).?.receive.multishot);

    _ = try harness.base.driver.stop(connection);
    try harness.dispatchUntilIdle();
    try harness.base.drainClosing(connection);
}

test "gzip output rejection discards active receive without recovery or rearm" {
    const cases = [_]enum { bytes, eof, buffer_exhausted }{
        .bytes,
        .eof,
        .buffer_exhausted,
    };
    for (cases, 121..) |case, socket| {
        var harness: GzipHarness = undefined;
        try harness.init();
        defer harness.deinit();
        TestPool.TestAccess.pauseDecode(true);
        defer TestPool.TestAccess.pauseDecode(false);
        const connection_index = try harness.base.addConnection(socket);
        _ = try harness.base.receive(connection_index, gzip_head, false);
        try waitDecodePaused();

        const connection = &harness.base.storage.connections[connection_index];
        connection.receive_flags.gzip_rejecting = true;
        switch (case) {
            .bytes => _ = try harness.base.receive(connection_index, "discard", false),
            .eof => _ = try harness.base.endOfStream(connection_index),
            .buffer_exhausted => {
                const token = connection.receive_token.?;
                _ = try harness.base.complete(
                    token,
                    .{ .failure = .buffer_exhausted },
                    false,
                );
            },
        }
        try std.testing.expect(connection.phase == .receiving_body);
        try std.testing.expect(connection.receive_token == null);
        try std.testing.expect(!connection.receive_flags.paused);
        try std.testing.expect(!connection.receive_flags.gzip_paused);
        try std.testing.expect(connection.receive_flags.gzip_rejecting);
        try std.testing.expect(!try harness.base.driver.resumeReceive(connection_index));
        try std.testing.expect(connection.send_token == null);

        TestPool.TestAccess.pauseDecode(false);
        _ = try harness.base.driver.stop(connection_index);
        try std.testing.expect(!connection.receive_flags.gzip_rejecting);
        try harness.dispatchUntilIdle();
        try harness.base.drainClosing(connection_index);
    }
}

test "gzip close waits when network completions beat decoder terminal" {
    var harness: GzipHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const connection = try harness.base.addConnection(98);
    _ = try harness.base.receive(
        connection,
        gzip_head ++ gzip_abcdef[0..10].*,
        false,
    );
    _ = try harness.base.driver.stop(connection);

    try drainNetwork(&harness.base, connection);
    try std.testing.expectEqual(@as(u16, 0), harness.base.io.activeCount());
    try std.testing.expect(
        harness.base.storage.connections[connection].active_request != null,
    );
    try std.testing.expect(
        harness.base.storage.connections[connection].phase == .closing,
    );

    try harness.dispatchUntilIdle();
    try std.testing.expect(harness.base.storage.connections[connection].phase == .free);
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.aborted);
}

test "gzip short eof and body timeout cancel then close without response" {
    const Cause = enum { eof, timeout };
    const causes = [_]Cause{ .eof, .timeout };
    for (causes, 99..) |cause, socket| {
        var harness: GzipHarness = undefined;
        try harness.init();
        defer harness.deinit();
        const connection = try harness.base.addConnection(socket);
        _ = try harness.base.receive(
            connection,
            gzip_head ++ gzip_abcdef[0..10].*,
            false,
        );
        switch (cause) {
            .eof => _ = try harness.base.endOfStream(connection),
            .timeout => {
                const record = &harness.base.storage.connections[connection];
                const timeout = record.timeout_token.?;
                harness.base.now_ns = record.timeout_deadline_ns;
                _ = try harness.base.complete(
                    timeout,
                    .{ .success = .{ .timeout = {} } },
                    false,
                );
            },
        }
        try std.testing.expect(
            harness.base.storage.connections[connection].send_token == null,
        );
        try harness.dispatchUntilIdle();
        try harness.base.drainClosing(connection);
        try std.testing.expectEqual(@as(u8, 1), harness.base.state.aborted);
    }
}

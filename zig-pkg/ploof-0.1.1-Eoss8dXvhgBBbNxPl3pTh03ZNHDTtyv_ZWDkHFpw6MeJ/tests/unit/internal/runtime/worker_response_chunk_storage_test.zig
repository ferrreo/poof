const std = @import("std");
const application = @import("../../../../src/application.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const connection_response_transport = @import(
    "../../../../src/internal/runtime/connection/response_transport.zig",
);
const connection_send = @import("../../../../src/internal/runtime/connection/send.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const worker_emergency = @import("../../../../src/internal/runtime/worker/emergency.zig");
const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

const TestApp = struct {
    pub const Workspace = struct { marker: u64 = 7 };

    pub fn abort(_: *Workspace) error{}!void {}

    pub fn __scrubPreparedHead(workspace: *Workspace, _: []const u8) void {
        workspace.marker = 0;
    }
};

const limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .response_chunk_count = 3,
    .submission_entries = 8,
    .completion_entries = 16,
});

const Storage = worker_storage.Storage(TestApp, limits);
const TransportError = error{ StateInvariant, InvalidCompletion };
const ResponseTransport = connection_response_transport.Transport(
    TestApp,
    Storage,
    TransportError,
);

const TestOperations = struct {
    submitted: []const u8 = "",

    pub fn cancelReceive(_: *TestOperations, _: *Storage, _: u16) TransportError!void {}

    pub fn retargetTimeout(
        _: *TestOperations,
        _: *Storage,
        _: u16,
        _: u64,
        _: u64,
    ) TransportError!void {}

    pub fn extendTimeoutDeadline(
        _: *Storage,
        _: u16,
        _: u64,
        _: u64,
    ) TransportError!void {}

    pub fn submitSend(
        self: *TestOperations,
        _: *Storage,
        _: u16,
        bytes: []const u8,
    ) TransportError!void {
        self.submitted = bytes;
    }
};

const TestDriver = struct {
    storage: *Storage,
    operations: TestOperations = .{},
    close_called: bool = false,

    pub fn beginClose(self: *TestDriver, _: u16) TransportError!void {
        self.close_called = true;
    }
};

test "finite response transport adopts exactly one owned chunk chain" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    var writer = storage.responseChunkWriter(16);
    try writer.write("chunk transport");
    const chain = try writer.finish();
    var driver = TestDriver{ .storage = &storage };
    try ResponseTransport.begin(
        &driver,
        connection,
        request,
        chunkPrepared(chain, "head"),
        false,
        "",
        .borrowed,
        1,
    );
    try std.testing.expectEqual(@as(u64, 0), storage.requests[request].workspace.marker);
    try std.testing.expectEqualStrings("head", driver.operations.submitted);
    try std.testing.expectEqual(worker_storage.ResponseSource.chunks, storage.responseSource(
        request,
    ));
    storage.releaseRequest(connection, request);
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());

    const next_connection = storage.acquireConnection(.{ .value = 11 }).?;
    const next_request = storage.acquireRequest(next_connection).?;
    var invalid_writer = storage.responseChunkWriter(8);
    try invalid_writer.write("invalid");
    const invalid_chain = try invalid_writer.finish();
    try std.testing.expectError(error.StateInvariant, ResponseTransport.begin(
        &driver,
        next_connection,
        next_request,
        chunkPrepared(invalid_chain, ""),
        false,
        "",
        .borrowed,
        2,
    ));
    try std.testing.expect(driver.close_called);
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());
    storage.releaseRequest(next_connection, next_request);

    const stream_connection = storage.acquireConnection(.{ .value = 12 }).?;
    const stream_request = storage.acquireRequest(stream_connection).?;
    var stream_writer = storage.responseChunkWriter(8);
    try stream_writer.write("stream");
    var invalid_stream = chunkPrepared(try stream_writer.finish(), "head");
    invalid_stream.transmission = .{ .stream = .{
        .framing = .{
            .framing = .chunked,
            .send_body = true,
            .invoke_stream = true,
            .emit_content_type = true,
            .emit_trailers = false,
        },
        .trailers = .{ .emitted = false, .declarations = &.{}, .fingerprint = 0 },
    } };
    driver.close_called = false;
    try std.testing.expectError(error.StateInvariant, ResponseTransport.begin(
        &driver,
        stream_connection,
        stream_request,
        invalid_stream,
        false,
        "",
        .borrowed,
        3,
    ));
    try std.testing.expect(driver.close_called);
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());
    storage.releaseRequest(stream_connection, stream_request);
}

test "malformed empty chunk metadata cannot masquerade as internal storage" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    storage.requests[request].response_chain.head = 0;
    try std.testing.expectEqual(worker_storage.ResponseSource.chunks, storage.responseSource(
        request,
    ));
    try std.testing.expectEqual(
        worker_storage.RequestReleaseIssue.response_range_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].response_chain = .{};
    storage.releaseRequest(connection, request);
}

test "worker chunk response survives partial sends across chunk boundaries" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;

    var full_chunk = [_]u8{'a'} ** config.response_chunk_bytes;
    var writer = storage.responseChunkWriter(config.response_chunk_bytes + 4);
    try writer.write(&full_chunk);
    try writer.write("tail");
    const chain = try writer.finish();
    try std.testing.expect(storage.commitResponseChunks(request, "head", chain));
    try std.testing.expectEqual(
        worker_storage.ResponseSource.chunks,
        storage.responseSource(request),
    );
    try std.testing.expect(storage.responseChunkStateValid(request));
    try std.testing.expectEqualSlices(
        u8,
        "head",
        try connection_send.bytes(&storage, connection),
    );

    const first = try sendToken(&storage, connection, 1);
    storage.connections[connection].send_token = first;
    try expectSendResult(.partial, &storage, connection, first, 4);
    try std.testing.expectEqualSlices(
        u8,
        &full_chunk,
        try connection_send.bytes(&storage, connection),
    );

    const second = try sendToken(&storage, connection, 2);
    storage.connections[connection].send_token = second;
    try expectSendResult(.partial, &storage, connection, second, 1000);
    try std.testing.expectEqual(
        @as(usize, config.response_chunk_bytes - 1000),
        (try connection_send.bytes(&storage, connection)).len,
    );

    const third = try sendToken(&storage, connection, 3);
    storage.connections[connection].send_token = third;
    try expectSendResult(
        .partial,
        &storage,
        connection,
        third,
        config.response_chunk_bytes - 1000,
    );
    try std.testing.expectEqualStrings("tail", try connection_send.bytes(&storage, connection));

    const fourth = try sendToken(&storage, connection, 4);
    storage.connections[connection].send_token = fourth;
    try expectSendResult(.buffer_complete, &storage, connection, fourth, 4);
    try std.testing.expect(storage.responseChunkStateValid(request));

    const head_start = @as(usize, chain.head) * config.response_chunk_bytes;
    const tail_start = @as(usize, chain.tail) * config.response_chunk_bytes;
    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** config.response_chunk_bytes),
        storage.response_chunks.storage[head_start..][0..config.response_chunk_bytes],
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 4),
        storage.response_chunks.storage[tail_start..][0..4],
    );
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());

    const reused = storage.acquireRequest(connection).?;
    try std.testing.expectEqual(request, reused);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.internal,
        storage.responseSource(reused),
    );
    storage.releaseRequest(connection, reused);
}

test "shared response chunk exhaustion is transactional across requests" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const first_connection = storage.acquireConnection(.{ .value = 10 }).?;
    const second_connection = storage.acquireConnection(.{ .value = 11 }).?;
    const first_request = storage.acquireRequest(first_connection).?;
    const second_request = storage.acquireRequest(second_connection).?;

    var two_chunks = [_]u8{'x'} ** (config.response_chunk_bytes + 1);
    var first_writer = storage.responseChunkWriter(two_chunks.len);
    try first_writer.write(&two_chunks);
    const first_chain = try first_writer.finish();
    try std.testing.expect(storage.commitResponseChunks(first_request, "head", first_chain));

    var second_writer = storage.responseChunkWriter(1);
    try second_writer.write("y");
    const second_chain = try second_writer.finish();
    try std.testing.expect(storage.commitResponseChunks(second_request, "head", second_chain));
    try std.testing.expectEqual(@as(u16, 0), storage.response_chunks.available());

    var exhausted = storage.responseChunkWriter(1);
    try std.testing.expectError(error.ResponseChunksExhausted, exhausted.write("z"));
    try std.testing.expectEqual(@as(u16, 0), storage.response_chunks.available());
    storage.releaseRequest(first_connection, first_request);
    try std.testing.expectEqual(@as(u16, 2), storage.response_chunks.available());
    storage.releaseRequest(second_connection, second_request);
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());
}

test "fatal worker cleanup clears chunk bytes and restores pool ownership" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    var writer = storage.responseChunkWriter(32);
    try writer.write("fatal response secret");
    const chain = try writer.finish();
    try std.testing.expect(storage.commitResponseChunks(request, "head", chain));

    const status = worker_emergency.abortAll(TestApp, &storage);
    try std.testing.expectEqual(@as(u16, 1), status.workspace_attempts);
    try std.testing.expectEqual(@as(u16, 0), status.workspace_failures);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** (3 * config.response_chunk_bytes)),
        storage.response_chunks.storage,
    );
    worker_emergency.releaseAllRecords(&storage);
    try std.testing.expectEqual(@as(u16, 3), storage.response_chunks.available());
    try std.testing.expectEqual(@as(u16, 0), storage.response_chunks.live_chunks);

    const reused_connection = storage.acquireConnection(.{ .value = 11 }).?;
    const reused_request = storage.acquireRequest(reused_connection).?;
    try std.testing.expectEqual(worker_storage.ResponseSource.internal, storage.responseSource(
        reused_request,
    ));
    storage.releaseRequest(reused_connection, reused_request);
}

fn expectSendResult(
    expected: connection_send.Result,
    storage: *Storage,
    connection: u16,
    token: reactor.OperationToken,
    sent: u32,
) !void {
    const result = try connection_send.handle(storage, connection, .{
        .token = token,
        .result = .{ .success = .{ .send = sent } },
        .more = false,
    });
    try std.testing.expectEqual(expected, result);
}

fn chunkPrepared(
    chain: @import("../../../../src/internal/response/chunk_chain.zig").Chain,
    bytes: []const u8,
) application.Prepared {
    return .{
        .source = .{ .finite_chain = .{ .head = bytes, .body = chain } },
        .bytes = "",
        .status = .ok,
        .close_connection = true,
        .coding_outcome = .identity_disabled,
    };
}

fn sendToken(storage: *const Storage, connection: u16, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = connection,
        .slot_generation = storage.connections[connection].generation,
        .sequence = sequence,
    });
}

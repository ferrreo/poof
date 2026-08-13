const source = @import("worker_storage_test.zig");
const std = source.std;
const address = source.address;
const body = source.body;
const forwarding = source.forwarding;
const config = source.config;
const connection_send = source.connection_send;
const connection_chunked_body = source.connection_chunked_body;
const event_counter = source.event_counter;
const memory_budget = source.memory_budget;
const reactor = source.reactor;
const worker_emergency = source.worker_emergency;
const worker_storage = source.worker_storage;
const BodyResetIssue = source.BodyResetIssue;
const ConnectionPhase = source.ConnectionPhase;
const ConnectionReleaseIssue = source.ConnectionReleaseIssue;
const RequestReleaseIssue = source.RequestReleaseIssue;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const BodyTestApp = source.BodyTestApp;
const body_test_limits = source.body_test_limits;
const ExternalTestApp = source.ExternalTestApp;
const external_test_limits = source.external_test_limits;
const chunked_one_limits = source.chunked_one_limits;
const chunked_two_limits = source.chunked_two_limits;
const gzip_two_limits = source.gzip_two_limits;
const LayoutTestApp = source.LayoutTestApp;
const StreamTestApp = source.StreamTestApp;
const acquired = source.acquired;
const sendToken = source.sendToken;
const expectAcquireIssue = source.expectAcquireIssue;

test "body workspace reset rejects running and quiesced gzip decoder pools" {
    const Storage = worker_storage.Storage(BodyTestApp, gzip_two_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);

    const pool = storage.gzipPool().?;
    try std.testing.expectEqual(@as(?BodyResetIssue, null), storage.bodyResetIssue());
    storage.resetBodyWorkspaces();

    try pool.start(config.gzip_thread_stack_bytes_min);
    defer {
        if (pool.lifecycleStatus() == .running) _ = pool.beginStop();
        if (pool.lifecycleStatus() == .quiesced) _ = pool.finishStop() catch null;
    }
    try std.testing.expectEqual(
        BodyResetIssue.gzip_decoder_active,
        storage.bodyResetIssue().?,
    );

    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.beginStop());
    try std.testing.expectEqual(
        BodyResetIssue.gzip_decoder_active,
        storage.bodyResetIssue().?,
    );

    try std.testing.expectEqual(
        @as(?event_counter.Failure, null),
        try pool.finishStop(),
    );
    try std.testing.expectEqual(@as(?BodyResetIssue, null), storage.bodyResetIssue());
    storage.resetBodyWorkspaces();
}

test "active gzip lease blocks release and uncommitted borrows clear full storage" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));
    _ = try storage.bodyReadable(request);
    try std.testing.expect(!storage.requests[request].body.dirty_full);
    const writable = try storage.bodyWritable(request);
    const response = storage.responseWritable(request);
    @memset(writable, 0xa5);
    @memset(response, 0x5a);
    try std.testing.expect(storage.requests[request].body.dirty_full);
    try std.testing.expect(storage.requests[request].flags.response_dirty_full);
    storage.requests[request].gzip_lease = .{ .index = 0, .generation = 1 };
    try std.testing.expectEqual(
        RequestReleaseIssue.gzip_decoder_active,
        storage.requestReleaseIssue(connection, request).?,
    );
    try std.testing.expectError(error.GzipDecoderActive, storage.releaseUnusedBody(request));

    storage.requests[request].gzip_lease = null;
    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), writable);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), storage.responseReadable(request));
}

test "successful body commit clears only committed bytes after dirty decode" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));
    const writable = try storage.bodyWritable(request);
    @memset(writable, 0xa5);
    try storage.commitBody(request, 3);
    try std.testing.expect(!storage.requests[request].body.dirty_full);
    try std.testing.expect(!storage.requests[request].body.tainted_full);
    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 3), writable[0..3]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 5), writable[3..]);
}

test "full body workspace taint survives commit and clears before reuse" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));
    const workspace = try storage.bodyWorkspace(request);
    @memset(workspace, 0xa5);
    try storage.commitBody(request, 3);
    try std.testing.expect(!storage.requests[request].body.dirty_full);
    try std.testing.expect(storage.requests[request].body.tainted_full);

    const workspace_index = storage.requests[request].body.workspace_index.?;
    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), workspace);

    const reused = try acquired(storage.acquireRequestClassified(connection, 1, false));
    try std.testing.expectEqual(
        workspace_index,
        storage.requests[reused].body.workspace_index.?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 8),
        try storage.bodyWorkspace(reused),
    );
    storage.releaseRequest(connection, reused);
}

test "worker slots exhaust and reuse released indices in LIFO order" {
    const TestStorage = worker_storage.Storage(TestApp, test_limits);
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    const connection_0 = storage.acquireConnection(.{ .value = 10 }).?;
    const connection_1 = storage.acquireConnection(.{ .value = 11 }).?;
    const connection_2 = storage.acquireConnection(.{ .value = 12 }).?;
    try std.testing.expectEqual(@as(u16, 0), connection_0);
    try std.testing.expectEqual(@as(u16, 1), connection_1);
    try std.testing.expectEqual(@as(u16, 2), connection_2);
    try std.testing.expectEqual(@as(?u16, null), storage.acquireConnection(.{ .value = 13 }));

    const request_0 = storage.acquireRequest(connection_0).?;
    const request_1 = storage.acquireRequest(connection_1).?;
    try std.testing.expectEqual(@as(u16, 0), request_0);
    try std.testing.expectEqual(@as(u16, 1), request_1);
    try std.testing.expectEqual(@as(?u16, null), storage.acquireRequest(connection_2));

    storage.releaseRequest(connection_0, request_0);
    storage.connections[connection_0].phase = .closing;
    storage.connections[connection_0].receive_terminal_reaped = true;
    storage.connections[connection_0].socket_closed = true;
    storage.releaseConnection(connection_0);
    try std.testing.expectEqual(@as(?u16, connection_0), storage.acquireConnection(.{
        .value = 14,
    }));
    try std.testing.expectEqual(
        ConnectionPhase.first_head,
        storage.connections[connection_0].phase,
    );
    try std.testing.expectEqual(@as(usize, 0), storage.connections[0].head_decoder.bytes().len);
    try std.testing.expectEqual(@as(?u16, request_0), storage.acquireRequest(connection_0));
}

test "body class exhaustion rolls back request and leaves class zero available" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    try std.testing.expectEqual(@as(u16, 2), Storage.workspace_class_count);
    try std.testing.expectEqual(@as(u32, 8), Storage.body_workspace_bytes_per_slot);
    try std.testing.expectEqual(@as(usize, 1), storage.body_workspaces.free_indices.len);
    try std.testing.expectEqual(@as(usize, 8), storage.body_workspaces.storage.len);
    const first = storage.acquireConnection(.{ .value = 10 }).?;
    const second = storage.acquireConnection(.{ .value = 11 }).?;
    const third = storage.acquireConnection(.{ .value = 12 }).?;
    const body_request = try acquired(storage.acquireRequestClassified(first, 1, false));
    try std.testing.expectEqual(@as(u16, 0), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.request_pool.available());

    try expectAcquireIssue(
        .body_workspace_exhausted,
        storage.acquireRequestClassified(second, 1, false),
    );
    try std.testing.expectEqual(@as(u16, 1), storage.request_pool.available());
    try std.testing.expect(storage.connections[second].active_request == null);

    const bodyless_request = try acquired(storage.acquireRequestClassified(second, 0, false));
    try expectAcquireIssue(
        .request_slots_exhausted,
        storage.acquireRequestClassified(third, 0, false),
    );
    storage.releaseRequest(second, bodyless_request);

    const writable = try storage.bodyWritable(body_request);
    @memcpy(writable[0..6], "secret");
    try storage.commitBody(body_request, 6);
    const decoded = try storage.finishBody(body_request, .bytes);
    const bytes = switch (decoded) {
        .bytes => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(bytes.eql("secret"));
    const used_region = writable[0..6];
    storage.releaseRequest(first, body_request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 6), used_region);
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
}

test "chunked exhaustion rolls back body and request leases then reuses slot" {
    const Storage = worker_storage.Storage(BodyTestApp, chunked_one_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const first = storage.acquireConnection(.{ .value = 10 }).?;
    const second = storage.acquireConnection(.{ .value = 11 }).?;
    const first_request = try acquired(storage.acquireRequestClassified(first, 1, true));
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 0), storage.chunkedWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.request_pool.available());

    try expectAcquireIssue(
        .chunked_workspace_exhausted,
        storage.acquireRequestClassified(second, 1, true),
    );
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 0), storage.chunkedWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.request_pool.available());
    try std.testing.expect(storage.connections[second].active_request == null);

    const bodyless = try acquired(storage.acquireRequestClassified(second, 0, false));
    try std.testing.expect(storage.requests[bodyless].chunked_workspace_index == null);
    try std.testing.expect(storage.requests[bodyless].body.workspace_index == null);
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
    storage.releaseRequest(second, bodyless);

    const state_bytes = std.mem.asBytes(try storage.chunkedState(first_request));
    @memset(state_bytes, 0xa5);
    storage.releaseRequest(first, first_request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9736), state_bytes);
    try std.testing.expectEqual(@as(u16, 2), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.chunkedWorkspaceAvailable());

    const reused = try acquired(storage.acquireRequestClassified(first, 1, true));
    try std.testing.expectEqual(@as(?u16, 0), storage.requests[reused].chunked_workspace_index);
    storage.releaseRequest(first, reused);
}

test "unused chunked body releases and clears both pooled workspaces" {
    const Storage = worker_storage.Storage(BodyTestApp, chunked_one_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, true));
    const state_bytes = std.mem.asBytes(try storage.chunkedState(request));
    @memset(state_bytes, 0x5a);

    try std.testing.expect(try storage.releaseUnusedBody(request));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9736), state_bytes);
    try std.testing.expect(storage.requests[request].chunked_workspace_index == null);
    try std.testing.expect(storage.requests[request].body.workspace_index == null);
    try std.testing.expectEqual(@as(u16, 2), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.chunkedWorkspaceAvailable());
    try std.testing.expect(!(try storage.releaseUnusedBody(request)));
    storage.releaseRequest(connection, request);
}

test "body workspace bounds and request-owned decoded descriptor are stable" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const first = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(first, 1, false));
    const writable = try storage.bodyWritable(request);
    try std.testing.expectEqual(@as(usize, 8), writable.len);
    try std.testing.expectError(error.BodyWorkspaceOverflow, storage.commitBody(request, 9));
    @memcpy(writable[0..3], "h\xc3\xa9");
    try storage.commitBody(request, 3);
    const decoded = try storage.finishBody(request, .text);
    const text = switch (decoded) {
        .text => |value| value,
        else => return error.TestUnexpectedResult,
    };
    @memset(storage.responseWritable(request)[0..8], 0xa5);
    try std.testing.expect(text.eql("h\xc3\xa9"));
    storage.releaseRequest(first, request);

    const invalid = try acquired(storage.acquireRequestClassified(first, 1, false));
    const invalid_writable = try storage.bodyWritable(invalid);
    invalid_writable[0] = 0xff;
    try storage.commitBody(invalid, 1);
    try std.testing.expectError(error.InvalidUtf8, storage.finishBody(invalid, .text));
    storage.releaseRequest(first, invalid);

    const bodyless = storage.acquireRequest(first).?;
    try std.testing.expectError(
        error.BodyWorkspaceNotLeased,
        storage.bodyWritable(bodyless),
    );
    storage.releaseRequest(first, bodyless);
}

test "fatal shutdown clears body slabs and resets both pools" {
    const Storage = worker_storage.Storage(BodyTestApp, chunked_one_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, true));
    const writable = try storage.bodyWritable(request);
    @memset(writable, 0xa5);
    try storage.commitBody(request, 6);
    const chunked_state = std.mem.asBytes(try storage.chunkedState(request));
    @memset(chunked_state, 0x5a);

    const status = worker_emergency.abortAll(BodyTestApp, &storage);
    try std.testing.expectEqual(@as(u16, 1), status.workspace_attempts);
    try std.testing.expectEqual(@as(u16, 0), status.workspace_failures);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), writable);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9736), chunked_state);
    try std.testing.expectEqual(@as(u16, 2), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(u16, 1), storage.chunkedWorkspaceAvailable());
    try std.testing.expect(storage.requests[request].chunked_workspace_index == null);
    worker_emergency.releaseAllRecords(&storage);
    try std.testing.expectEqual(@as(u16, 2), storage.request_pool.available());
}

test "body release validation rejects corrupted lease metadata" {
    const Storage = worker_storage.Storage(BodyTestApp, body_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));
    const invalid = worker_storage.BodyAcquireResult.invalid_request;
    const metadata = RequestReleaseIssue.body_metadata_without_workspace;

    storage.requests[request].body.workspace_index = null;
    storage.requests[request].body.used = 1;
    try std.testing.expectEqual(invalid, storage.acquireBodyClassified(request, 1, false));
    try std.testing.expectEqual(metadata, storage.requestReleaseIssue(connection, request).?);
    try std.testing.expectError(error.BodyWorkspaceNotLeased, storage.releaseUnusedBody(request));
    storage.requests[request].body.used = 0;
    storage.requests[request].body.dirty_full = true;
    try std.testing.expectEqual(invalid, storage.acquireBodyClassified(request, 1, false));
    try std.testing.expectEqual(metadata, storage.requestReleaseIssue(connection, request).?);
    try std.testing.expectError(error.BodyWorkspaceNotLeased, storage.releaseUnusedBody(request));
    storage.requests[request].body.dirty_full = false;
    storage.requests[request].body.tainted_full = true;
    try std.testing.expectEqual(invalid, storage.acquireBodyClassified(request, 1, false));
    try std.testing.expectEqual(metadata, storage.requestReleaseIssue(connection, request).?);
    try std.testing.expectError(error.BodyWorkspaceNotLeased, storage.releaseUnusedBody(request));
    storage.requests[request].body.tainted_full = false;
    storage.requests[request].body.workspace_index = 0;

    storage.requests[request].body.used = 9;
    try std.testing.expectEqual(
        RequestReleaseIssue.body_range_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.used = 0;
    storage.requests[request].body.workspace_index = 1;
    try std.testing.expectEqual(
        RequestReleaseIssue.body_workspace_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.workspace_index = 0;
    storage.requests[request].chunked_workspace_index = 1;
    try std.testing.expectEqual(
        RequestReleaseIssue.chunked_workspace_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    try std.testing.expectError(
        error.ChunkedWorkspaceNotLeased,
        storage.chunkedState(request),
    );
    storage.requests[request].chunked_workspace_index = null;
    storage.releaseRequest(connection, request);
}

test {
    _ = @import("worker_response_chunk_storage_test.zig");
}

test "accepted transport peer is normalized and retained independently" {
    const Storage = worker_storage.Storage(TestApp, test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const mapped = [16]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 203, 0, 113, 7,
    };
    const connection = storage.acquireAcceptedConnection(.{
        .socket = .{ .value = 77 },
        .peer = address.Endpoint.initIpv6(mapped, 65_535),
    }).?;
    try std.testing.expectEqual(@as(u64, 77), storage.connections[connection].socket.value);
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv4(.{ 203, 0, 113, 7 }, 65_535),
        storage.connections[connection].transport_peer,
    );
    try std.testing.expect(storage.connections[connection].connection_peer.eql(
        storage.connections[connection].transport_peer,
    ));
    try std.testing.expectEqual(
        forwarding.ConnectionSource.transport,
        storage.connections[connection].connection_source,
    );
    try std.testing.expect(storage.connections[connection].proxy_destination == null);
}

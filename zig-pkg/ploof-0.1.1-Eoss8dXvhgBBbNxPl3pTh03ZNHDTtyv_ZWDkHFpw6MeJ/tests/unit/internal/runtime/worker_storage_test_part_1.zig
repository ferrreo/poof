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
const ResponseOnlyTestApp = source.ResponseOnlyTestApp;
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

test "release clears used bytes resets workspace and advances generation" {
    const TestStorage = worker_storage.Storage(TestApp, test_limits);
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);

    const connection_index = storage.acquireConnection(.{ .value = 10 }).?;
    const request_index = storage.acquireRequest(connection_index).?;
    const workspace_address = @intFromPtr(&storage.requests[request_index].workspace);
    const connection_generation = storage.connections[connection_index].generation;
    const request_generation = storage.requests[request_index].generation;
    const wire = "GET /secret HTTP/1.1\r\nHost: example.test\r\n\r\n";
    switch (storage.connections[connection_index].head_decoder.feed(wire).state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    const raw_head = @constCast(
        storage.connections[connection_index].head_decoder.bytes(),
    );

    @memset(storage.decodedPath(connection_index)[0..5], 0xa5);
    @memset(storage.responseWritable(request_index)[0..7], 0x5a);
    @memset(storage.pipeline(connection_index)[0..9], 0xcc);
    storage.connections[connection_index].decoded_path_used = 5;
    storage.connections[connection_index].pipeline_write = 3;
    storage.connections[connection_index].pipeline_high_water = 9;
    storage.requests[request_index].response_used = 7;
    storage.requests[request_index].response_sent = 3;
    @memset(std.mem.asBytes(&storage.requests[request_index].workspace), 0xa5);
    storage.requests[request_index].workspace.marker = 99;

    storage.releaseRequest(connection_index, request_index);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** wire.len), raw_head);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 5),
        storage.decodedPath(0)[0..5],
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 7),
        storage.responseReadable(0)[0..7],
    );
    try std.testing.expectEqual(@as(u64, 7), storage.requests[request_index].workspace.marker);
    try std.testing.expect(std.mem.indexOfScalar(
        u8,
        std.mem.asBytes(&storage.requests[request_index].workspace),
        0xa5,
    ) == null);
    try std.testing.expectEqual(
        reactor.nextGeneration(request_generation),
        storage.requests[request_index].generation,
    );
    try std.testing.expectEqual(workspace_address, @intFromPtr(&storage.requests[0].workspace));

    storage.connections[connection_index].phase = .responding;
    storage.reuseConnection(connection_index);
    try std.testing.expectEqual(
        ConnectionPhase.keepalive_idle,
        storage.connections[connection_index].phase,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        storage.connections[connection_index].head_decoder.bytes().len,
    );
    storage.connections[connection_index].phase = .closing;
    storage.connections[connection_index].receive_terminal_reaped = true;
    storage.connections[connection_index].socket_closed = true;
    storage.releaseConnection(connection_index);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9), storage.pipeline(0)[0..9]);
    try std.testing.expectEqual(
        reactor.nextGeneration(connection_generation),
        storage.connections[connection_index].generation,
    );
    try std.testing.expect(storage.connections[connection_index].generation != 0);
    try std.testing.expect(storage.connections[connection_index].sequence != 0);
    try std.testing.expect(storage.requests[request_index].generation != 0);
    try std.testing.expect(storage.requests[request_index].sequence != 0);
}

test "response release clears the largest committed buffer" {
    const TestStorage = worker_storage.Storage(TestApp, test_limits);
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);

    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    const first = storage.responseWritable(request);
    @memset(first, 0);
    @memset(first[0..24], 0xa5);
    try std.testing.expect(storage.commitResponse(request, first[0..24]));
    const second = storage.responseWritable(request);
    @memset(second[0..5], 0x5a);
    try std.testing.expect(storage.commitResponse(request, second[0..5]));
    try std.testing.expectEqual(
        @as(u32, 24),
        storage.requests[request].response_high_water,
    );

    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 24),
        storage.responseReadable(request)[0..24],
    );
}

test "external response source supports partial send and secure slot reuse" {
    const Storage = worker_storage.Storage(ExternalTestApp, external_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));

    const internal = storage.responseWritable(request);
    @memset(internal, 0xa5);
    const workspace = try storage.bodyWritable(request);
    for (workspace, 0..) |*byte, index| byte.* = @truncate(index + 1);
    const external = workspace[4..44];
    try std.testing.expect(storage.commitExternalResponse(request, external));
    try std.testing.expectEqual(
        worker_storage.ResponseSource.body_workspace,
        storage.responseSource(request),
    );
    try std.testing.expectEqual(@as(u32, 5), storage.requests[request]
        .body.response_source_offset);
    try std.testing.expectEqual(@as(u32, 40), storage.requests[request].response_used);
    try std.testing.expect(storage.requests[request].flags.response_dirty_full);
    try std.testing.expect(storage.requests[request].body.dirty_full);
    try std.testing.expectEqualSlices(u8, external, storage.responseReadable(request));
    try std.testing.expectError(error.BodyWorkspaceNotEmpty, storage.releaseUnusedBody(request));

    const first = try sendToken(&storage, connection, 1);
    storage.connections[connection].send_token = first;
    try std.testing.expectEqual(connection_send.Result.partial, try connection_send.handle(
        &storage,
        connection,
        .{ .token = first, .result = .{ .success = .{ .send = 7 } }, .more = false },
    ));
    try std.testing.expectEqualSlices(
        u8,
        external[7..],
        try connection_send.bytes(&storage, connection),
    );

    const second = try sendToken(&storage, connection, 2);
    storage.connections[connection].send_token = second;
    try std.testing.expectEqual(connection_send.Result.buffer_complete, try connection_send.handle(
        &storage,
        connection,
        .{ .token = second, .result = .{ .success = .{ .send = 33 } }, .more = false },
    ));
    try std.testing.expect(storage.requestReleaseIssue(connection, request) == null);

    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 48), workspace);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), storage.responseRegion(request));
    try std.testing.expectEqual(@as(u16, 2), storage.bodyWorkspaceAvailable());

    const reused = try acquired(storage.acquireRequestClassified(connection, 1, false));
    try std.testing.expectEqual(request, reused);
    try std.testing.expectEqual(
        worker_storage.ResponseSource.internal,
        storage.responseSource(reused),
    );
    try std.testing.expectEqual(@as(u32, 0), storage.requests[reused]
        .body.response_source_offset);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 48), try storage.bodyWritable(reused));
    storage.releaseRequest(connection, reused);
}

test "static response source copies only head and borrows immutable body" {
    const Storage = worker_storage.Storage(TestApp, test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    const head = "HTTP/1.1 200 OK\r\n\r\n";
    const static_body = "asset-body";

    const output = storage.responseWritable(request);
    @memset(output, 0xa5);
    @memcpy(output[0..head.len], head);
    try std.testing.expect(storage.commitStaticResponse(
        request,
        output[0..head.len],
        static_body,
    ));
    try std.testing.expectEqual(
        worker_storage.ResponseSource.static,
        storage.responseSource(request),
    );
    try std.testing.expectEqualStrings(head, try storage.responseSendReadable(request));
    var progress = try storage.planResponseProgress(request, head.len);
    storage.commitResponseProgress(request, progress);
    try std.testing.expectEqualStrings(static_body, try storage.responseSendReadable(request));
    progress = try storage.planResponseProgress(request, 3);
    storage.commitResponseProgress(request, progress);
    try std.testing.expectEqualStrings(static_body[3..], try storage.responseSendReadable(request));
    progress = try storage.planResponseProgress(request, static_body.len - 3);
    storage.commitResponseProgress(request, progress);
    try std.testing.expectEqualStrings("", try storage.responseSendReadable(request));
    try std.testing.expect(storage.requestReleaseIssue(connection, request) == null);

    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** 32),
        storage.responseRegion(request),
    );
    try std.testing.expectEqual(
        worker_storage.ResponseSource.internal,
        storage.responseSource(request),
    );
}

test "external response commit rejects empty foreign and crossing slices" {
    const Storage = worker_storage.Storage(ExternalTestApp, external_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const first_connection = storage.acquireConnection(.{ .value = 10 }).?;
    const second_connection = storage.acquireConnection(.{ .value = 11 }).?;
    const first = try acquired(storage.acquireRequestClassified(first_connection, 1, false));
    const second = try acquired(storage.acquireRequestClassified(second_connection, 1, false));
    try std.testing.expectEqual(@as(?u16, 0), storage.requests[first]
        .body.workspace_index);
    const first_workspace = try storage.bodyWritable(first);
    const second_workspace = try storage.bodyWritable(second);

    try std.testing.expect(!storage.commitExternalResponse(first, first_workspace[0..0]));
    try std.testing.expect(!storage.commitExternalResponse(first, second_workspace[0..1]));
    try std.testing.expect(!storage.commitExternalResponse(
        first,
        storage.body_workspaces.storage[47..49],
    ));
    try std.testing.expect(!storage.commitExternalResponse(
        first,
        storage.responseRegion(first)[0..1],
    ));
    try std.testing.expect(!storage.commitExternalResponse(
        @intCast(storage.requests.len),
        first_workspace[0..1],
    ));
    try std.testing.expect(storage.commitExternalResponse(first, first_workspace[47..48]));

    storage.releaseRequest(first_connection, first);
    storage.releaseRequest(second_connection, second);

    const Bodyless = worker_storage.Storage(TestApp, test_limits);
    var bodyless_slab: [Bodyless.required_bytes]u8 align(Bodyless.slab_alignment) = undefined;
    var bodyless: Bodyless = undefined;
    try bodyless.init(&bodyless_slab);
    const connection = bodyless.acquireConnection(.{ .value = 12 }).?;
    const request = bodyless.acquireRequest(connection).?;
    try std.testing.expect(!bodyless.commitExternalResponse(
        request,
        bodyless.responseRegion(request)[0..1],
    ));
    bodyless.releaseRequest(connection, request);
}

test "external response release validation uses its workspace bound" {
    const Storage = worker_storage.Storage(ExternalTestApp, external_test_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = try acquired(storage.acquireRequestClassified(connection, 1, false));
    const workspace = try storage.bodyWritable(request);
    try std.testing.expect(storage.commitExternalResponse(request, workspace[4..44]));
    try std.testing.expect(storage.requestReleaseIssue(connection, request) == null);

    const body_index = storage.requests[request].body.workspace_index.?;
    storage.requests[request].body.response_source_offset = 49;
    try std.testing.expectEqual(@as(usize, 0), storage.responseReadable(request).len);
    try std.testing.expectEqual(
        RequestReleaseIssue.response_range_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.response_source_offset = 5;

    storage.requests[request].body.workspace_index = null;
    try std.testing.expectEqual(
        RequestReleaseIssue.response_workspace_not_leased,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.workspace_index = body_index;

    storage.requests[request].body.dirty_full = false;
    storage.requests[request].body.tainted_full = false;
    try std.testing.expectEqual(
        RequestReleaseIssue.response_workspace_not_dirty,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.dirty_full = true;
    storage.requests[request].body.tainted_full = true;

    storage.requests[request].response_used = 0;
    try std.testing.expectEqual(
        RequestReleaseIssue.response_range_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].response_used = 40;

    storage.requests[request].body.response_source_offset = 0;
    try std.testing.expectEqual(
        RequestReleaseIssue.response_range_out_of_range,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].body.response_source_offset = 5;
    storage.releaseRequest(connection, request);
}

test "release checks exact ownership and detects repeated release" {
    const TestStorage = worker_storage.Storage(TestApp, test_limits);
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    const first = storage.acquireConnection(.{ .value = 10 }).?;
    const second = storage.acquireConnection(.{ .value = 11 }).?;
    const request = storage.acquireRequest(first).?;

    try std.testing.expectEqual(
        RequestReleaseIssue.wrong_connection,
        storage.requestReleaseIssue(second, request).?,
    );
    try std.testing.expectEqual(
        ConnectionReleaseIssue.request_still_active,
        storage.connectionReleaseIssue(first).?,
    );
    storage.releaseRequest(first, request);
    try std.testing.expectEqual(
        RequestReleaseIssue.request_not_live,
        storage.requestReleaseIssue(first, request).?,
    );
    try std.testing.expectEqual(
        ConnectionReleaseIssue.not_closing,
        storage.connectionReleaseIssue(first).?,
    );
    const receive_token = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 0,
        .slot_index = first,
        .slot_generation = storage.connections[first].generation,
        .sequence = storage.connections[first].sequence,
    });
    storage.connections[first].phase = .closing;
    storage.connections[first].receive_token = receive_token;
    storage.connections[first].inflight_operations = 1;
    try std.testing.expectEqual(
        ConnectionReleaseIssue.receive_active,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].receive_token = null;
    storage.connections[first].send_token = try reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = first,
        .slot_generation = storage.connections[first].generation,
        .sequence = reactor.nextSequence(storage.connections[first].sequence),
    });
    try std.testing.expectEqual(
        ConnectionReleaseIssue.send_active,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].send_token = null;
    try std.testing.expectEqual(
        ConnectionReleaseIssue.operations_inflight,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].inflight_operations = 0;
    storage.connections[first].timeout_token = try reactor.OperationToken.init(.{
        .kind = .timeout,
        .worker_index = 0,
        .slot_index = first,
        .slot_generation = storage.connections[first].generation,
        .sequence = reactor.nextSequence(storage.connections[first].sequence),
    });
    try std.testing.expectEqual(
        ConnectionReleaseIssue.timeout_active,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].timeout_token = null;
    storage.connections[first].close_token = try reactor.OperationToken.init(.{
        .kind = .close,
        .worker_index = 0,
        .slot_index = first,
        .slot_generation = storage.connections[first].generation,
        .sequence = reactor.nextSequence(reactor.nextSequence(
            storage.connections[first].sequence,
        )),
    });
    try std.testing.expectEqual(
        ConnectionReleaseIssue.close_active,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].close_token = null;
    try std.testing.expectEqual(
        ConnectionReleaseIssue.receive_terminal_not_reaped,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].receive_terminal_reaped = true;
    try std.testing.expectEqual(
        ConnectionReleaseIssue.socket_not_closed,
        storage.connectionReleaseIssue(first).?,
    );
    storage.connections[first].socket_closed = true;
    storage.releaseConnection(first);
    try std.testing.expectEqual(
        ConnectionReleaseIssue.not_live,
        storage.connectionReleaseIssue(first).?,
    );
}

test "worker slab honors over-aligned workspaces and rejects invalid slabs" {
    const TestStorage = worker_storage.Storage(TestApp, test_limits);
    try std.testing.expect(TestStorage.slab_alignment >= 64);
    try std.testing.expectEqual(
        @as(usize, 0),
        TestStorage.required_bytes % TestStorage.slab_alignment,
    );
    const Slab = [TestStorage.required_bytes + TestStorage.slab_alignment]u8;
    var slab: Slab align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try std.testing.expectError(
        error.SlabTooSmall,
        storage.init(slab[0 .. TestStorage.required_bytes - 1]),
    );
    try std.testing.expectError(
        error.SlabMisaligned,
        storage.init(slab[1 .. TestStorage.required_bytes + 1]),
    );
    try storage.init(slab[0..TestStorage.required_bytes]);
    try std.testing.expectEqual(@as(u16, 1), TestStorage.workspace_class_count);
    try std.testing.expectEqual(@as(u32, 0), TestStorage.body_workspace_bytes_per_slot);
    try std.testing.expectEqual(@as(u16, 0), TestStorage.gzip_decoder_thread_count);
    try std.testing.expectEqual(@as(usize, 0), TestStorage.gzip_decoder_control_bytes);
    try std.testing.expectEqual(@as(usize, 0), TestStorage.gzip_decoder_slot_bytes);
    try std.testing.expectEqual(@as(usize, 0), TestStorage.gzip_decoder_slots_bytes);
    try std.testing.expectEqual(@as(usize, 0), TestStorage.gzip_input_queue_bytes_per_slot);
    try std.testing.expectEqual(
        @as(usize, 0),
        TestStorage.gzip_output_mailbox_capacity_bytes_per_slot,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        TestStorage.gzip_output_mailbox_bytes_per_slot,
    );
    try std.testing.expectEqual(@as(u64, 0), TestStorage.gzip_decoder_requested_stack_bytes);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(storage.gzip_decoders)));
    try std.testing.expect(storage.gzipPool() == null);
    try std.testing.expectEqual(@as(?BodyResetIssue, null), storage.bodyResetIssue());
    try std.testing.expectEqual(@as(u16, 0), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(@as(usize, 3), storage.connections.len);
    try std.testing.expectEqual(@as(usize, 2), storage.requests.len);
    try std.testing.expectEqual(@as(usize, 3), storage.connection_free_indices.len);
    try std.testing.expectEqual(@as(usize, 2), storage.request_free_indices.len);
    try std.testing.expectEqual(@as(usize, 3 * 8 * 1024), storage.decoded_path_storage.len);
    try std.testing.expectEqual(@as(usize, 3 * 16), storage.pipeline_storage.len);
    try std.testing.expectEqual(@as(usize, 2 * 32), storage.response_storage.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(&storage.requests[0].workspace) % @alignOf(TestApp.Workspace),
    );
    const EmptyBackend = struct {
        pub const external_provided_buffer_bytes: u64 = 0;
    };
    const report = try memory_budget.callerOwned(u8, TestStorage, EmptyBackend);
    try std.testing.expectEqual(@as(u16, 0), report.decoder_thread_count);
    try std.testing.expectEqual(@as(u64, 0), report.decoder_requested_stack_bytes);
    try std.testing.expect(!report.decoder_thread_vm_overhead_unknown);
}

test "chunked workspace layout and memory report preserve exact bytes" {
    const One = worker_storage.Storage(LayoutTestApp, chunked_one_limits);
    const Two = worker_storage.Storage(LayoutTestApp, chunked_two_limits);
    const EmptyBackend = struct {
        pub const external_provided_buffer_bytes: u64 = 0;
    };

    try std.testing.expectEqual(@as(usize, 9736), @sizeOf(connection_chunked_body.State));
    // Each request also tracks its bounded response-chunk chain and send cursor.
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(One.Request));
    try std.testing.expectEqual(@as(usize, 2_506_432), One.required_bytes);
    try std.testing.expectEqual(@as(usize, 2_516_224), Two.required_bytes);
    try std.testing.expectEqual(@as(usize, 9792), Two.required_bytes - One.required_bytes);
    try std.testing.expectEqual(
        @sizeOf(connection_chunked_body.State),
        One.chunked_workspace_bytes_per_slot,
    );

    var slab: [One.required_bytes]u8 align(One.slab_alignment) = undefined;
    var storage: One = undefined;
    try storage.init(&slab);
    try std.testing.expectEqual(@as(usize, 1), storage.chunked_workspaces.states.len);
    try std.testing.expectEqual(@as(usize, 1), storage.chunked_workspaces.free_indices.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage.chunked_workspaces.states.ptr) %
        @alignOf(connection_chunked_body.State));

    const one_report = try memory_budget.callerOwned(u8, One, EmptyBackend);
    const two_report = try memory_budget.callerOwned(u8, Two, EmptyBackend);
    try std.testing.expectEqual(@as(u64, One.required_bytes), one_report.storage_slab_bytes);
    try std.testing.expectEqual(@as(u64, Two.required_bytes), two_report.storage_slab_bytes);
    try std.testing.expectEqual(@as(u16, 1), one_report.decoder_thread_count);
    try std.testing.expectEqual(@as(u64, 256 * 1024), one_report.decoder_requested_stack_bytes);
    try std.testing.expect(one_report.decoder_thread_vm_overhead_unknown);
    try std.testing.expectEqual(@as(u64, 9792), two_report.total_bytes - one_report.total_bytes);
}

test "stream transport storage compiles out and blocks unfinished release" {
    const Finite = worker_storage.Storage(TestApp, test_limits);
    const Streaming = worker_storage.Storage(StreamTestApp, test_limits);
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(Finite.Request, "stream_transport")),
    );
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Finite.Request));

    var slab: [Streaming.required_bytes]u8 align(Streaming.slab_alignment) = undefined;
    var storage: Streaming = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = storage.acquireRequest(connection).?;
    const state_address = @intFromPtr(&storage.requests[request].stream_transport.state);

    try std.testing.expect(storage.requestReleaseIssue(connection, request) == null);
    storage.requests[request].stream_transport.active = true;
    storage.requests[request].stream_transport.state.state = .waiting;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.state.state = .finished;
    storage.requests[request].stream_transport.cancel_outcome = .peer_aborted;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.cancel_outcome = null;
    storage.requests[request].stream_transport.timeout_cancel_target_sequence = 7;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.timeout_cancel_target_sequence = 0;
    storage.requests[request].stream_transport.timeout_cancel_operation_sequence = 8;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.timeout_cancel_operation_sequence = 0;
    storage.requests[request].stream_transport.poll_ready = true;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.poll_ready = false;
    storage.requests[request].stream_transport.full_clear_required = true;
    try std.testing.expectEqual(
        RequestReleaseIssue.stream_not_finished,
        storage.requestReleaseIssue(connection, request).?,
    );
    storage.requests[request].stream_transport.full_clear_required = false;
    storage.releaseRequest(connection, request);

    const reused = storage.acquireRequest(connection).?;
    try std.testing.expectEqual(request, reused);
    try std.testing.expectEqual(
        state_address,
        @intFromPtr(&storage.requests[reused].stream_transport.state),
    );
    try std.testing.expect(!storage.requests[reused].stream_transport.active);
    try std.testing.expect(!storage.requests[reused].stream_transport.poll_ready);
    try std.testing.expect(!storage.requests[reused].stream_transport.full_clear_required);
    try std.testing.expectEqual(
        @as(u16, 0),
        storage.requests[reused].stream_transport.timeout_cancel_target_sequence,
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        storage.requests[reused].stream_transport.timeout_cancel_operation_sequence,
    );
    try std.testing.expect(storage.requests[reused].stream_transport.cancel_outcome == null);
    storage.releaseRequest(connection, reused);
}

test "gzip controller and slots are stable caller-owned storage without startup effects" {
    const Storage = worker_storage.Storage(BodyTestApp, gzip_two_limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);

    try std.testing.expectEqual(@as(u16, 2), Storage.gzip_decoder_thread_count);
    try std.testing.expectEqual(@as(usize, 24), Storage.gzip_input_queue_bytes_per_slot);
    try std.testing.expectEqual(
        @as(usize, gzip_two_limits.receive_buffer_bytes),
        Storage.gzip_output_mailbox_capacity_bytes_per_slot,
    );
    try std.testing.expectEqual(
        @as(usize, 128),
        Storage.gzip_output_mailbox_bytes_per_slot,
    );
    try std.testing.expectEqual(
        Storage.gzip_decoder_slot_bytes * Storage.gzip_decoder_thread_count,
        Storage.gzip_decoder_slots_bytes,
    );
    try std.testing.expect(Storage.gzip_decoder_slot_bytes >
        Storage.gzip_input_queue_bytes_per_slot);
    try std.testing.expectEqual(@as(u64, 256 * 1024), Storage.gzip_decoder_requested_stack_bytes);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(@TypeOf(storage.requests[0].gzip_lease)));

    const pool = storage.gzipPool().?;
    const slab_start = @intFromPtr(slab[0..].ptr);
    const slab_end = slab_start + slab.len;
    const pool_start = @intFromPtr(pool);
    const slots_start = @intFromPtr(pool.slots);
    try std.testing.expect(pool_start >= slab_start);
    try std.testing.expect(pool_start + Storage.gzip_decoder_control_bytes <= slab_end);
    try std.testing.expect(slots_start >= slab_start);
    try std.testing.expect(slots_start + Storage.gzip_decoder_slots_bytes <= slab_end);
    try std.testing.expectEqual(@as(usize, 0), pool_start % @alignOf(Storage.GzipDecoderPool));
    try std.testing.expectEqual(
        @as(usize, 0),
        slots_start % @alignOf(Storage.GzipDecoderPool.Slot),
    );
    try std.testing.expectEqual(@as(u16, 0), pool.available());
    try std.testing.expect(!pool.counter_open);
    try std.testing.expectEqual(@as(u16, 0), pool.started_count);
    for (pool.slots) |*slot| {
        try std.testing.expect(slot.thread == null);
        try std.testing.expect(slot.counter == &pool.counter);
    }
}

test "response-only workspace does not reserve gzip decoders" {
    const Storage = worker_storage.Storage(ResponseOnlyTestApp, gzip_two_limits);
    try std.testing.expectEqual(@as(u16, 2), Storage.workspace_class_count);
    try std.testing.expectEqual(@as(u32, 8), Storage.body_workspace_bytes_per_slot);
    try std.testing.expectEqual(@as(u16, 0), Storage.gzip_decoder_thread_count);
}

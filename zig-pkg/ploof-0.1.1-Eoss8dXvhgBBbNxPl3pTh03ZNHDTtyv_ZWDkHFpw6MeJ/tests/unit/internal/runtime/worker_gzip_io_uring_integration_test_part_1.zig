const source = @import("worker_gzip_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const json = source.json;
const multipart = source.multipart;
const query = source.query;
const response = source.response;
const route = source.route;
const allocation_guard = source.allocation_guard;
const buffer_ring = source.buffer_ring;
const config = source.config;
const gzip_encoder = source.gzip_encoder;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const guarded_request_count = source.guarded_request_count;
const typed_json_body = source.typed_json_body;
const typed_gzip_bytes_max = source.typed_gzip_bytes_max;
const large_body_bytes = source.large_body_bytes;
const large_gzip_bytes_max = source.large_gzip_bytes_max;
const multipart_boundary = source.multipart_boundary;
const multipart_count_part = source.multipart_count_part;
const multipart_upload_head = source.multipart_upload_head;
const multipart_close = source.multipart_close;
const multipart_body = source.multipart_body;
const multipart_large_body = source.multipart_large_body;
const multipart_gzip_bytes_max = source.multipart_gzip_bytes_max;
const continue_response = source.continue_response;
const gzip_abcdef = source.gzip_abcdef;
const gzip_twelve = source.gzip_twelve;
const gzip_head = source.gzip_head;
const expect_gzip_head = source.expect_gzip_head;
const chunked_gzip_head = source.chunked_gzip_head;
const chunked_gzip_wire = source.chunked_gzip_wire;
const ping_request = source.ping_request;
const multipart_head = source.multipart_head;
const body_response = source.body_response;
const ping_response = source.ping_response;
const typed_response = source.typed_response;
const multipart_response = source.multipart_response;
const bad_request_response = source.bad_request_response;
const too_large_response = source.too_large_response;
const unavailable_response = source.unavailable_response;
const LargeFixture = source.LargeFixture;
const rejectionResponse = source.rejectionResponse;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const echo = source.echo;
const ping = source.ping;
const largeEcho = source.largeEcho;
const TypedQuery = source.TypedQuery;
const TypedPayload = source.TypedPayload;
const TypedEndpoint = source.TypedEndpoint;
const typed = source.typed;
const MultipartBody = source.MultipartBody;
const MultipartEndpoint = source.MultipartEndpoint;
const MultipartSpec = source.MultipartSpec;
const MultipartConsumer = source.MultipartConsumer;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const ActiveGzip = source.ActiveGzip;
const Runtime = source.Runtime;
const expectClosedRejection = source.expectClosedRejection;
const expectGuardedChild = source.expectGuardedChild;
const runGuardedGzip = source.runGuardedGzip;
const expectState = source.expectState;
const expectMultipartResult = source.expectMultipartResult;
const activeGzip = source.activeGzip;
const waitDecodePaused = source.waitDecodePaused;
const waitForSpaceNotification = source.waitForSpaceNotification;
const expectReadable = source.expectReadable;
const discardLiveSockets = source.discardLiveSockets;
const resolveStep = source.resolveStep;
const waitCompletion = source.waitCompletion;
const connectClient = source.connectClient;
const sendAll = source.sendAll;
const receiveExact = source.receiveExact;
const monotonicNow = source.monotonicNow;

test "real io_uring fixed gzip preserves fragments and pipelined keep-alive tail" {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();

    try sendAll(runtime.clients[0], gzip_head ++ gzip_abcdef[0..9].*);
    try runtime.driveUntilFixedProgress(9);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
    try sendAll(runtime.clients[0], gzip_abcdef[9..].* ++ ping_request);
    try runtime.driveUntilCompleted(2);

    var received: [body_response.len + ping_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(body_response ++ ping_response, &received);
    try expectState(&runtime.state, 1, 1, 2);
    try runtime.stop();
}

test "real io_uring gzip materializes typed Endpoint JSON" {
    var gzip_workspace: gzip_encoder.Workspace = undefined;
    var gzip_bytes: [typed_gzip_bytes_max]u8 = undefined;
    const encoded = try gzip_encoder.compress(
        &gzip_workspace,
        typed_json_body,
        &gzip_bytes,
        .fastest,
    );
    var head_bytes: [256]u8 = undefined;
    var head: std.Io.Writer = .fixed(&head_bytes);
    try head.print(
        "POST /typed?request_id=41 HTTP/1.1\r\n" ++
            "Host: gzip.integration.test\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Encoding: gzip\r\n" ++
            "Content-Length: {d}\r\n\r\n",
        .{encoded.len},
    );

    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();
    try sendAll(runtime.clients[0], head.buffered());
    try sendAll(runtime.clients[0], encoded[0..9]);
    try runtime.driveUntilFixedProgress(9);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.typed_calls);
    try sendAll(runtime.clients[0], encoded[9..]);
    try runtime.driveUntilCompleted(1);

    var received: [typed_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(typed_response, &received);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.typed_calls);
    try std.testing.expect(runtime.state.typed_valid);
    try std.testing.expectEqual(
        limits.gzip.decoder_slots,
        runtime.storage.gzipPool().?.available(),
    );
    try runtime.stop();
}

test "real io_uring fragmented identity multipart reaches typed consumer" {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();

    try sendAll(runtime.clients[0], multipart_head);
    var used: usize = 0;
    while (used + 37 < multipart_body.len) {
        const end = used + 37;
        try sendAll(runtime.clients[0], multipart_body[used..end]);
        try runtime.driveUntilIdentityProgress(@intCast(end));
        try std.testing.expectEqual(@as(u16, 0), runtime.state.multipart_calls);
        used = end;
    }
    try sendAll(runtime.clients[0], multipart_body[used..]);
    try runtime.driveUntilCompleted(1);

    var received: [multipart_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(multipart_response, &received);
    try expectMultipartResult(&runtime);
    try runtime.stop();
    try std.testing.expect(runtime.worker.cleanupStatus().quiescent());
}

test "real io_uring gzip multipart crosses decoded mailbox" {
    try std.testing.expect(
        multipart_large_body.len > Storage.gzip_output_mailbox_capacity_bytes_per_slot,
    );
    var gzip_workspace: gzip_encoder.Workspace = undefined;
    var gzip_bytes: [multipart_gzip_bytes_max]u8 = undefined;
    const encoded = try gzip_encoder.compress(
        &gzip_workspace,
        multipart_large_body,
        &gzip_bytes,
        .fastest,
    );
    var head_bytes: [256]u8 = undefined;
    var head: std.Io.Writer = .fixed(&head_bytes);
    try head.print(
        "POST /multipart HTTP/1.1\r\n" ++
            "Host: gzip.integration.test\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\n" ++
            "Content-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{ multipart_boundary, encoded.len },
    );

    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();
    try sendAll(runtime.clients[0], head.buffered());
    try sendAll(runtime.clients[0], encoded[0..9]);
    try runtime.driveUntilFixedProgress(9);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.multipart_calls);
    try sendAll(runtime.clients[0], encoded[9..]);
    try runtime.driveUntilCompleted(1);

    var received: [multipart_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(multipart_response, &received);
    try expectMultipartResult(&runtime);
    try runtime.stop();
    try std.testing.expect(runtime.worker.cleanupStatus().quiescent());
}

test "real io_uring chunked gzip preserves every wire fragment and trailer" {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();

    try sendAll(runtime.clients[0], chunked_gzip_head);
    for (chunked_gzip_wire[0 .. chunked_gzip_wire.len - 1], 1..) |byte, used| {
        const one = [1]u8{byte};
        try sendAll(runtime.clients[0], &one);
        try runtime.driveUntilChunkProgress(used);
    }
    try sendAll(runtime.clients[0], chunked_gzip_wire[chunked_gzip_wire.len - 1 ..]);
    try runtime.driveUntilCompleted(1);

    var received: [body_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(body_response, &received);
    try expectState(&runtime.state, 1, 0, 1);
    try std.testing.expect(runtime.state.trailers_valid);
    try runtime.stop();
}

test "real io_uring gzip sends continue before decoding fragmented body" {
    var runtime = Runtime{};
    try runtime.init(1);
    defer runtime.abort();

    try sendAll(runtime.clients[0], expect_gzip_head);
    try runtime.driveUntilContinueDelivered();
    var interim: [continue_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &interim);
    try std.testing.expectEqualStrings(continue_response, &interim);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);

    try sendAll(runtime.clients[0], gzip_abcdef[0..11]);
    try runtime.driveUntilFixedProgress(11);
    try sendAll(runtime.clients[0], gzip_abcdef[11..]);
    try runtime.driveUntilCompleted(1);
    var final: [body_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &final);
    try std.testing.expectEqualStrings(body_response, &final);
    try expectState(&runtime.state, 1, 0, 1);
    try runtime.stop();
}

test "real io_uring gzip queue pressure wakes and rearms receive" {
    var fixture: LargeFixture = undefined;
    try fixture.init();
    try std.testing.expect(fixture.gzip().len > Storage.gzip_input_queue_bytes_per_slot);

    Storage.GzipDecoderPool.TestAccess.pauseDecode(true);
    defer Storage.GzipDecoderPool.TestAccess.pauseDecode(false);
    var runtime = Runtime{};
    runtime.state.large_expected = &fixture.decoded;
    try runtime.init(1);
    defer runtime.abort();

    const wake_before = runtime.worker.gzip.wake.currentPollToken().?;
    var head_bytes: [256]u8 = undefined;
    var head: std.Io.Writer = .fixed(&head_bytes);
    try head.print(
        "POST /large HTTP/1.1\r\n" ++
            "Host: gzip.integration.test\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Encoding: gzip\r\n" ++
            "Content-Length: {d}\r\n\r\n",
        .{fixture.gzip().len},
    );
    try sendAll(runtime.clients[0], head.buffered());
    try sendAll(runtime.clients[0], fixture.gzip());

    const active = try runtime.driveUntilGzipPaused();
    try waitDecodePaused();
    const connection = &runtime.storage.connections[active.connection_index];
    const request = &runtime.storage.requests[active.request_index];
    const lease = request.gzip_lease.?;
    const pool = runtime.storage.gzipPool().?;
    const queue = &pool.slots[lease.index].queue;
    try std.testing.expect(connection.receive_flags.gzip_paused);
    try std.testing.expect(connection.receive_token == null);
    try std.testing.expect(!connection.receive_flags.multishot);
    try std.testing.expect(request.body.receiver.progress() < fixture.gzip().len);
    try std.testing.expect(
        queue.producerFreeBytes() < limits.receive_buffer_bytes,
    );
    try std.testing.expect(!queue.spaceNotificationPending());
    try std.testing.expect(runtime.worker.gzip.wake.currentPollToken().?.eql(wake_before));

    Storage.GzipDecoderPool.TestAccess.pauseDecode(false);
    try waitForSpaceNotification(queue);
    try std.testing.expect(queue.producerFreeBytes() >= limits.receive_buffer_bytes);
    try std.testing.expect(queue.spaceNotificationPending());
    try expectReadable(pool.wakeDescriptor());

    const completions_before = runtime.worker.metricsSnapshot().valid_completions;
    var rearm_completions: u16 = 0;
    while (runtime.worker.gzip.wake.currentPollToken().?.eql(wake_before)) {
        if (rearm_completions == completion_limit) return error.WakeRearmNotObserved;
        try runtime.step();
        rearm_completions += 1;
    }
    try std.testing.expect(rearm_completions != 0);
    try std.testing.expectEqual(
        completions_before + @as(u64, rearm_completions),
        runtime.worker.metricsSnapshot().valid_completions,
    );
    const wake_after = runtime.worker.gzip.wake.currentPollToken().?;
    try std.testing.expect(!wake_after.eql(wake_before));
    const before_fields = try wake_before.fields();
    const after_fields = try wake_after.fields();
    try std.testing.expectEqual(reactor.OperationKind.wake, after_fields.kind);
    try std.testing.expectEqual(before_fields.slot_generation, after_fields.slot_generation);
    try std.testing.expectEqual(
        reactor.nextSequence(before_fields.sequence),
        after_fields.sequence,
    );
    try std.testing.expect(!queue.spaceNotificationPending());
    try std.testing.expect(!connection.receive_flags.gzip_paused);
    try std.testing.expect(connection.receive_token != null);
    try std.testing.expect(!connection.receive_flags.multishot);

    try runtime.driveUntilCompleted(1);
    var received: [body_response.len]u8 = undefined;
    try receiveExact(runtime.clients[0], &received);
    try std.testing.expectEqualStrings(body_response, &received);
    try expectState(&runtime.state, 1, 0, 1);
    try std.testing.expectEqual(@as(u16, 0), pool.activeJobs());
    try std.testing.expectEqual(limits.gzip.decoder_slots, pool.available());
    try std.testing.expectEqual(
        limits.body_workspace_slots,
        runtime.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        Storage.gzip_input_queue_bytes_per_slot,
        queue.producerFreeBytes(),
    );
    try std.testing.expect(!queue.spaceNotificationPending());
    try std.testing.expectEqual(@as(u16, 0), runtime.backend.borrowedCount());
    try runtime.stop();
}

test "real io_uring malformed gzip is 400 and decoded overflow is 413" {
    const cases = [_]struct { wire: []const u8, expected: []const u8 }{
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: gzip.integration.test\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Encoding: gzip\r\nContent-Length: 4\r\n\r\nnope",
            .expected = bad_request_response,
        },
        .{
            .wire = "POST /echo HTTP/1.1\r\nHost: gzip.integration.test\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++ gzip_twelve,
            .expected = too_large_response,
        },
    };
    for (cases) |case| try expectClosedRejection(case.wire, case.expected);
}

test "real io_uring gzip encoded and chunk wire limits are exact 413" {
    const fixed =
        "POST /echo HTTP/1.1\r\nHost: gzip.integration.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Encoding: gzip\r\nContent-Length: 81\r\n\r\n";
    try expectClosedRejection(fixed, too_large_response);
    try expectClosedRejection(chunked_gzip_head ++ "51\r\n", too_large_response);
}

test "real io_uring malformed gzip chunk framing is exact 400" {
    try expectClosedRejection(chunked_gzip_head ++ "g\r\n", bad_request_response);
}

test "real io_uring gzip exhaustion is 503 before continue and disconnect cancels" {
    var runtime = Runtime{};
    try runtime.init(2);
    defer runtime.abort();

    try sendAll(runtime.clients[0], gzip_head ++ gzip_abcdef[0..9].*);
    try runtime.driveUntilFixedProgress(9);
    try std.testing.expectEqual(@as(u16, 1), runtime.storage.gzipPool().?.activeJobs());
    try sendAll(runtime.clients[1], expect_gzip_head);
    try runtime.driveUntilClosed(1);

    var unavailable: [unavailable_response.len]u8 = undefined;
    try receiveExact(runtime.clients[1], &unavailable);
    try std.testing.expectEqualStrings(unavailable_response, &unavailable);
    try std.testing.expect(!std.mem.startsWith(u8, &unavailable, continue_response));

    _ = linux.close(runtime.clients[0]);
    runtime.clients[0] = -1;
    try runtime.driveUntilClosed(2);
    try std.testing.expectEqual(@as(u16, 0), runtime.storage.gzipPool().?.activeJobs());
    try std.testing.expectEqual(
        limits.gzip.decoder_slots,
        runtime.storage.gzipPool().?.available(),
    );
    try std.testing.expectEqual(
        limits.body_workspace_slots,
        runtime.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
    try runtime.stop();
}

test "real io_uring gzip stays allocation free after worker readiness" {
    try expectGuardedChild(runGuardedGzip, 131);
}

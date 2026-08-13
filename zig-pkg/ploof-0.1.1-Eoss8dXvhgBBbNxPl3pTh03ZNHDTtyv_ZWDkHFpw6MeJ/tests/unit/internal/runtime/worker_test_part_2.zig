const source = @import("worker_test.zig");
const std = source.std;
const application = source.application;
const forwarding = source.forwarding;
const response = source.response;
const route = source.route;
const accept_controller = source.accept_controller;
const buffer_ring = source.buffer_ring;
const config = source.config;
const deterministic_reactor = source.deterministic_reactor;
const fuzz_support = source.fuzz_support;
const io_uring_backend = source.io_uring_backend;
const reactor = source.reactor;
const server_command = source.server_command;
const worker_module = source.worker_module;
const worker_storage = source.worker_storage;
const fixed_epoch_second = source.fixed_epoch_second;
const fixed_date = source.fixed_date;
const next_date = source.next_date;
const ping_request = source.ping_request;
const TestState = source.TestState;
const TestContext = source.TestContext;
const Observe = source.Observe;
const ping = source.ping;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const TestWorker = source.TestWorker;
const Harness = source.Harness;
const fuzzWorkerStateMachine = source.fuzzWorkerStateMachine;
const fuzzWorkerStep = source.fuzzWorkerStep;
const fuzzCompletion = source.fuzzCompletion;
const fuzzAccept = source.fuzzAccept;
const fuzzSend = source.fuzzSend;
const fuzzCancel = source.fuzzCancel;
const expectFuzzQuiescent = source.expectFuzzQuiescent;
const fuzzReceive = source.fuzzReceive;
const worker_state_fuzz_corpus = source.worker_state_fuzz_corpus;

test "unproven fatal ownership retains slots and requires process exit" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(51);
    try harness.receive(connection_index, ping_request, false);
    const request_index = harness.storage.connections[connection_index].active_request.?;
    const response_used = harness.storage.requests[request_index].response_used;
    try std.testing.expect(response_used != 0);
    var response_before: [test_limits.response_bytes_per_request]u8 = undefined;
    @memcpy(
        response_before[0..response_used],
        harness.storage.responseReadable(request_index)[0..response_used],
    );
    const head_used = harness.storage.connections[connection_index].head_decoder.bytes().len;
    var head_before: [test_limits.pipeline_bytes_per_connection]u8 = undefined;
    @memcpy(
        head_before[0..head_used],
        harness.storage.connections[connection_index].head_decoder.bytes(),
    );
    harness.io.injectUnprovenAbort();

    const wrong_worker = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 1,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectError(error.InvalidCompletion, harness.worker.handle(.{
        .token = wrong_worker,
        .result = .{ .failure = .canceled },
        .more = false,
    }, harness.sample));

    const status = harness.worker.cleanupStatus();
    try std.testing.expect(status.requiresProcessExit());
    try std.testing.expect(!status.quiescent());
    try std.testing.expectEqual(worker_module.Phase.failed, status.phase);
    try std.testing.expectEqual(@as(u16, 1), status.live_connections);
    try std.testing.expectEqual(@as(u16, 1), status.live_requests);
    try std.testing.expectEqual(@as(u16, 0), status.workspace_abort_attempts);
    try std.testing.expectEqual(@as(u16, 0), status.workspace_abort_failures);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
    try std.testing.expectEqual(@as(u64, 0), harness.io.discardedCount());
    try std.testing.expectEqualSlices(
        u8,
        response_before[0..response_used],
        harness.storage.responseReadable(request_index)[0..response_used],
    );
    try std.testing.expectEqualSlices(
        u8,
        head_before[0..head_used],
        harness.storage.connections[connection_index].head_decoder.bytes(),
    );
}

test "consumed close success prevents stale descriptor discard during later fatal" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(52);
    _ = try harness.worker.stop();
    const close = harness.storage.connections[connection_index].close_token.?;
    _ = try harness.complete(close, .{ .success = .{ .close = {} } }, false);
    try std.testing.expect(harness.storage.connections[connection_index].socket_closed);

    const wrong_worker = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 1,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectError(error.InvalidCompletion, harness.worker.handle(.{
        .token = wrong_worker,
        .result = .{ .failure = .canceled },
        .more = false,
    }, harness.sample));
    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(@as(u64, 0), harness.io.discardedCount());
}

test "failed close leaves descriptor ownership unproven" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(53);
    _ = try harness.worker.stop();
    const close = harness.storage.connections[connection_index].close_token.?;
    try std.testing.expectError(
        error.DriverFailure,
        harness.complete(close, .{ .failure = .backend_failure }, false),
    );
    const status = harness.worker.cleanupStatus();
    try std.testing.expect(status.requiresProcessExit());
    try std.testing.expectEqual(worker_module.Phase.failed, status.phase);
    try std.testing.expectEqual(@as(u16, 1), status.live_connections);
    try std.testing.expectEqual(@as(u64, 0), harness.io.discardedCount());
}

test "worker bounded state machine fuzz drains every valid schedule" {
    try std.testing.fuzz({}, fuzzWorkerStateMachine, .{
        .corpus = &worker_state_fuzz_corpus,
    });
}

test "production backend satisfies worker orchestration method surface" {
    const ReceiveBuffers = buffer_ring.BufferRing(
        test_limits.receive_buffers,
        test_limits.receive_buffer_bytes,
        41,
    );
    const Backend = io_uring_backend.IoUringBackend(test_limits, ReceiveBuffers);
    const ProductionWorker = worker_module.Worker(TestApp, TestStorage, Backend);
    std.testing.refAllDecls(ProductionWorker);
    const ConfiguredProductionWorker = worker_module.ConfiguredWorker(
        TestApp,
        TestStorage,
        Backend,
        forwarding.Limits{
            .trusted_matchers_max = 2,
            .hops_max = 2,
            .parameters_per_element_max = 2,
        },
    );
    std.testing.refAllDecls(ConfiguredProductionWorker);
}

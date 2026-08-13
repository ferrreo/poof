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

test "worker control flags pack independently into one byte" {
    const Flags = @FieldType(TestWorker, "control_flags");
    var flags = Flags{};
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Flags));
    try std.testing.expect(flags.services_allowed);
    flags.draining_grace = true;
    flags.stop_accept_scheduled = true;
    flags.services_started = true;
    flags.upload_stop_scheduled = true;
    flags.live_static_stop_scheduled = true;
    try std.testing.expect(flags.draining_grace and flags.stop_accept_scheduled);
    try std.testing.expect(flags.services_started and flags.upload_stop_scheduled);
    try std.testing.expect(flags.live_static_stop_scheduled and flags.services_allowed);
}

test "worker drives fragmented pipelined requests partial sends and cancel reorder" {
    var harness: Harness = undefined;
    try harness.init(true);

    harness.sample = .{
        .monotonic_ns = std.time.ns_per_s,
        .epoch_second = fixed_epoch_second + 1,
    };
    const connection_index = try harness.accept(10);
    try std.testing.expectEqualStrings(fixed_date, harness.worker.cachedDate());
    try std.testing.expectEqualDeep(worker_module.MetricsSnapshot{
        .valid_completions = 1,
        .connections_accepted = 1,
        .connections_closed = 0,
        .live_connections = 1,
        .connections_high_water = 1,
        .timeout_completions = 0,
        .receive_buffer_exhaustions = 0,
        .fatal_transitions = 0,
    }, harness.worker.metricsSnapshot());

    harness.sample.monotonic_ns = std.time.ns_per_s + 1;
    try harness.receive(connection_index, "GET /pi", false);
    try std.testing.expectEqualStrings(next_date, harness.worker.cachedDate());
    try harness.receive(
        connection_index,
        "ng HTTP/1.1\r\nHost: example.test\r\n\r\n" ++ ping_request,
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.calls);
    try std.testing.expectEqual(@as(u64, 2), harness.io.recycledCount());
    try std.testing.expect(std.mem.indexOf(
        u8,
        harness.sendBytes(connection_index),
        "date: " ++ next_date,
    ) != null);

    const first_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(first_send, .{ .success = .{ .send = 7 } }, false);
    const remainder = harness.sendBytes(connection_index).len;
    const remainder_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        remainder_send,
        .{ .success = .{ .send = @intCast(remainder) } },
        false,
    );
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);

    try harness.reapCancelRequestsReordered();
    try std.testing.expectEqual(@as(u16, 2), harness.state.calls);
    const second_length = harness.sendBytes(connection_index).len;
    const second_send = harness.storage.connections[connection_index].send_token.?;
    _ = try harness.complete(
        second_send,
        .{ .success = .{ .send = @intCast(second_length) } },
        false,
    );
    try harness.reapCancelRequestsReordered();
    try std.testing.expectEqual(@as(u16, 2), harness.state.completed);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);

    try harness.stopAndDrain();
    try std.testing.expect(harness.worker.cleanupStatus().quiescent());
    const metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), metrics.live_connections);
}

test "worker timeout stop and racing accept reach exact quiescence" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(20);
    try harness.receive(connection_index, "GET ", false);

    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    try std.testing.expectEqual(
        @as(u64, 1),
        harness.worker.metricsSnapshot().timeout_completions,
    );
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.responding,
        harness.storage.connections[connection_index].phase,
    );
    _ = try harness.worker.stop();
    _ = try harness.accept(21);

    const pending = harness.worker.cleanupStatus();
    try std.testing.expectEqual(@as(u16, 2), pending.live_connections);
    try std.testing.expect(pending.listener_operations != 0);
    try std.testing.expect(pending.connection_operations != 0);
    const pending_metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), pending_metrics.connections_accepted);
    try std.testing.expectEqual(@as(u16, 2), pending_metrics.live_connections);
    try std.testing.expectEqual(@as(u16, 2), pending_metrics.connections_high_water);
    try harness.stopAndDrain();

    const stopped = harness.worker.cleanupStatus();
    try std.testing.expect(stopped.quiescent());
    try std.testing.expect(!stopped.fatal);
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
    try std.testing.expectEqual(worker_module.Step.stopped, try harness.worker.stop());
    const stopped_metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), stopped_metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), stopped_metrics.live_connections);
}

test "graceful drain closes partial heads and force upgrade stays irreversible" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(24);
    try harness.receive(connection_index, "GET ", false);

    _ = try harness.worker.beginDrain();
    try std.testing.expect(harness.worker.control_flags.draining_grace);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.closing,
        harness.storage.connections[connection_index].phase,
    );
    try std.testing.expectEqual(@as(u16, 0), harness.state.started);
    _ = try harness.worker.stop();
    try std.testing.expect(!harness.worker.control_flags.draining_grace);
    try std.testing.expectEqual(test_limits.connection_slots, harness.worker.stop_cursor);
    try harness.stopAndDrain();
    try std.testing.expect(harness.worker.cleanupStatus().quiescent());
}

test "external command poll permits stop only after worker operations quiesce" {
    var harness: Harness = undefined;
    try harness.init(true);
    var command = try server_command.Channel.init(0);
    defer if (command.counter.live) command.abortAfterBackend();
    try command.start(&harness.io);

    _ = try harness.worker.stop();
    harness.worker.reconcileStopWithExternalOperations(command.operationTokens());
    var status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.Phase.stopping, status.phase);
    try std.testing.expect(status.listener_operations != 0);

    try harness.reapCancelRequestsReordered();
    status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.Phase.stopping, status.phase);
    try std.testing.expectEqual(@as(u8, 0), status.listener_operations);
    try std.testing.expectEqual(@as(u16, 1), harness.io.activeCount());

    harness.worker.reconcileStopWithExternalOperations(command.operationTokens());
    status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.Phase.stopped, status.phase);
    try std.testing.expectEqual(@as(u32, 1), status.backend_active);
    try std.testing.expect(!status.quiescent());

    try std.testing.expect(!(try command.beginStop(&harness.io)));
    const poll = command.wake.currentPollToken().?;
    const cancel = command.wake.currentCancelToken().?;
    try harness.io.complete(cancel, .{ .success = .{ .cancel = .canceled } }, false);
    try std.testing.expect(
        !(try command.handle(&harness.io, harness.io.nextCompletion().?)).stopped,
    );
    try harness.io.complete(poll, .{ .failure = .canceled }, false);
    try std.testing.expect(
        (try command.handle(&harness.io, harness.io.nextCompletion().?)).stopped,
    );
    try command.finish();
    try std.testing.expect(harness.worker.cleanupStatus().quiescent());
}

test "graceful drain finishes admitted response and prevents keepalive reuse" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(25);
    try harness.receive(connection_index, ping_request, false);
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.responding,
        harness.storage.connections[connection_index].phase,
    );

    _ = try harness.worker.beginDrain();
    try std.testing.expect(harness.storage.connections[connection_index].close_after_response);
    const send = harness.storage.connections[connection_index].send_token.?;
    const response_length = harness.sendBytes(connection_index).len;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(response_length) } },
        false,
    );
    try harness.reapCancelRequestsReordered();
    try harness.stopAndDrain();
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u16, 0), harness.state.aborted);
    try std.testing.expect(harness.worker.cleanupStatus().quiescent());
}

test "worker single-shot accept never exceeds slots and resumes after release" {
    var harness: Harness = undefined;
    try harness.init(true);
    const first = try harness.accept(30);
    _ = try harness.accept(31);
    try std.testing.expectEqual(
        accept_controller.Phase.paused,
        harness.worker.controller.phase,
    );
    try std.testing.expect(harness.findToken(.accept, std.math.maxInt(u16)) == null);
    try std.testing.expectError(error.TestUnexpectedResult, harness.accept(32));
    const full = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), full.connections_accepted);
    try std.testing.expectEqual(@as(u16, 2), full.live_connections);
    try std.testing.expectEqual(test_limits.connection_slots, full.connections_high_water);

    const timeout = harness.storage.connections[first].timeout_token.?;
    _ = try harness.complete(timeout, .{ .success = .{ .timeout = {} } }, false);
    var iterations: u8 = 0;
    while (harness.storage.connections[first].phase != .free) : (iterations += 1) {
        if (iterations == 32) return error.TestUnexpectedResult;
        const token = harness.findToken(.cancel, first) orelse
            harness.findToken(.close, first) orelse
            harness.findToken(.receive, first) orelse
            harness.findToken(.send, first) orelse
            harness.findToken(.timeout, first) orelse
            return error.TestUnexpectedResult;
        const kind = (try token.fields()).kind;
        const result: reactor.CompletionResult = switch (kind) {
            .cancel => .{ .success = .{ .cancel = .canceled } },
            .close => .{ .success = .{ .close = {} } },
            .receive, .send, .timeout => .{ .failure = .canceled },
            .accept,
            .wake,
            .file_open,
            .file_write,
            .file_close,
            .file_link,
            .file_unlink,
            .file_rename_no_replace,
            .file_sync,
            .upload_cancel,
            .file_read,
            .file_stat,
            .file_cancel,
            => return error.TestUnexpectedResult,
        };
        _ = try harness.complete(token, result, false);
    }
    try std.testing.expectEqual(
        accept_controller.Phase.accepting,
        harness.worker.controller.phase,
    );
    try std.testing.expect(harness.worker.controller.accept_token != null);
    _ = try harness.accept(32);
    const resumed = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 3), resumed.connections_accepted);
    try std.testing.expectEqual(test_limits.connection_slots, resumed.live_connections);
    try std.testing.expectEqual(test_limits.connection_slots, resumed.connections_high_water);
    try harness.stopAndDrain();
}

test "worker cleanup inventory counts accept resource backoff timeout" {
    var harness: Harness = undefined;
    try harness.init(true);
    const accept = harness.findToken(.accept, std.math.maxInt(u16)).?;
    _ = try harness.complete(accept, .{ .failure = .resource_exhausted }, false);
    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(accept_controller.Phase.backoff, harness.worker.controller.phase);
    try std.testing.expectEqual(@as(u8, 1), status.listener_operations);
    try std.testing.expectEqual(@as(u32, 1), status.backend_active);
    try harness.stopAndDrain();
    try std.testing.expect(harness.worker.cleanupStatus().quiescent());
}

test "worker rearms one ENOBUFS receive only after another buffer is recycled" {
    var harness: Harness = undefined;
    try harness.init(true);
    const paused_index = try harness.accept(31);
    const recycling_index = try harness.accept(32);
    const exhausted = harness.storage.connections[paused_index].receive_token.?;
    _ = try harness.complete(exhausted, .{ .failure = .buffer_exhausted }, false);
    try std.testing.expectEqual(
        @as(u64, 1),
        harness.worker.metricsSnapshot().receive_buffer_exhaustions,
    );
    try std.testing.expect(harness.storage.connections[paused_index].receive_flags.paused);
    try std.testing.expect(harness.storage.connections[paused_index].receive_token == null);
    try std.testing.expectEqual(@as(u16, 1), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.receive_resume_credits);

    try harness.receive(recycling_index, "GET ", false);
    try std.testing.expect(!harness.storage.connections[paused_index].receive_flags.paused);
    try std.testing.expect(harness.storage.connections[paused_index].receive_token != null);
    const resumed = harness.storage.connections[paused_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(resumed).?.receive.multishot);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.receive_resume_credits);
    try harness.stopAndDrain();
}

test "one-shot response has no receive and keepalive reuse rearms it" {
    var harness: Harness = undefined;
    try harness.init(true);
    const responding_index = try harness.accept(34);
    const recycling_index = try harness.accept(35);
    try harness.receive(responding_index, ping_request, false);
    try std.testing.expect(
        harness.storage.connections[responding_index].receive_token == null,
    );
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);

    try harness.receive(recycling_index, "GET ", false);
    const response_length = harness.sendBytes(responding_index).len;
    const send = harness.storage.connections[responding_index].send_token.?;
    _ = try harness.complete(
        send,
        .{ .success = .{ .send = @intCast(response_length) } },
        false,
    );
    try harness.reapCancelRequestsReordered();
    try std.testing.expectEqual(
        worker_storage.ConnectionPhase.keepalive_idle,
        harness.storage.connections[responding_index].phase,
    );
    try std.testing.expect(
        harness.storage.connections[responding_index].receive_token != null,
    );
    const receive = harness.storage.connections[responding_index].receive_token.?;
    try std.testing.expect(!harness.io.operation(receive).?.receive.multishot);
    try std.testing.expect(!harness.storage.connections[responding_index].receive_flags.paused);
    try std.testing.expectEqual(@as(u16, 1), harness.state.completed);
    try harness.stopAndDrain();
}

test "worker retains bounded recycle credits and cannot spin after exhaustion" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(33);
    const initial_receive = harness.storage.connections[connection_index].receive_token.?;
    const cursor = harness.worker.receive_resume_cursor;

    try harness.receive(connection_index, "GE", false);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 1), harness.worker.receive_resume_credits);
    try std.testing.expectEqual(cursor, harness.worker.receive_resume_cursor);
    const second_receive = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!initial_receive.eql(second_receive));
    try harness.receive(connection_index, "T ", false);
    try std.testing.expectEqual(@as(u16, 2), harness.worker.receive_resume_credits);
    try std.testing.expectEqual(cursor, harness.worker.receive_resume_cursor);

    _ = try harness.complete(
        harness.storage.connections[connection_index].receive_token.?,
        .{ .failure = .buffer_exhausted },
        false,
    );
    const first_rearm = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!second_receive.eql(first_rearm));
    try std.testing.expect(!harness.storage.connections[connection_index].receive_flags.paused);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 1), harness.worker.receive_resume_credits);

    _ = try harness.complete(first_rearm, .{ .failure = .buffer_exhausted }, false);
    const second_rearm = harness.storage.connections[connection_index].receive_token.?;
    try std.testing.expect(!first_rearm.eql(second_rearm));
    try std.testing.expect(!harness.storage.connections[connection_index].receive_flags.paused);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.receive_resume_credits);

    _ = try harness.complete(second_rearm, .{ .failure = .buffer_exhausted }, false);
    try std.testing.expect(harness.storage.connections[connection_index].receive_flags.paused);
    try std.testing.expect(harness.storage.connections[connection_index].receive_token == null);
    try std.testing.expectEqual(@as(u16, 1), harness.worker.paused_receive_count);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.receive_resume_credits);

    _ = try harness.worker.stop();
    try std.testing.expectEqual(@as(u16, 0), harness.worker.paused_receive_count);
    try std.testing.expect(!harness.worker.paused_receives[connection_index]);
    try std.testing.expectEqual(@as(u16, 0), harness.worker.receive_resume_credits);
    try harness.stopAndDrain();
}

test "worker exposes flush retry without spinning" {
    var harness: Harness = undefined;
    try harness.init(false);
    harness.io.injectFlushRetries(1);
    try std.testing.expectEqual(
        worker_module.Step.flush_retry,
        try harness.worker.start(harness.sample),
    );
    try std.testing.expect(harness.worker.cleanupStatus().flush_pending);

    try std.testing.expectEqual(
        worker_module.Step.progressed,
        try harness.worker.retryFlush(),
    );
    try std.testing.expect(!harness.worker.cleanupStatus().flush_pending);
    try harness.stopAndDrain();
}

test "worker owns supplied accepts during invalid phase and pending flush" {
    var idle: Harness = undefined;
    try idle.init(false);
    const foreign = try reactor.OperationToken.init(.{
        .kind = .accept,
        .worker_index = 0,
        .slot_index = std.math.maxInt(u16),
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectError(error.InvalidPhase, idle.worker.handle(.{
        .token = foreign,
        .result = .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 47 }) } },
        .more = false,
    }, idle.sample));
    try std.testing.expect(idle.worker.cleanupStatus().quiescent());
    try std.testing.expectEqual(@as(u64, 1), idle.io.discardedCount());

    var pending: Harness = undefined;
    try pending.init(false);
    pending.io.injectFlushRetries(1);
    try std.testing.expectEqual(
        worker_module.Step.flush_retry,
        try pending.worker.start(pending.sample),
    );
    const accept = pending.findToken(.accept, std.math.maxInt(u16)).?;
    try std.testing.expectError(error.FlushPending, pending.worker.handle(.{
        .token = accept,
        .result = .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 48 }) } },
        .more = false,
    }, pending.sample));
    try std.testing.expect(pending.worker.cleanupStatus().quiescent());
    try std.testing.expectEqual(@as(u64, 1), pending.io.discardedCount());
}

test "worker rejects invalid shard index before controller initialization" {
    var harness: Harness = undefined;
    try harness.init(false);
    var invalid: TestWorker = undefined;
    try std.testing.expectError(error.InvalidWorkerIndex, invalid.init(
        &harness.state,
        &harness.storage,
        &harness.io,
        reactor.max_worker_index + 1,
        .{ .value = 4 },
        null,
    ));
}

test "worker reconciles acquisition when controller fails after accepting" {
    var harness: Harness = undefined;
    try harness.init(true);
    const accept = harness.findToken(.accept, std.math.maxInt(u16)).?;
    harness.io.injectSubmitFailure();

    try std.testing.expectError(error.ControllerFailure, harness.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 49 }) } },
        false,
    ));

    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqualDeep(worker_module.MetricsSnapshot{
        .valid_completions = 0,
        .connections_accepted = 1,
        .connections_closed = 1,
        .live_connections = 0,
        .connections_high_water = 1,
        .timeout_completions = 0,
        .receive_buffer_exhaustions = 0,
        .fatal_transitions = 1,
    }, harness.worker.metricsSnapshot());
}

test "terminal accept is owned before clock failure cleanup" {
    var harness: Harness = undefined;
    try harness.init(true);
    harness.sample.monotonic_ns = 0;
    const accept = harness.findToken(.accept, std.math.maxInt(u16)).?;

    try std.testing.expectError(error.InvalidClock, harness.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 54 }) } },
        false,
    ));

    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(@as(u64, 1), harness.io.discardedCount());
    const metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_accepted);
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), metrics.live_connections);
}

test "unclaimed accepted completion is discarded before fatal cleanup" {
    var harness: Harness = undefined;
    try harness.init(true);
    const foreign_accept = try reactor.OperationToken.init(.{
        .kind = .accept,
        .worker_index = 1,
        .slot_index = std.math.maxInt(u16),
        .slot_generation = 1,
        .sequence = 1,
    });

    try std.testing.expectError(error.InvalidCompletion, harness.worker.handle(.{
        .token = foreign_accept,
        .result = .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 55 }) } },
        .more = false,
    }, harness.sample));

    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(@as(u32, 1), status.accepted_sockets_discarded);
    try std.testing.expectEqual(@as(u64, 1), harness.io.discardedCount());
}

test "worker fatal path preserves bounded cleanup accounting" {
    var harness: Harness = undefined;
    try harness.init(true);
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
    try std.testing.expect(harness.worker.cleanupStatus().fatal);
    try std.testing.expectEqualDeep(worker_module.MetricsSnapshot{
        .valid_completions = 0,
        .connections_accepted = 0,
        .connections_closed = 0,
        .live_connections = 0,
        .connections_high_water = 0,
        .timeout_completions = 0,
        .receive_buffer_exhaustions = 0,
        .fatal_transitions = 1,
    }, harness.worker.metricsSnapshot());

    try harness.stopAndDrain();
    const status = harness.worker.cleanupStatus();
    try std.testing.expect(status.fatal);
    try std.testing.expect(status.quiescent());
}

test "worker rejects out-of-range connection token through fatal cleanup" {
    var harness: Harness = undefined;
    try harness.init(true);
    const invalid_slot = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 0,
        .slot_index = test_limits.connection_slots,
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectError(error.InvalidCompletion, harness.worker.handle(.{
        .token = invalid_slot,
        .result = .{ .failure = .canceled },
        .more = false,
    }, harness.sample));
    const status = harness.worker.cleanupStatus();
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
}

test "failed connection cancel enters fatal cleanup without retiring its target" {
    var harness: Harness = undefined;
    try harness.init(true);
    const connection_index = try harness.accept(50);
    try harness.receive(connection_index, ping_request, false);
    const timeout = harness.storage.connections[connection_index].timeout_token.?;
    try harness.worker.driver.operations.submitCancel(
        &harness.storage,
        connection_index,
        timeout,
    );
    const cancel = harness.findToken(.cancel, connection_index).?;
    const target = harness.io.operation(cancel).?.cancel.target;
    try std.testing.expect(harness.io.operation(target) != null);

    try std.testing.expectError(
        error.DriverFailure,
        harness.complete(cancel, .{ .failure = .backend_failure }, false),
    );
    const status = harness.worker.cleanupStatus();
    try std.testing.expect(status.fatal);
    try std.testing.expectEqual(worker_module.FatalCleanup.recovered, status.fatal_cleanup);
    try std.testing.expect(status.quiescent());
    try std.testing.expectEqual(@as(u32, 0), status.backend_active);
    try std.testing.expectEqual(@as(u16, 1), status.workspace_abort_attempts);
    try std.testing.expectEqual(@as(u16, 1), harness.state.aborted);
    const metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_accepted);
    try std.testing.expectEqual(@as(u64, 1), metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), metrics.live_connections);
    try std.testing.expectEqual(@as(u64, 1), metrics.fatal_transitions);
}

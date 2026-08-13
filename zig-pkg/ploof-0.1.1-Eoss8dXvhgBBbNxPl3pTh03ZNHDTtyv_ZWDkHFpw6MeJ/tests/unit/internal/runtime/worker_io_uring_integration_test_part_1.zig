const source = @import("worker_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const response = source.response;
const route = source.route;
const buffer_ring = source.buffer_ring;
const config = source.config;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const memory_budget = source.memory_budget;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const ping_request = source.ping_request;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const poll_pause_ns = source.poll_pause_ns;
const burst_client_count = source.burst_client_count;
const buffer_reuse_request_count = source.buffer_reuse_request_count;
const ping_response = source.ping_response;
const request_timeout_response = source.request_timeout_response;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const ping = source.ping;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const StandardReceiveBuffers = source.StandardReceiveBuffers;
const StandardBackend = source.StandardBackend;
const StandardStorage = source.StandardStorage;
const StandardWorker = source.StandardWorker;
const mappingVmBytes = source.mappingVmBytes;
const driveUntilCompleted = source.driveUntilCompleted;
const driveUntilPartialHead = source.driveUntilPartialHead;
const driveUntilResponseQueued = source.driveUntilResponseQueued;
const driveUntilConnectionsClosed = source.driveUntilConnectionsClosed;
const driveUntilCapacityPaused = source.driveUntilCapacityPaused;
const expectOpenDescriptorLimit = source.expectOpenDescriptorLimit;
const openFileDescriptorCount = source.openFileDescriptorCount;
const expectAcceptedDescriptorsBounded = source.expectAcceptedDescriptorsBounded;
const driveUntilStopped = source.driveUntilStopped;
const resolveStep = source.resolveStep;
const waitCompletion = source.waitCompletion;
const abortTestBackend = source.abortTestBackend;
const expectProgress = source.expectProgress;
const connectClient = source.connectClient;
const sendAll = source.sendAll;
const receiveExact = source.receiveExact;
const monotonicNow = source.monotonicNow;

test "standard runtime capacity has an exact fixed memory budget" {
    const buffer_mapping = try std.posix.mmap(
        null,
        @sizeOf(StandardReceiveBuffers.Buffers),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    var buffers_live = true;
    defer if (buffers_live) std.posix.munmap(buffer_mapping);
    const buffers: *StandardReceiveBuffers.Buffers = @ptrCast(buffer_mapping.ptr);

    var backend: StandardBackend = undefined;
    try backend.init(buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };
    const fixed = try memory_budget.callerOwned(
        StandardWorker,
        StandardStorage,
        StandardBackend,
    );
    const report = try memory_budget.report(
        StandardWorker,
        StandardStorage,
        StandardBackend,
        &backend,
        1,
    );
    try std.testing.expectEqualDeep(memory_budget.CallerOwned{
        .worker_value_bytes = 448,
        .storage_value_bytes = 272,
        .backend_value_bytes = 37_888,
        .storage_slab_bytes = 18_619_136,
        .route_search_workspace_bytes = 12,
        .external_provided_buffer_bytes = 1_048_576,
        .total_bytes = 19_706_320,
    }, fixed);
    try std.testing.expectEqualDeep(memory_budget.PerWorker{
        .worker_value_bytes = 448,
        .storage_value_bytes = 272,
        .backend_value_bytes = 37_888,
        .storage_slab_bytes = 18_619_136,
        .route_search_workspace_bytes = 12,
        .external_provided_buffer_bytes = 1_048_576,
        .provided_buffer_descriptor_mapping_bytes = 1_024,
        .provided_buffer_descriptor_mapping_vm_bytes = 4_096,
        .io_uring_sq_cq_mapping_bytes = 9_280,
        .io_uring_sq_cq_mapping_vm_bytes = 12_288,
        .io_uring_sqe_mapping_bytes = 16_384,
        .io_uring_sqe_mapping_vm_bytes = 16_384,
        .caller_owned_bytes = 19_706_320,
        .framework_mapping_bytes = 26_688,
        .framework_mapping_vm_bytes = 32_768,
        .requested_total_bytes = 19_733_008,
        .total_bytes = 19_739_088,
    }, report.per_worker);
    try std.testing.expectEqual(@as(u64, 12), report.process_route_search_workspace_bytes);
    try std.testing.expectEqual(@as(u64, 19_739_088), report.process_total_bytes);

    try backend.deinit();
    backend_live = false;
    std.posix.munmap(buffer_mapping);
    buffers_live = false;
}

test "real initialized backend reports exact fixed worker memory" {
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const mappings = backend.memoryMappings().?;
    try std.testing.expectError(
        error.WorkerCountZero,
        memory_budget.report(Worker, Storage, Backend, &backend, 0),
    );
    const report = try memory_budget.report(Worker, Storage, Backend, &backend, 3);
    try std.testing.expectEqual(@sizeOf(Worker), report.per_worker.worker_value_bytes);
    try std.testing.expectEqual(@sizeOf(Storage), report.per_worker.storage_value_bytes);
    try std.testing.expectEqual(@sizeOf(Backend), report.per_worker.backend_value_bytes);
    try std.testing.expectEqual(Storage.required_bytes, report.per_worker.storage_slab_bytes);
    try std.testing.expectEqual(
        @sizeOf(ReceiveBuffers.Buffers),
        report.per_worker.external_provided_buffer_bytes,
    );
    try std.testing.expectEqual(
        ReceiveBuffers.descriptor_bytes,
        report.per_worker.provided_buffer_descriptor_mapping_bytes,
    );
    try std.testing.expectEqual(
        mappingVmBytes(ReceiveBuffers.descriptor_bytes),
        report.per_worker.provided_buffer_descriptor_mapping_vm_bytes,
    );
    try std.testing.expectEqual(mappings.sq_cq, report.per_worker.io_uring_sq_cq_mapping_bytes);
    try std.testing.expectEqual(
        mappingVmBytes(mappings.sq_cq),
        report.per_worker.io_uring_sq_cq_mapping_vm_bytes,
    );
    try std.testing.expectEqual(mappings.sqes, report.per_worker.io_uring_sqe_mapping_bytes);
    try std.testing.expectEqual(
        mappingVmBytes(mappings.sqes),
        report.per_worker.io_uring_sqe_mapping_vm_bytes,
    );
    try std.testing.expectEqual(
        report.per_worker.caller_owned_bytes + report.per_worker.framework_mapping_bytes,
        report.per_worker.requested_total_bytes,
    );
    try std.testing.expectEqual(
        report.per_worker.caller_owned_bytes + report.per_worker.framework_mapping_vm_bytes,
        report.per_worker.total_bytes,
    );
    try std.testing.expectEqual(
        report.per_worker.total_bytes * @as(u64, report.worker_count),
        report.process_total_bytes,
    );

    try backend.deinit();
    backend_live = false;
    try std.testing.expectError(
        error.BackendNotLive,
        memory_budget.report(Worker, Storage, Backend, &backend, 1),
    );
}

test "real io_uring worker serves ping over loopback and shuts down quiescently" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    try sendAll(client, ping_request);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);

    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));
    try driveUntilCompleted(&worker, &backend, sample, &state, 1);

    var received: [ping_response.len]u8 = undefined;
    try receiveExact(client, &received);
    try std.testing.expectEqualStrings(ping_response, &received);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try std.testing.expectEqual(@as(u16, 1), state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

test "real io_uring worker preserves fragmented pipelined requests" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    const first_fragment = "GET /pi";
    try sendAll(client, first_fragment);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);

    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));
    try driveUntilPartialHead(
        &worker,
        &backend,
        sample,
        &storage,
        &state,
        .first_head,
        0,
        first_fragment,
    );

    try sendAll(client, ping_request[first_fragment.len..]);
    try sendAll(client, ping_request);
    try driveUntilCompleted(&worker, &backend, sample, &state, 2);

    var received: [ping_response.len * 2]u8 = undefined;
    try receiveExact(client, &received);
    try std.testing.expectEqualStrings(ping_response ++ ping_response, &received);
    try std.testing.expectEqual(@as(u16, 2), state.calls);
    try std.testing.expectEqual(@as(u16, 2), state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

test "real io_uring partial request head times out with exact 408" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    const first_fragment = "GET /pi";
    try sendAll(client, first_fragment);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);

    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));
    try driveUntilPartialHead(
        &worker,
        &backend,
        sample,
        &storage,
        &state,
        .first_head,
        0,
        first_fragment,
    );
    try driveUntilResponseQueued(&worker, &backend, sample, &storage, &state);

    var received: [request_timeout_response.len]u8 = undefined;
    try receiveExact(client, &received);
    try std.testing.expectEqualStrings(request_timeout_response, &received);
    try std.testing.expectEqual(@as(u16, 0), state.calls);
    try std.testing.expectEqual(@as(u16, 0), state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    try driveUntilConnectionsClosed(&worker, &backend, sample);
    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

test "real io_uring recycles receive buffers and drains pending cancellations" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);

    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));

    for (0..buffer_reuse_request_count) |request_index| {
        try sendAll(client, ping_request);
        const expected: u16 = @intCast(request_index + 1);
        try driveUntilCompleted(&worker, &backend, sample, &state, expected);

        var received: [ping_response.len]u8 = undefined;
        try receiveExact(client, &received);
        try std.testing.expectEqualStrings(ping_response, &received);
        try std.testing.expectEqual(@as(u16, 0), backend.borrowedCount());
    }
    try std.testing.expectEqual(buffer_reuse_request_count, state.calls);
    try std.testing.expectEqual(buffer_reuse_request_count, state.completed);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    const fragment = "GET /pi";
    try sendAll(client, fragment);
    try driveUntilPartialHead(
        &worker,
        &backend,
        sample,
        &storage,
        &state,
        .reused_head,
        buffer_reuse_request_count,
        fragment,
    );
    var live_connections: u16 = 0;
    for (storage.connections) |connection| {
        if (connection.phase == .free) continue;
        live_connections += 1;
        try std.testing.expect(connection.receive_token != null);
        try std.testing.expect(connection.timeout_token != null);
    }
    try std.testing.expectEqual(@as(u16, 1), live_connections);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try std.testing.expectEqual(@as(u16, 0), backend.borrowedCount());
    try std.testing.expectEqual(@as(u16, 0), state.aborted);
    try backend.deinit();
    backend_live = false;
}

test "real io_uring burst stays queued until descriptor capacity returns" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    var clients: [burst_client_count]linux.fd_t = undefined;
    var client_count: usize = 0;
    defer {
        for (clients[0..client_count]) |client| {
            if (client >= 0) _ = linux.close(client);
        }
    }
    for (&clients) |*client| {
        client.* = try connectClient(listener.bound_address);
        client_count += 1;
    }
    const queued_client = clients[limits.connection_slots];
    try sendAll(queued_client, ping_request);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const descriptor_baseline = try openFileDescriptorCount();
    const descriptor_limit = try std.math.add(
        u16,
        descriptor_baseline,
        limits.connection_slots,
    );

    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));
    try driveUntilCapacityPaused(&worker, &backend, sample, descriptor_limit);
    const full = worker.cleanupStatus();
    try std.testing.expectEqual(limits.connection_slots, full.live_connections);
    try std.testing.expectEqual(@as(u8, 0), full.listener_operations);
    try std.testing.expectEqual(
        @as(u64, limits.connection_slots),
        worker.metricsSnapshot().connections_accepted,
    );

    _ = linux.close(clients[0]);
    clients[0] = -1;
    try driveUntilCompleted(&worker, &backend, sample, &state, 1);

    var received: [ping_response.len]u8 = undefined;
    try receiveExact(queued_client, &received);
    try std.testing.expectEqualStrings(ping_response, &received);
    const resumed = worker.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 3), resumed.connections_accepted);
    try std.testing.expectEqual(limits.connection_slots, resumed.live_connections);
    try std.testing.expectEqual(limits.connection_slots, resumed.connections_high_water);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

test "real io_uring fatal accept ownership requires process exit" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var storage: Storage = undefined;
    var storage_ready = false;
    var backend_live = true;
    defer if (backend_live) {
        abortTestBackend(&backend, if (storage_ready) &storage else null);
    };
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try expectProgress(try worker.start(sample));

    const wrong_worker = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 1,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectError(error.InvalidCompletion, worker.handle(.{
        .token = wrong_worker,
        .result = .{ .failure = .canceled },
        .more = false,
    }, sample));
    backend_live = false;

    const status = worker.cleanupStatus();
    try std.testing.expect(status.fatal);
    try std.testing.expect(status.requiresProcessExit());
    try std.testing.expect(!status.quiescent());
    try std.testing.expectEqual(worker_runtime.Phase.failed, status.phase);
    try std.testing.expectEqual(@as(u32, 0), status.backend_active);
    try std.testing.expectEqual(@as(u16, 0), status.borrowed_receives);
}

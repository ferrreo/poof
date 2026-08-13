const source = @import("worker_file_sink_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const endpoint = source.endpoint;
const multipart = source.multipart;
const response = source.response;
const route = source.route;
const buffer_ring = source.buffer_ring;
const config = source.config;
const connection_body_transport = source.connection_body_transport;
const connection_driver = source.connection_driver;
const gzip_encoder = source.gzip_encoder;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const upload_metrics = source.upload_metrics;
const request_head = source.request_head;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const boundary = source.boundary;
const first_bytes = source.first_bytes;
const second_bytes = source.second_bytes;
const first_part = source.first_part;
const second_part = source.second_part;
const valid_body = source.valid_body;
const failed_body = source.failed_body;
const rejected_body = source.rejected_body;
const missing_required_body = source.missing_required_body;
const invalid_after_first_body = source.invalid_after_first_body;
const success_response = source.success_response;
const failure_response = source.failure_response;
const bad_request_response = source.bad_request_response;
const too_large_response = source.too_large_response;
const unsupported_response = source.unsupported_response;
const forbidden_status = source.forbidden_status;
const Sink = source.Sink;
const Body = source.Body;
const Definition = source.Definition;
const Spec = source.Spec;
const AppState = source.AppState;
const Context = source.Context;
const Consumer = source.Consumer;
const Observe = source.Observe;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const BodyTransport = source.BodyTransport;
const deadline_limits = source.deadline_limits;
const DeadlineBackend = source.DeadlineBackend;
const DeadlineStorage = source.DeadlineStorage;
const DeadlineWorker = source.DeadlineWorker;
const HalfSubmitBackend = source.HalfSubmitBackend;
const HalfSubmitWorker = source.HalfSubmitWorker;
const ActiveGzipUpload = source.ActiveGzipUpload;
const Runtime = source.Runtime;
const Encoding = source.Encoding;
const CloseOrder = source.CloseOrder;
const DrainGoal = source.DrainGoal;
const exerciseActiveGzipResponse = source.exerciseActiveGzipResponse;
const exerciseActiveGzipClose = source.exerciseActiveGzipClose;
const forceActiveParserRejection = source.forceActiveParserRejection;
const drainOrdered = source.drainOrdered;
const deliverCompletion = source.deliverCompletion;
const flushBackend = source.flushBackend;
const expectClientClosedWithoutResponse = source.expectClientClosedWithoutResponse;
const expectParserRejectionMetrics = source.expectParserRejectionMetrics;
const exercisePublication = source.exercisePublication;
const sendMultipart = source.sendMultipart;
const expectStoredFiles = source.expectStoredFiles;
const expectFile = source.expectFile;
const expectFileAbsent = source.expectFileAbsent;
const fileExists = source.fileExists;
const discardLiveSockets = source.discardLiveSockets;
const resolveStep = source.resolveStep;
const waitCompletion = source.waitCompletion;
const clientReady = source.clientReady;
const connectClient = source.connectClient;
const sendAll = source.sendAll;
const receiveExact = source.receiveExact;
const enterTemporary = source.enterTemporary;
const restoreCwd = source.restoreCwd;
const monotonicNow = source.monotonicNow;

test "real worker FileSink gates identity and gzip responses on publication" {
    inline for (.{ Encoding.identity, Encoding.gzip }) |encoding| {
        try exercisePublication(encoding);
    }
}

test "worker init failure clears upload entropy" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var state = AppState{};
    var backend: Backend = undefined;
    var worker: Worker = undefined;
    try std.testing.expectError(error.DriverFailure, worker.init(
        &state,
        &storage,
        &backend,
        0,
        .{ .value = 0 },
        .{ .value = "\r\n" },
    ));
    try std.testing.expectEqual([_]u8{0} ** 32, worker.upload_entropy);
}

test "worker start clock failure clears upload entropy" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var state = AppState{};
    var backend: Backend = undefined;
    var worker: Worker = undefined;
    try worker.init(
        &state,
        &storage,
        &backend,
        0,
        .{ .value = 4 },
        null,
    );

    try std.testing.expectError(error.InvalidClock, worker.start(.{
        .monotonic_ns = 1,
        .epoch_second = -1,
    }));
    try std.testing.expectEqual([_]u8{0} ** 32, worker.upload_entropy);
}

test "real io_uring enforces a one-nanosecond FileSink startup deadline" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: DeadlineBackend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer {
        if (backend_live) _ = backend.abort() catch {};
    }
    var slab: [DeadlineStorage.required_bytes]u8 align(DeadlineStorage.slab_alignment) =
        undefined;
    var storage: DeadlineStorage = undefined;
    try storage.init(&slab);
    var state = AppState{};
    var worker: DeadlineWorker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    var sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    try resolveStep(&worker, try worker.start(sample));

    const wall_deadline = try std.math.add(u64, sample.monotonic_ns, completion_wait_ns);
    var observed = false;
    for (0..completion_limit) |_| {
        const completion = try waitCompletion(&backend);
        sample.monotonic_ns = try monotonicNow();
        const handled = worker.handle(completion, sample);
        if (handled) |step| {
            try resolveStep(&worker, step);
        } else |problem| {
            try std.testing.expectEqual(error.UploadFailure, problem);
            observed = true;
            backend_live = false;
            break;
        }
        if (sample.monotonic_ns >= wall_deadline) return error.StartupDeadlineNotObserved;
    }
    try std.testing.expect(observed);
    const diagnostic = worker.uploadStartupDiagnostic().?;
    try std.testing.expectEqual(
        @TypeOf(diagnostic.failure.deadline.?.kind).deadline,
        diagnostic.failure.deadline.?.kind,
    );
    try std.testing.expectEqual(@as(u64, 1), diagnostic.failure.deadline.?.timeout_ns);
    try std.testing.expect(!worker.cleanupStatus().requiresProcessExit());
}

test "worker half-submitted startup timer requires process exit without sink resume" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var state = AppState{};
    var backend = HalfSubmitBackend{};
    var worker: HalfSubmitWorker = undefined;
    try worker.init(
        &state,
        &storage,
        &backend,
        0,
        .{ .value = 1 },
        null,
    );
    try std.testing.expectError(error.UploadFailure, worker.start(.{
        .monotonic_ns = 1,
        .epoch_second = epoch_second,
    }));
    try std.testing.expectEqual(@as(u8, 2), backend.submit_attempts);
    try std.testing.expect(backend.aborted);
    try std.testing.expectEqual(
        @TypeOf(storage.upload_registry.driver(Sink).startup_state.phase).open_root,
        storage.upload_registry.driver(Sink).startup_state.phase,
    );
    try std.testing.expectEqual(@as(u32, 1), worker.driver.uploadPending());
    try std.testing.expect(!worker.driver.uploadOwnershipProven());
    const status = worker.cleanupStatus();
    try std.testing.expect(status.requiresProcessExit());
    try std.testing.expectEqual(worker_runtime.Phase.failed, status.phase);
}

test "real worker maps FileSink failure to 500 and serves a later request" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, failed_body, .identity);
    try runtime.driveUntilReady();
    var failure: [failure_response.len]u8 = undefined;
    try receiveExact(runtime.client, &failure);
    try std.testing.expectEqualStrings(failure_response, &failure);
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try expectFileAbsent(temporary.dir, "uploads/first.bin");
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);

    try runtime.reconnect();
    try sendMultipart(runtime.client, valid_body, .identity);
    try runtime.driveUntilDecision(1);
    try runtime.driveUntilReady();
    var success: [success_response.len]u8 = undefined;
    try receiveExact(runtime.client, &success);
    try std.testing.expectEqualStrings(success_response, &success);
    try runtime.driveUntilAfter(2);
    try expectStoredFiles(temporary.dir);
    try runtime.stop();
}

test "later file rejection reverses first staging before response" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, rejected_body, .identity);
    try runtime.driveUntilReady();
    var status: [forbidden_status.len]u8 = undefined;
    try receiveExact(runtime.client, &status);
    try std.testing.expectEqualStrings(forbidden_status, &status);
    try expectFileAbsent(temporary.dir, "uploads/first.bin");
    try expectFileAbsent(temporary.dir, "uploads/second.bin");
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    runtime.closeClient();
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try runtime.stop();
}

test "async parser rejection returns 400 and releases request resources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, missing_required_body, .identity);
    try runtime.driveUntilReady();
    var received: [bad_request_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(bad_request_response, &received);
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try expectFileAbsent(temporary.dir, "uploads/first.bin");
    try expectFileAbsent(temporary.dir, "uploads/second.bin");
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        limits.connection_slots,
        runtime.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
    try std.testing.expectEqual(@as(u32, 1), runtime.worker.driver.uploadActiveHandles());
    try expectParserRejectionMetrics(&runtime.worker);

    try runtime.stop();
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadActiveHandles());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
}

test "gzip async parser rejection returns 400 and releases request resources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, missing_required_body, .gzip);
    try runtime.driveUntilReady();
    var received: [bad_request_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(bad_request_response, &received);
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try expectFileAbsent(temporary.dir, "uploads/first.bin");
    try expectFileAbsent(temporary.dir, "uploads/second.bin");
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        limits.connection_slots,
        runtime.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
    try std.testing.expectEqual(@as(u32, 1), runtime.worker.driver.uploadActiveHandles());
    try expectParserRejectionMetrics(&runtime.worker);

    try runtime.stop();
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadActiveHandles());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
}

test "gzip parser rejection after async resume returns 400" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, invalid_after_first_body, .gzip);
    try runtime.driveUntilReady();
    var received: [bad_request_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(bad_request_response, &received);
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try expectFileAbsent(temporary.dir, "uploads/first.bin");
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try std.testing.expectEqual(limits.request_slots, runtime.storage.request_pool.available());
    try std.testing.expectEqual(
        limits.connection_slots,
        runtime.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
    try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
    try expectParserRejectionMetrics(&runtime.worker);
    try std.testing.expect(runtime.worker.uploadMetricsSnapshot().window_full_count != 0);
    try runtime.stop();
}

test "active gzip worker parser rejection preserves 400 413 and 415" {
    const cases = .{
        .{ request_head.Status.bad_request, bad_request_response },
        .{ request_head.Status.payload_too_large, too_large_response },
        .{ request_head.Status.unsupported_media_type, unsupported_response },
    };
    inline for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, "uploads");
        const original_cwd = try enterTemporary(temporary.dir.handle);
        defer restoreCwd(original_cwd);
        var runtime = Runtime{};
        try runtime.init();
        defer runtime.abort();

        _ = try forceActiveParserRejection(&runtime, case[0]);
        try runtime.driveUntilReady();
        var received: [case[1].len]u8 = undefined;
        try receiveExact(runtime.client, &received);
        try std.testing.expectEqualStrings(case[1], &received);
        try runtime.driveUntilAfter(1);
        try runtime.driveUntilClosed(1);
        try std.testing.expectEqual(
            limits.request_slots,
            runtime.storage.request_pool.available(),
        );
        try std.testing.expectEqual(
            limits.connection_slots,
            runtime.storage.connection_pool.available(),
        );
        try std.testing.expectEqual(
            limits.gzip.decoder_slots,
            runtime.storage.gzipPool().?.available(),
        );
        try std.testing.expectEqual(@as(u32, 0), runtime.worker.driver.uploadPending());
        try std.testing.expect(runtime.worker.driver.uploadOwnershipProven());
        try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
        try expectParserRejectionMetrics(&runtime.worker);
        try runtime.stop();
    }
}

test "active gzip parser rejection waits for decoder and upload in either order" {
    inline for (.{ CloseOrder.gzip_terminal_first, CloseOrder.upload_cqes_first }) |order| {
        try exerciseActiveGzipResponse(order);
    }
}

test "active gzip parser rejection close reaps decoder and upload in either order" {
    inline for (.{ CloseOrder.gzip_terminal_first, CloseOrder.upload_cqes_first }) |order| {
        try exerciseActiveGzipClose(order);
    }
}

test "post-decision reset cannot finalize FileSink twice" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "uploads");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendMultipart(runtime.client, valid_body, .identity);
    try runtime.driveUntilDecision(1);
    try runtime.driveUntilPublished(temporary.dir);
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try runtime.resetClient();
    try runtime.driveUntilAfter(1);
    try runtime.driveUntilClosed(1);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.decisions);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.after_calls);
    try std.testing.expectEqual(@as(u32, 0), runtime.report().live_anonymous);
    try expectStoredFiles(temporary.dir);
    try runtime.stop();
}

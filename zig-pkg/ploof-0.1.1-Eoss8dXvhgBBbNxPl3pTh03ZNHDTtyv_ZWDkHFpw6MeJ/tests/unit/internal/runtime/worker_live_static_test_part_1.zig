const source = @import("worker_live_static_test.zig");
const std = source.std;
const application = source.application;
const response = source.response;
const static_file = source.static_file;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const App = source.App;
const limits = source.limits;
const Storage = source.Storage;
const TestReactor = source.TestReactor;
const Driver = source.Driver;
const Worker = source.Worker;
const TinyTestReactor = source.TinyTestReactor;
const TinyWorker = source.TinyWorker;
const MultiRootApp = source.MultiRootApp;
const MultiRootStorage = source.MultiRootStorage;
const MultiRootDriver = source.MultiRootDriver;
const LiveHarness = source.LiveHarness;
const isDrainOperation = source.isDrainOperation;
const CancelSendStage = source.CancelSendStage;
const PendingSend = source.PendingSend;
const long_content = source.long_content;
const reachPendingSend = source.reachPendingSend;
const expectRootOperation = source.expectRootOperation;
const findRootSubmission = source.findRootSubmission;
const settleDriverRootTarget = source.settleDriverRootTarget;
const settleWorkerRootTarget = source.settleWorkerRootTarget;
const completeAllStaticCloses = source.completeAllStaticCloses;
const fillDirectoryStat = source.fillDirectoryStat;
const ScheduleStage = source.ScheduleStage;
const RootSchedule = source.RootSchedule;
const fuzzLiveStaticControllerSchedule = source.fuzzLiveStaticControllerSchedule;
const fuzzRootSchedule = source.fuzzRootSchedule;
const settleLatePositiveRootTimeout = source.settleLatePositiveRootTimeout;
const expectFuzzRootIdle = source.expectFuzzRootIdle;
const settleFuzzRootTarget = source.settleFuzzRootTarget;
const completeRootControl = source.completeRootControl;
const fuzzRequestSchedule = source.fuzzRequestSchedule;
const reachScheduleStage = source.reachScheduleStage;
const RandomDrain = source.RandomDrain;
const expectScheduleClean = source.expectScheduleClean;
const expectDescriptorLedgerClosed = source.expectDescriptorLedgerClosed;
const expectZeroed = source.expectZeroed;

test "live static roots form a completion-driven startup and stop barrier" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var driver = try Driver.init(
        &state,
        &storage,
        &io,
        3,
        .{ .date = "Tue, 14 Jul 2026 12:00:00 GMT" },
    );

    try std.testing.expectEqual(.pending, try driver.beginLiveStaticRoots(1));
    try std.testing.expect(!driver.liveStaticRootsReady());
    const open = findRootSubmission(&io, .file_open).?;
    try expectRootOperation(open, .file_open);
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            open,
            .{ .success = .{ .file_open = .{ .value = 41 } } },
            1,
        ),
    );
    const stat = findRootSubmission(&io, .file_stat).?;
    try expectRootOperation(stat, .file_stat);
    fillDirectoryStat(stat.operation.file_stat.output);
    try std.testing.expectEqual(
        .roots_ready,
        try settleDriverRootTarget(
            &driver,
            &io,
            stat,
            .{ .success = .{ .file_stat = {} } },
            1,
        ),
    );
    try std.testing.expect(driver.liveStaticRootsReady());
    try std.testing.expectEqual(@as(u16, 0), driver.liveStaticPending());

    try std.testing.expectEqual(.pending, try driver.beginLiveStaticStop());
    const close = findRootSubmission(&io, .file_close).?;
    try expectRootOperation(close, .file_close);
    try io.complete(close.token, .{ .success = .{ .file_close = {} } }, false);
    try std.testing.expectEqual(
        .stopped,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
    try std.testing.expect(driver.liveStaticStopped());
}

test "worker readiness waits for static root validation before arming accept" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &io, 3, .{ .value = 91 }, null);

    try std.testing.expectEqual(
        worker_runtime.Step.progressed,
        try worker.start(.{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 }),
    );
    try std.testing.expect(!worker.startupReady());
    try std.testing.expect(worker.controller.accept_token == null);
    const open = findRootSubmission(&io, .file_open).?;
    try expectRootOperation(open, .file_open);
    try std.testing.expectEqual(
        worker_runtime.Step.progressed,
        try settleWorkerRootTarget(
            &worker,
            &io,
            open,
            .{ .success = .{ .file_open = .{ .value = 42 } } },
            2,
        ),
    );
    try std.testing.expect(!worker.startupReady());
    const stat = findRootSubmission(&io, .file_stat).?;
    try expectRootOperation(stat, .file_stat);
    fillDirectoryStat(stat.operation.file_stat.output);
    try std.testing.expectEqual(
        worker_runtime.Step.progressed,
        try settleWorkerRootTarget(
            &worker,
            &io,
            stat,
            .{ .success = .{ .file_stat = {} } },
            3,
        ),
    );
    try std.testing.expect(worker.startupReady());
    try std.testing.expect(worker.controller.accept_token != null);
    try std.testing.expect(worker.startupFailure() == null);
}

test "worker preserves a bounded static-root startup diagnostic" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &io, 3, .{ .value = 92 }, null);
    _ = try worker.start(.{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 });
    const open = findRootSubmission(&io, .file_open).?;

    try std.testing.expectError(
        error.StaticFailure,
        settleWorkerRootTarget(&worker, &io, open, .{ .failure = .not_found }, 2),
    );
    const diagnostic = worker.startupFailure().?;
    try std.testing.expectEqual(@as(u16, 0), diagnostic.root_index);
    try std.testing.expectEqualStrings("/srv/assets", diagnostic.path);
    try std.testing.expectEqual(reactor.CompletionError.not_found, diagnostic.problem);
}

test "static root timeout closes a raced positive descriptor in both cancel orders" {
    inline for (.{ false, true }) |cancel_first| {
        var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
        var storage: Storage = undefined;
        try storage.init(&slab);
        var io = TestReactor{};
        var state = App.StateType{};
        var driver = try Driver.init(
            &state,
            &storage,
            &io,
            3,
            .{ .date = fixed_date },
        );
        try std.testing.expectEqual(.pending, try driver.beginLiveStaticRoots(1));
        const target = findRootSubmission(&io, .file_open).?;
        const timeout = findRootSubmission(&io, .timeout).?;
        try io.complete(timeout.token, .{ .success = .{ .timeout = {} } }, false);
        try std.testing.expectEqual(
            .none,
            try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
        );
        const cancel = findRootSubmission(&io, .file_cancel).?;
        if (cancel_first) {
            try io.complete(cancel.token, .{ .success = .{ .file_cancel = .canceled } }, false);
            try std.testing.expectEqual(
                .none,
                try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
            );
        }
        try io.complete(
            target.token,
            .{ .success = .{ .file_open = .{ .value = 77 } } },
            false,
        );
        try std.testing.expectEqual(
            .none,
            try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
        );
        if (!cancel_first) {
            try io.complete(cancel.token, .{ .success = .{ .file_cancel = .not_found } }, false);
            try std.testing.expectEqual(
                .none,
                try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
            );
        }
        const close = findRootSubmission(&io, .file_close).?;
        try std.testing.expectEqual(@as(i32, 77), close.operation.file_close.file.value);
        try std.testing.expectError(
            error.BackendFailure,
            settleDriverRootTarget(
                &driver,
                &io,
                close,
                .{ .success = .{ .file_close = {} } },
                2,
            ),
        );
        try std.testing.expectEqual(@as(u16, 0), driver.liveStaticPending());
        const diagnostic = driver.liveStaticStartupDiagnostic().?;
        try std.testing.expectEqual(.deadline, diagnostic.kind);
    }
}

test "static root rejects stale directory mode without STATX type presence" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var driver = try Driver.init(&state, &storage, &io, 3, .{ .date = fixed_date });
    try std.testing.expectEqual(.pending, try driver.beginLiveStaticRoots(1));
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            findRootSubmission(&io, .file_open).?,
            .{ .success = .{ .file_open = .{ .value = 78 } } },
            2,
        ),
    );
    const stat = findRootSubmission(&io, .file_stat).?;
    stat.operation.file_stat.output.mode = 0o040755;
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            stat,
            .{ .success = .{ .file_stat = {} } },
            3,
        ),
    );
    try std.testing.expectError(
        error.BackendFailure,
        settleDriverRootTarget(
            &driver,
            &io,
            findRootSubmission(&io, .file_close).?,
            .{ .success = .{ .file_close = {} } },
            4,
        ),
    );
    try std.testing.expectEqual(
        reactor.CompletionError.invalid_resource,
        driver.liveStaticStartupDiagnostic().?.problem,
    );
}

test "later static root failure rolls back every earlier descriptor" {
    var slab: [MultiRootStorage.required_bytes]u8 align(MultiRootStorage.slab_alignment) =
        undefined;
    var storage: MultiRootStorage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = MultiRootApp.StateType{};
    var driver = try MultiRootDriver.init(
        &state,
        &storage,
        &io,
        3,
        .{ .date = fixed_date },
    );
    try std.testing.expectEqual(.pending, try driver.beginLiveStaticRoots(1));
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            findRootSubmission(&io, .file_open).?,
            .{ .success = .{ .file_open = .{ .value = 80 } } },
            2,
        ),
    );
    const first_stat = findRootSubmission(&io, .file_stat).?;
    fillDirectoryStat(first_stat.operation.file_stat.output);
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            first_stat,
            .{ .success = .{ .file_stat = {} } },
            3,
        ),
    );
    try std.testing.expectEqual(
        .none,
        try settleDriverRootTarget(
            &driver,
            &io,
            findRootSubmission(&io, .file_open).?,
            .{ .failure = .permission_denied },
            4,
        ),
    );
    const rollback = findRootSubmission(&io, .file_close).?;
    try std.testing.expectEqual(@as(i32, 80), rollback.operation.file_close.file.value);
    try std.testing.expectError(
        error.BackendFailure,
        settleDriverRootTarget(
            &driver,
            &io,
            rollback,
            .{ .success = .{ .file_close = {} } },
            5,
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), driver.liveStaticPending());
    try std.testing.expectEqual(@as(u16, 1), driver.liveStaticStartupDiagnostic().?.root_index);
}

test "static root deadline overflow fails before submitting ownership" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var driver = try Driver.init(&state, &storage, &io, 3, .{ .date = fixed_date });
    try std.testing.expectError(
        error.BackendFailure,
        driver.beginLiveStaticRoots(std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(@as(u16, 0), driver.liveStaticPending());
    try std.testing.expectEqual(.clock_overflow, driver.liveStaticStartupDiagnostic().?.kind);
}

test "timeout submission failure retains target and requires process exit" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TinyTestReactor{};
    var state = App.StateType{};
    var worker: TinyWorker = undefined;
    try worker.init(&state, &storage, &io, 3, .{ .value = 93 }, null);
    try std.testing.expectError(
        error.StaticFailure,
        worker.start(.{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 }),
    );
    try std.testing.expect(worker.cleanupStatus().requiresProcessExit());
    try std.testing.expectEqual(@as(u32, 0), io.activeCount());
    try std.testing.expectEqual(.io, worker.startupFailure().?.kind);
}

test "timed-out rollback close is synchronously recovered after backend abort" {
    const opened = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(opened));
    const descriptor: i32 = @intCast(opened);
    errdefer _ = std.os.linux.close(descriptor);

    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &io, 3, .{ .value = 94 }, null);
    _ = try worker.start(.{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 });
    _ = try settleWorkerRootTarget(
        &worker,
        &io,
        findRootSubmission(&io, .file_open).?,
        .{ .success = .{ .file_open = .{ .value = descriptor } } },
        2,
    );
    _ = try settleWorkerRootTarget(
        &worker,
        &io,
        findRootSubmission(&io, .file_stat).?,
        .{ .failure = .io_failure },
        3,
    );
    const close = findRootSubmission(&io, .file_close).?;
    const timeout = findRootSubmission(&io, .timeout).?;
    try io.complete(timeout.token, .{ .success = .{ .timeout = {} } }, false);
    _ = try worker.handle(
        io.nextCompletion().?,
        .{ .monotonic_ns = 4, .epoch_second = 1_784_030_400 },
    );
    const cancel = findRootSubmission(&io, .file_cancel).?;
    try io.complete(close.token, .{ .failure = .canceled }, false);
    _ = try worker.handle(
        io.nextCompletion().?,
        .{ .monotonic_ns = 4, .epoch_second = 1_784_030_400 },
    );
    try io.complete(cancel.token, .{ .success = .{ .file_cancel = .canceled } }, false);
    try std.testing.expectError(
        error.StaticFailure,
        worker.handle(
            io.nextCompletion().?,
            .{ .monotonic_ns = 4, .epoch_second = 1_784_030_400 },
        ),
    );
    try std.testing.expect(!worker.cleanupStatus().requiresProcessExit());
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(descriptor, std.os.linux.F.GETFD, 0)),
    );
}

test "live static GET sends exact file through bounded reads" {
    var content: [5_137]u8 = undefined;
    for (&content, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var harness: LiveHarness = undefined;
    try harness.init(&content);
    const connection = try harness.request(
        "GET /assets/app.js HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try harness.runResponse(connection);

    try std.testing.expectEqualStrings("app.js", harness.opened(0));
    try std.testing.expect(std.mem.startsWith(u8, harness.written(), "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(
        std.mem.indexOf(u8, harness.written(), "content-type: text/javascript") != null,
    );
    try std.testing.expectEqualSlices(u8, &content, try harness.body());
}

test "live static HEAD and range preserve HTTP wire semantics" {
    const content = "0123456789abcdef";
    var head: LiveHarness = undefined;
    try head.init(content);
    const head_connection = try head.request(
        "HEAD /assets/app.css HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try head.runResponse(head_connection);
    try std.testing.expectEqual(@as(usize, 0), (try head.body()).len);
    try std.testing.expect(
        std.mem.indexOf(u8, head.written(), "content-length: 16\r\n") != null,
    );

    var range: LiveHarness = undefined;
    try range.init(content);
    const range_connection = try range.request(
        "GET /assets/app.css HTTP/1.1\r\n" ++
            "Host: example.test\r\nRange: bytes=2-5\r\n\r\n",
    );
    try range.runResponse(range_connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        range.written(),
        "HTTP/1.1 206 Partial Content\r\n",
    ));
    try std.testing.expect(
        std.mem.indexOf(u8, range.written(), "content-range: bytes 2-5/16\r\n") != null,
    );
    try std.testing.expectEqualStrings("2345", try range.body());
}

test "live static directory redirect and index use descriptor-relative paths" {
    const content = "index body";
    var redirect: LiveHarness = undefined;
    try redirect.init(content);
    redirect.directory_path = "docs";
    const redirect_connection = try redirect.request(
        "GET /assets/docs HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try redirect.runResponse(redirect_connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        redirect.written(),
        "HTTP/1.1 308 Permanent Redirect\r\n",
    ));
    try std.testing.expect(
        std.mem.indexOf(u8, redirect.written(), "location: /assets/docs/\r\n") != null,
    );

    var index: LiveHarness = undefined;
    try index.init(content);
    index.directory_path = "docs";
    const index_connection = try index.request(
        "GET /assets/docs/ HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try index.completeStatic(index.findStatic(.file_open).?);
    try index.completeStatic(index.findStatic(.file_stat).?);
    const index_open = index.findStatic(.file_open).?;
    try std.testing.expectEqual(
        index.directory_descriptor.?,
        index_open.operation.file_open.base.directory.value,
    );
    try std.testing.expectEqualStrings("index.html", index_open.operation.file_open.path);
    try index.completeStatic(index_open);
    try index.runResponse(index_connection);
    try std.testing.expectEqual(@as(u8, 2), index.opened_count);
    try std.testing.expectEqualStrings("docs", index.opened(0));
    try std.testing.expectEqualStrings("index.html", index.opened(1));
    try std.testing.expectEqualStrings(content, try index.body());
}

test "index open retains directory ownership across cancellation races" {
    inline for (.{ false, true }) |cancel_first| {
        var harness: LiveHarness = undefined;
        try harness.init("index body");
        harness.directory_path = "docs";
        const connection = try harness.request(
            "GET /assets/docs/ HTTP/1.1\r\nHost: example.test\r\n\r\n",
        );
        try harness.completeStatic(harness.findStatic(.file_open).?);
        try harness.completeStatic(harness.findStatic(.file_stat).?);
        const target = harness.findStatic(.file_open).?;
        _ = try harness.driver.stop(connection);
        const cancel = harness.findStatic(.file_cancel).?;
        if (cancel_first) {
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .canceled } },
            );
        }
        try harness.completeStatic(target);
        if (!cancel_first) {
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .not_found } },
            );
        }
        try completeAllStaticCloses(&harness);
        try harness.runReleased(connection);
        try std.testing.expectEqualSlices(
            i32,
            &.{ 50, 51 },
            harness.closed_descriptors[0..harness.closed_count],
        );
    }
}

test "index directory close cancellation retires both descriptors in either order" {
    inline for (.{ false, true }) |cancel_first| {
        var harness: LiveHarness = undefined;
        try harness.init("index body");
        harness.directory_path = "docs";
        const connection = try harness.request(
            "GET /assets/docs/ HTTP/1.1\r\nHost: example.test\r\n\r\n",
        );
        try harness.completeStatic(harness.findStatic(.file_open).?);
        try harness.completeStatic(harness.findStatic(.file_stat).?);
        try harness.completeStatic(harness.findStatic(.file_open).?);
        const target = harness.findStatic(.file_close).?;
        _ = try harness.driver.stop(connection);
        const cancel = harness.findStatic(.file_cancel).?;
        if (cancel_first) {
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .canceled } },
            );
            try harness.completeStaticResult(target, .{ .failure = .canceled });
        } else {
            try harness.completeStatic(target);
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .not_found } },
            );
        }
        try completeAllStaticCloses(&harness);
        try harness.runReleased(connection);
        try std.testing.expectEqualSlices(
            i32,
            &.{ 50, 51 },
            harness.closed_descriptors[0..harness.closed_count],
        );
    }
}

test "directory abort close propagates a persistent backend failure" {
    var harness: LiveHarness = undefined;
    try harness.init("index body");
    harness.directory_path = "docs";
    const connection = try harness.request(
        "GET /assets/docs/ HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try harness.completeStatic(harness.findStatic(.file_open).?);
    try harness.completeStatic(harness.findStatic(.file_stat).?);
    try harness.completeStatic(harness.findStatic(.file_open).?);
    const first_close = harness.findStatic(.file_close).?;
    try std.testing.expectEqual(
        connection_driver.Disposition.retained,
        try harness.driver.stop(connection),
    );
    const cancel = harness.findStatic(.file_cancel).?;
    try harness.completeStaticResult(first_close, .{ .failure = .canceled });
    try harness.completeStaticResult(
        cancel,
        .{ .success = .{ .file_cancel = .canceled } },
    );
    const retry = harness.findStatic(.file_close).?;
    try harness.io.complete(retry.token, .{ .failure = .io_failure }, false);
    try std.testing.expectError(
        error.BackendFailure,
        harness.driver.handleLiveStatic(
            harness.io.nextCompletion().?,
            1_784_030_400,
            3,
        ),
    );
    try std.testing.expect(harness.findStatic(.file_close) == null);
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticPending());
    try std.testing.expectEqual(@as(u16, 1), harness.driver.liveStaticRequests());
}

test "live static positive short reads complete and early EOF fails closed" {
    const content = "bounded short-read response";
    var short: LiveHarness = undefined;
    try short.init(content);
    short.max_read = 3;
    const short_connection = try short.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try short.runResponse(short_connection);
    try std.testing.expectEqualStrings(content, try short.body());

    var eof: LiveHarness = undefined;
    try eof.init(content);
    eof.zero_read_at = 0;
    const eof_connection = try eof.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try eof.runReleased(eof_connection);
    try std.testing.expectEqual(@as(u16, 0), eof.driver.liveStaticRequests());
    try std.testing.expectEqual(@as(usize, 0), (try eof.body()).len);
}

test "live static slot exhaustion applies bounded 503 backpressure" {
    var harness: LiveHarness = undefined;
    try harness.init("body");
    _ = try harness.request(
        "GET /assets/one.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    _ = try harness.request(
        "GET /assets/two.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    const rejected = try harness.request(
        "GET /assets/three.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );

    try std.testing.expectEqual(@as(u16, 2), harness.driver.liveStaticRequests());
    const send_token = harness.storage.connections[rejected].send_token.?;
    const bytes = harness.io.operation(send_token).?.send.bytes;
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "HTTP/1.1 503 Service Unavailable\r\n",
    ));
    try std.testing.expectEqual(@as(u8, 0), harness.opened_count);
}

const source = @import("worker_upload_runtime_registry_test.zig");
const std = source.std;
const multipart = source.multipart;
const upload_sink_driver = source.upload_sink_driver;
const reactor = source.reactor;
const worker_upload = source.worker_upload;
const base = source.base;
const TestApp = source.TestApp;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const RuntimeSink = source.RuntimeSink;
const RuntimeSinkA = source.RuntimeSinkA;
const RuntimeSinkB = source.RuntimeSinkB;
const RuntimeSinkStartFailure = source.RuntimeSinkStartFailure;
const RuntimeSinkResumeFailure = source.RuntimeSinkResumeFailure;
const RuntimeSinkStopFailure = source.RuntimeSinkStopFailure;
const RuntimeSinkStopDone = source.RuntimeSinkStopDone;
const StartupStage = source.StartupStage;
const TwoStageStartupSink = source.TwoStageStartupSink;
const RuntimeRegistry = source.RuntimeRegistry;
const RuntimeApp = source.RuntimeApp;
const SingleRuntimeApp = source.SingleRuntimeApp;
const RuntimeFailureApp = source.RuntimeFailureApp;
const TwoStageApp = source.TwoStageApp;
const RuntimeStorage = source.RuntimeStorage;
const RuntimeController = source.RuntimeController;
const expectEntropyCleared = source.expectEntropyCleared;
const completeTimedTarget = source.completeTimedTarget;
const targetWinnerSchedule = source.targetWinnerSchedule;
const deadlineWinnerSchedule = source.deadlineWinnerSchedule;
const FailureMode = source.FailureMode;
const rollbackScenario = source.rollbackScenario;
const startThreeRuntimes = source.startThreeRuntimes;
const drainEarlierRuntimes = source.drainEarlierRuntimes;
const normalStopFailureScenario = source.normalStopFailureScenario;
const expectRuntimeFatalMetric = source.expectRuntimeFatalMetric;

test "runtime target winner waits for timeout cancellation CQEs in either order" {
    inline for (.{ false, true }) |cancel_first| {
        try targetWinnerSchedule(cancel_first);
    }
}

test "runtime deadline winner waits for target cancellation CQEs in either order" {
    inline for (.{ false, true }) |cancel_first| {
        try deadlineWinnerSchedule(cancel_first);
    }
}

test "deadline race closes a positive OPEN that cancellation could not stop" {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x43} ** 32),
        60,
    ) == .none);
    const target = io.takeKind(.file_open);
    const timeout = io.takeKind(.timeout);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = timeout.token,
        .result = .{ .success = .{ .timeout = {} } },
        .more = false,
    }, 61) == .none);
    const cancel = io.takeKind(.upload_cancel);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = target.token,
        .result = .{ .success = .{ .file_open = .{ .value = 92 } } },
        .more = false,
    }, 62) == .none);
    try std.testing.expect(storage.upload_registry.a.runtimePointer() == null);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .upload_cancel = .not_found } },
        .more = false,
    }, 63) == .none);
    try std.testing.expect(storage.upload_registry.a.runtimePointer() == null);
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    const close = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 92), close.operation.file_close.file.value);
    try std.testing.expectError(error.ApplicationFailure, completeTimedTarget(
        &controller,
        &storage,
        &io,
        close,
        .{ .success = .{ .file_close = {} } },
        false,
    ));
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

test "timeout submit half-state never resumes sink and keeps ownership unproven" {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{ .fail_submit_attempt = 2 };
    var controller = try Controller.init(3);
    try std.testing.expectError(error.BackendFailure, controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x44} ** 32),
        70,
    ));
    try std.testing.expectEqual(
        @as(u8, 0),
        storage.upload_registry.a.startup_state.completion_count,
    );
    try std.testing.expectEqual(worker_upload.Phase.starting, controller.phase);
    try std.testing.expectEqual(@as(u32, 1), controller.pending());
    try std.testing.expect(!controller.ownershipProven());
}

test "runtime cancellation submit failure leaves race ownership unproven" {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x45} ** 32),
        80,
    ) == .none);
    const target = io.takeKind(.file_open);
    _ = io.takeKind(.timeout);
    io.fail_next_submit = true;
    try std.testing.expectError(error.BackendFailure, controller.completeAt(
        &storage,
        &io,
        .{
            .token = target.token,
            .result = .{ .success = .{ .file_open = .{ .value = 93 } } },
            .more = false,
        },
        81,
    ));
    try std.testing.expectEqual(
        @as(u8, 0),
        storage.upload_registry.a.startup_state.completion_count,
    );
    try std.testing.expectEqual(@as(u32, 1), controller.pending());
    try std.testing.expect(!controller.ownershipProven());
}

test "runtime stop takes a fresh absolute deadline sample" {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x46} ** 32),
        90,
    ) == .none);
    const open = io.takeKind(.file_open);
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        open,
        .{ .success = .{ .file_open = .{ .value = 94 } } },
        false,
    ) == .registry_ready);
    const stop_ns: u64 = 20 * std.time.ns_per_s;
    try std.testing.expect(try controller.beginRegistryStopAt(
        &storage,
        &io,
        stop_ns,
    ) == .none);
    _ = io.takeKind(.file_close);
    const timeout = io.takeKind(.timeout);
    try std.testing.expectEqual(
        stop_ns + TestStorage.runtime_limits.timeouts.startup_io_ns,
        timeout.operation.timeout.deadline_ns,
    );
}

test "registry starts in catalog order and stops in reverse before releasing handles" {
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try RuntimeController.init(4);

    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0xa5} ** 32),
    ) == .none);
    try std.testing.expectEqual([_]u8{0xa5} ** 32, controller.runtime_entropy);
    const open_a = io.take();
    try std.testing.expectEqual(
        reactor.upload_runtime_control_slot,
        (try open_a.token.fields()).slot_index,
    );
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        open_a,
        .{ .success = .{ .file_open = .{ .value = 80 } } },
        false,
    ) == .none);
    const open_b = io.take();
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        open_b,
        .{ .success = .{ .file_open = .{ .value = 81 } } },
        false,
    ) == .registry_ready);
    try std.testing.expect(controller.registryReady());
    try expectEntropyCleared(&controller);
    try std.testing.expect(storage.upload_registry.a.runtimePointer() != null);
    try std.testing.expect(storage.upload_registry.b.runtimePointer() != null);
    try std.testing.expectEqual(@as(u32, 2), controller.activeHandles());

    try std.testing.expect(try controller.beginRegistryStop(&storage, &io) == .none);
    const close_b = io.take();
    try std.testing.expectEqual(@as(i32, 81), close_b.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        close_b,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    controller.runtime_entropy = @splat(0x5a);
    const close_a = io.take();
    try std.testing.expectEqual(@as(i32, 80), close_a.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        close_a,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .registry_stopped);
    try std.testing.expect(controller.registryStopped());
    try expectEntropyCleared(&controller);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
}

test "later runtimeStart failure rolls constructed runtimes back asynchronously" {
    try rollbackScenario(.start, false);
}

test "runtime resume failure continues reverse rollback after cleanup failure" {
    try rollbackScenario(.resume_failure, true);
}

test "runtime submit failure preserves primary error through rollback" {
    try rollbackScenario(.submit, false);
}

test "rollback stop submission failure abandons poller and closes exact owner" {
    try rollbackScenario(.rollback_submit, false);
}

test "normal runtime stop error closes owner and preserves primary error" {
    try normalStopFailureScenario(RuntimeSinkStopFailure, false);
}

test "runtime stop done with owned handle is fatal and framework closes it" {
    try normalStopFailureScenario(RuntimeSinkStopDone, false);
}

test "runtime owner cleanup cancellation latches unproven ownership" {
    try normalStopFailureScenario(RuntimeSinkStopFailure, true);
}

test "framework closes current-owner handle after adversarial startup failure" {
    const Controller = worker_upload.Controller(TwoStageApp, RuntimeStorage, TestReactor);
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(5);

    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x55} ** 32),
    ) == .none);
    const open = io.take();
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        open,
        .{ .success = .{ .file_open = .{ .value = 90 } } },
        true,
    ) == .none);
    const cleanup = io.take();
    try std.testing.expectEqual(@as(i32, 90), cleanup.operation.file_close.file.value);
    try std.testing.expectError(error.BackendFailure, completeTimedTarget(
        &controller,
        &storage,
        &io,
        cleanup,
        .{ .success = .{ .file_close = {} } },
        false,
    ));
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

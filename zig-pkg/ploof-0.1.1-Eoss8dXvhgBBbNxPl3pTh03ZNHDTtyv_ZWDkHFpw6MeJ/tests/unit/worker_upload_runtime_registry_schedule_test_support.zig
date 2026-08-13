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

pub fn completeTimedTarget(
    controller: anytype,
    storage: *RuntimeStorage,
    io: *TestReactor,
    target: reactor.Submission,
    result: reactor.CompletionResult,
    fail_before_resume: bool,
) !worker_upload.Event {
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = target.token,
        .result = result,
        .more = false,
    }) == .none);
    const timeout = io.take();
    try std.testing.expectEqual(.timeout, (try timeout.token.fields()).kind);
    const cancel = io.take();
    try std.testing.expectEqual(.cancel, (try cancel.token.fields()).kind);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = timeout.token,
        .result = .{ .failure = .canceled },
        .more = false,
    }) == .none);
    if (fail_before_resume) io.fail_next_submit = true;
    return controller.complete(storage, io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    });
}

pub fn targetWinnerSchedule(comptime cancel_first: bool) !void {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(2);
    const started_ns: u64 = 40;
    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x41} ** 32),
        started_ns,
    ) == .none);
    const target = io.takeKind(.file_open);
    const timeout = io.takeKind(.timeout);
    try std.testing.expectEqual(
        started_ns + TestStorage.runtime_limits.timeouts.startup_io_ns,
        timeout.operation.timeout.deadline_ns,
    );
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = target.token,
        .result = .{ .success = .{ .file_open = .{ .value = 91 } } },
        .more = false,
    }, started_ns + 1) == .none);
    try std.testing.expect(storage.upload_registry.a.runtimePointer() == null);
    const cancel = io.takeKind(.cancel);
    const timeout_completion = reactor.Completion{
        .token = timeout.token,
        .result = .{ .failure = .canceled },
        .more = false,
    };
    const cancel_completion = reactor.Completion{
        .token = cancel.token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    };
    const final = if (cancel_first) final: {
        try std.testing.expect(try controller.completeAt(
            &storage,
            &io,
            cancel_completion,
            started_ns + 2,
        ) == .none);
        break :final try controller.completeAt(
            &storage,
            &io,
            timeout_completion,
            started_ns + 3,
        );
    } else final: {
        try std.testing.expect(try controller.completeAt(
            &storage,
            &io,
            timeout_completion,
            started_ns + 2,
        ) == .none);
        break :final try controller.completeAt(
            &storage,
            &io,
            cancel_completion,
            started_ns + 3,
        );
    };
    try std.testing.expect(final == .registry_ready);
    try std.testing.expect(storage.upload_registry.a.runtimePointer() != null);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

pub fn deadlineWinnerSchedule(comptime cancel_first: bool) !void {
    const Controller = worker_upload.Controller(
        SingleRuntimeApp(RuntimeSinkA),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(2);
    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x42} ** 32),
        50,
    ) == .none);
    const target = io.takeKind(.file_open);
    const timeout = io.takeKind(.timeout);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = timeout.token,
        .result = .{ .success = .{ .timeout = {} } },
        .more = false,
    }, 51) == .none);
    const cancel = io.takeKind(.upload_cancel);
    const target_completion = reactor.Completion{
        .token = target.token,
        .result = .{ .failure = .canceled },
        .more = false,
    };
    const cancel_completion = reactor.Completion{
        .token = cancel.token,
        .result = .{ .success = .{ .upload_cancel = .canceled } },
        .more = false,
    };
    if (cancel_first) {
        try std.testing.expect(try controller.completeAt(
            &storage,
            &io,
            cancel_completion,
            52,
        ) == .none);
        try std.testing.expectError(error.ApplicationFailure, controller.completeAt(
            &storage,
            &io,
            target_completion,
            53,
        ));
    } else {
        try std.testing.expect(try controller.completeAt(
            &storage,
            &io,
            target_completion,
            52,
        ) == .none);
        try std.testing.expectError(error.ApplicationFailure, controller.completeAt(
            &storage,
            &io,
            cancel_completion,
            53,
        ));
    }
    try std.testing.expect(storage.upload_registry.a.runtimePointer() == null);
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(
        @as(u64, 50 + TestStorage.runtime_limits.timeouts.startup_io_ns),
        controller.runtime_deadline_diagnostic.?.failure.deadline_ns,
    );
}

pub const FailureMode = enum { start, resume_failure, submit, rollback_submit };

pub fn rollbackScenario(comptime mode: FailureMode, cleanup_failure: bool) !void {
    const FailureSink = if (mode == .start or mode == .rollback_submit)
        RuntimeSinkStartFailure
    else
        RuntimeSinkResumeFailure;
    const FailureController = worker_upload.Controller(
        RuntimeFailureApp(FailureSink),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try FailureController.init(4);

    try beginRollbackScenario(mode, &controller, &storage, &io);
    try finishRollbackScenario(mode, cleanup_failure, &controller, &storage, &io);
}

fn beginRollbackScenario(
    comptime mode: FailureMode,
    controller: anytype,
    storage: *RuntimeStorage,
    io: *TestReactor,
) !void {
    try std.testing.expect(try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{0x77} ** 32),
    ) == .none);
    const open_a = io.take();
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        open_a,
        .{ .success = .{ .file_open = .{ .value = 80 } } },
        false,
    ) == .none);
    const open_b = io.take();
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        open_b,
        .{ .success = .{ .file_open = .{ .value = 81 } } },
        mode == .submit or mode == .rollback_submit,
    ) == .none);
    if (mode == .resume_failure) {
        const failing_open = io.take();
        try std.testing.expect(try completeTimedTarget(
            controller,
            storage,
            io,
            failing_open,
            .{ .failure = .io_failure },
            false,
        ) == .none);
    }
    try std.testing.expectEqual(worker_upload.Phase.rolling_back, controller.phase);
    try expectEntropyCleared(controller);
}

fn finishRollbackScenario(
    comptime mode: FailureMode,
    cleanup_failure: bool,
    controller: anytype,
    storage: *RuntimeStorage,
    io: *TestReactor,
) !void {
    const close_b = io.take();
    try std.testing.expectEqual(@as(i32, 81), close_b.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        close_b,
        if (cleanup_failure)
            .{ .failure = .canceled }
        else
            .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    if (cleanup_failure) {
        const cleanup_b = io.take();
        try std.testing.expectEqual(@as(i32, 81), cleanup_b.operation.file_close.file.value);
        try std.testing.expect(try completeTimedTarget(
            controller,
            storage,
            io,
            cleanup_b,
            .{ .success = .{ .file_close = {} } },
            false,
        ) == .none);
    }
    const close_a = io.take();
    try std.testing.expectEqual(@as(i32, 80), close_a.operation.file_close.file.value);
    const final = completeTimedTarget(
        controller,
        storage,
        io,
        close_a,
        .{ .success = .{ .file_close = {} } },
        false,
    );
    try std.testing.expectError(
        if (mode == .submit) error.BackendFailure else error.ApplicationFailure,
        final,
    );
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try expectEntropyCleared(controller);
    try std.testing.expectEqual(@as(?u16, 2), controller.startup_failure_index);
    try std.testing.expectEqual(@as(?u16, 2), controller.runtime_metric_index);
    try expectRuntimeFatalMetric(controller, 2);
    try std.testing.expectEqual(
        cleanup_failure or mode == .rollback_submit,
        controller.rollback_cleanup_failed,
    );
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expect(storage.upload_registry.a.quiescent());
    try std.testing.expect(storage.upload_registry.b.quiescent());
}

pub fn startThreeRuntimes(controller: anytype, storage: *RuntimeStorage, io: *TestReactor) !void {
    try std.testing.expect(try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{0x33} ** 32),
    ) == .none);
    for (0..3) |offset| {
        const open = io.take();
        const event = try completeTimedTarget(
            controller,
            storage,
            io,
            open,
            .{ .success = .{ .file_open = .{
                .value = 80 + @as(i32, @intCast(offset)),
            } } },
            false,
        );
        try std.testing.expect(if (offset == 2) event == .registry_ready else event == .none);
    }
}

pub fn drainEarlierRuntimes(
    controller: anytype,
    storage: *RuntimeStorage,
    io: *TestReactor,
) !void {
    const close_b = io.take();
    try std.testing.expectEqual(@as(i32, 81), close_b.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        close_b,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    const close_a = io.take();
    try std.testing.expectEqual(@as(i32, 80), close_a.operation.file_close.file.value);
    try std.testing.expectError(error.ApplicationFailure, completeTimedTarget(
        controller,
        storage,
        io,
        close_a,
        .{ .success = .{ .file_close = {} } },
        false,
    ));
}

pub fn normalStopFailureScenario(comptime Sink: type, cleanup_failure: bool) !void {
    const Controller = worker_upload.Controller(
        RuntimeFailureApp(Sink),
        RuntimeStorage,
        TestReactor,
    );
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(6);
    try startThreeRuntimes(&controller, &storage, &io);

    try std.testing.expect(try controller.beginRegistryStop(&storage, &io) == .none);
    const cleanup = io.take();
    try std.testing.expectEqual(@as(i32, 82), cleanup.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        &controller,
        &storage,
        &io,
        cleanup,
        if (cleanup_failure)
            .{ .failure = .canceled }
        else
            .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    try drainEarlierRuntimes(&controller, &storage, &io);

    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(@as(?u16, 2), controller.startup_failure_index);
    try std.testing.expectEqual(@as(?u16, 2), controller.runtime_metric_index);
    try expectRuntimeFatalMetric(&controller, 2);
    try std.testing.expectEqual(cleanup_failure, controller.rollback_cleanup_failed);
    try std.testing.expectEqual(
        @as(u32, @intFromBool(cleanup_failure)),
        controller.activeHandles(),
    );
    try std.testing.expectEqual(!cleanup_failure, controller.ownershipProven());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(storage.upload_registry.driver(Sink).quiescent());
    try std.testing.expect(storage.upload_registry.a.quiescent());
    try std.testing.expect(storage.upload_registry.b.quiescent());
}

pub fn expectRuntimeFatalMetric(controller: anytype, registry_index: u16) !void {
    const snapshot = controller.metricsSnapshot();
    if (snapshot.event_count == 0) return error.TestUnexpectedResult;
    const event = snapshot.events[snapshot.event_count - 1];
    const fatal = switch (event.detail) {
        .fatal_failure => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const identity = fatal.identity orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(registry_index, identity.registry_index);
    try std.testing.expectEqual(@as(u16, 0), identity.instance_index);
}

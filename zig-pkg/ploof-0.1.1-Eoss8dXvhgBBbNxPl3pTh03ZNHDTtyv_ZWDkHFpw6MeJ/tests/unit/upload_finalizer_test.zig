const std = @import("std");
const upload = @import("../../src/multipart/upload.zig");
const finalizer = @import("../../src/internal/upload/finalizer.zig");
const sink_driver = @import("../../src/internal/upload/sink_driver.zig");

const Action = enum(u8) {
    synchronous,
    asynchronous,
    fail_synchronous,
    fail_asynchronous,
    invalid_request,
    sink_invalid_request,
};

const EventKind = enum(u1) { commit, abort };

const Event = struct {
    kind: EventKind,
    id: u8,
};

const TestSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct {
        id: u8 = 0,
        begin_action: Action = .synchronous,
        finish_action: Action = .synchronous,
        commit_action: Action = .synchronous,
        abort_action: Action = .synchronous,
    };
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const StartupState = void;
    pub const Runtime = struct {
        events: [128]Event = undefined,
        event_count: usize = 0,

        fn record(self: *Runtime, kind: EventKind, id: u8) void {
            self.events[self.event_count] = .{ .kind = kind, .id = id };
            self.event_count += 1;
        }

        fn recorded(self: *const Runtime) []const Event {
            return self.events[0..self.event_count];
        }
    };
    pub const Error = error{ Rejected, InvalidRequest };
    pub const io_requirements = upload.IoRequirements{ .sync = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.Rejected,
        };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return lifecycleDone(event);
    }

    pub fn begin(
        _: *Runtime,
        state: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return phaseAction(state.id, state.begin_action, event);
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }

    pub fn finish(
        _: *Runtime,
        state: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return phaseAction(state.id, state.finish_action, event);
    }

    pub fn commit(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return runAction(runtime, state, .commit, state.commit_action, event);
    }

    pub fn abort(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return runAction(runtime, state, .abort, state.abort_action, event);
    }

    fn runAction(
        runtime: *Runtime,
        state: *State,
        kind: EventKind,
        action: Action,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => startAction(runtime, state, kind, action),
            .completion => switch (action) {
                .asynchronous => .{ .done = {} },
                .fail_asynchronous => error.Rejected,
                .sink_invalid_request => error.InvalidRequest,
                else => error.Rejected,
            },
        };
    }

    fn startAction(
        runtime: *Runtime,
        state: *State,
        kind: EventKind,
        action: Action,
    ) Error!upload.Poll(void) {
        runtime.record(kind, state.id);
        return switch (action) {
            .synchronous => .{ .done = {} },
            .asynchronous, .fail_asynchronous => .{ .request = syncRequest(state.id) },
            .fail_synchronous => error.Rejected,
            .sink_invalid_request => error.InvalidRequest,
            .invalid_request => .{ .request = .{ .write = .{
                .file = upload.FileHandle.init(state.id),
                .bytes = "",
                .offset = 0,
            } } },
        };
    }

    fn lifecycleDone(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }

    fn phaseAction(
        id: u8,
        action: Action,
        event: anytype,
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => switch (action) {
                .synchronous => .{ .done = {} },
                .asynchronous, .fail_asynchronous => .{ .request = syncRequest(id) },
                .fail_synchronous => error.Rejected,
                .sink_invalid_request => error.InvalidRequest,
                .invalid_request => .{ .request = .{ .write = .{
                    .file = upload.FileHandle.init(id),
                    .bytes = "",
                    .offset = 0,
                } } },
            },
            .completion => switch (action) {
                .asynchronous => .{ .done = {} },
                .fail_asynchronous => error.Rejected,
                .sink_invalid_request => error.InvalidRequest,
                else => error.Rejected,
            },
        };
    }
};

const Lifecycle = sink_driver.Lifecycle(TestSink);

test "finalizer commits synchronous entries in file-start order" {
    const Finalizer = finalizer.Finalizer(TestSink, 3);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{ makeState(1), makeState(2), makeState(3) };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    const report = (try value.startCommit(&runtime, &lifecycle)).done;
    try std.testing.expect(report.responseAllowed());
    try std.testing.expectEqual(finalizer.Outcome.committed, report.outcome);
    try std.testing.expectEqual(@as(usize, 3), report.commit_attempted_count);
    try std.testing.expectEqual(@as(usize, 3), report.commit_completed_count);
    try expectEvents(&runtime, &.{
        .{ .kind = .commit, .id = 1 },
        .{ .kind = .commit, .id = 2 },
        .{ .kind = .commit, .id = 3 },
    });
    try std.testing.expectError(
        error.AlreadyStarted,
        value.startCommit(&runtime, &lifecycle),
    );
    try std.testing.expectError(
        error.NoOperation,
        value.complete(&runtime, &lifecycle, syncSuccess()),
    );
}

test "finalizer serializes asynchronous commits" {
    const Finalizer = finalizer.Finalizer(TestSink, 3);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{
        stateWithCommit(1, .asynchronous),
        makeState(2),
        stateWithCommit(3, .asynchronous),
    };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    try expectSyncRequest((try value.startCommit(&runtime, &lifecycle)).request, 1);
    try std.testing.expect(value.pendingRequest(&lifecycle) != null);
    try expectSyncRequest(
        (try value.complete(&runtime, &lifecycle, syncSuccess())).request,
        3,
    );
    const report = (try value.complete(&runtime, &lifecycle, syncSuccess())).done;
    try std.testing.expect(report.responseAllowed());
    try expectEvents(&runtime, &.{
        .{ .kind = .commit, .id = 1 },
        .{ .kind = .commit, .id = 2 },
        .{ .kind = .commit, .id = 3 },
    });
}

test "first asynchronous commit failure compensates every begun entry" {
    const Finalizer = finalizer.Finalizer(TestSink, 3);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{
        makeState(1),
        stateWithCommit(2, .fail_asynchronous),
        makeState(3),
    };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    _ = (try value.startCommit(&runtime, &lifecycle)).request;
    const report = (try value.complete(&runtime, &lifecycle, syncSuccess())).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expect(!report.responseAllowed());
    try std.testing.expectEqual(@as(?usize, 1), report.primary.?.entry_index);
    try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
    try std.testing.expectEqual(@as(usize, 2), report.commit_attempted_count);
    try std.testing.expectEqual(@as(usize, 1), report.commit_completed_count);
    try expectEvents(&runtime, &.{
        .{ .kind = .commit, .id = 1 },
        .{ .kind = .commit, .id = 2 },
        .{ .kind = .abort, .id = 3 },
        .{ .kind = .abort, .id = 2 },
        .{ .kind = .abort, .id = 1 },
    });
}

test "explicit abort walks entries in reverse order" {
    const Finalizer = finalizer.Finalizer(TestSink, 3);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{ makeState(1), makeState(2), makeState(3) };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    const report = (try value.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(finalizer.Outcome.aborted, report.outcome);
    try std.testing.expect(report.responseAllowed());
    try std.testing.expectEqual(@as(usize, 3), report.abort_attempted_count);
    try std.testing.expectEqual(@as(usize, 3), report.abort_completed_count);
    try expectEvents(&runtime, &.{
        .{ .kind = .abort, .id = 3 },
        .{ .kind = .abort, .id = 2 },
        .{ .kind = .abort, .id = 1 },
    });
}

test "abort failures are masked and cleanup continues" {
    const Finalizer = finalizer.Finalizer(TestSink, 3);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{
        makeState(1),
        stateWithAbort(2, .fail_asynchronous),
        stateWithAbort(3, .fail_synchronous),
    };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    const first = try value.startAbort(&runtime, &lifecycle, null);
    try expectSyncRequest(first.request, 2);
    const report = (try value.complete(&runtime, &lifecycle, syncSuccess())).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expect(!report.responseAllowed());
    try std.testing.expectEqual(@as(usize, 2), report.cleanup_failure_count);
    try std.testing.expect(report.cleanupFailed(1));
    try std.testing.expect(report.cleanupFailed(2));
    try std.testing.expect(!report.cleanupFailed(0));
    try std.testing.expectEqual(
        finalizer.CleanupFailureClass.sink,
        report.cleanupFailureClass(2).?,
    );
    try std.testing.expectEqual(@as(usize, 3), report.abort_attempted_count);
    try std.testing.expectEqual(@as(usize, 1), report.abort_completed_count);
    try expectEvents(&runtime, &.{
        .{ .kind = .abort, .id = 3 },
        .{ .kind = .abort, .id = 2 },
        .{ .kind = .abort, .id = 1 },
    });
}

test "upstream cancellation is preserved through abort" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = makeState(7);
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    const report = (try value.startAbort(
        &runtime,
        &lifecycle,
        .framework_canceled,
    )).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expect(!report.responseAllowed());
    try std.testing.expectEqual(
        finalizer.FailureClass{ .upstream = .framework_canceled },
        report.primary.?.class,
    );
}

test "invalid sink request is fatal and cannot finalize" {
    const Finalizer = finalizer.Finalizer(TestSink, 2);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{
        stateWithCommit(1, .invalid_request),
        makeState(2),
    };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    const fatal = (try value.startCommit(&runtime, &lifecycle)).fatal;
    try std.testing.expectEqual(finalizer.FatalClass.invalid_request, fatal.class);
    try std.testing.expectEqual(finalizer.FatalPhase.commit, fatal.phase);
    try std.testing.expectEqual(@as(?usize, 0), fatal.entry_index);
    try std.testing.expectError(
        error.AlreadyStarted,
        value.startAbort(&runtime, &lifecycle, null),
    );
}

test "malformed commit completion is fatal" {
    const Finalizer = finalizer.Finalizer(TestSink, 2);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{
        stateWithCommit(1, .asynchronous),
        makeState(2),
    };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    _ = (try value.startCommit(&runtime, &lifecycle)).request;
    const malformed = upload.IoCompletion{ .success = .{ .write = 1 } };
    const fatal = (try value.complete(&runtime, &lifecycle, malformed)).fatal;
    try std.testing.expectEqual(finalizer.FatalClass.completion_kind_mismatch, fatal.class);
    try std.testing.expectEqual(finalizer.FatalPhase.commit, fatal.phase);
    try std.testing.expectEqual(@as(?usize, 0), fatal.entry_index);
    try std.testing.expect(!lifecycle.ownershipProven());
    try std.testing.expectError(
        error.NoOperation,
        value.complete(&runtime, &lifecycle, syncSuccess()),
    );
}

test "active begin and finish preserve collecting phase" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = TestSink.State{
        .id = 1,
        .begin_action = .asynchronous,
        .finish_action = .asynchronous,
    };
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    _ = (try lifecycle.startBegin(&runtime, &item, {})).request;
    try std.testing.expectError(
        error.NotQuiescent,
        value.startAbort(&runtime, &lifecycle, null),
    );
    _ = (try lifecycle.resumeBegin(&runtime, &item, syncSuccess())).done;

    _ = (try lifecycle.startFinish(&runtime, &item, .{ .bytes = 0 })).request;
    try std.testing.expectError(
        error.NotQuiescent,
        value.startCommit(&runtime, &lifecycle),
    );
    _ = (try lifecycle.resumeFinish(&runtime, &item, syncSuccess())).done;

    const report = (try value.startCommit(&runtime, &lifecycle)).done;
    try std.testing.expectEqual(finalizer.Outcome.committed, report.outcome);
}

test "begin and finish sink failures remain abortable" {
    inline for (.{ true, false }) |fail_begin| {
        const Finalizer = finalizer.Finalizer(TestSink, 1);
        var runtime = TestSink.Runtime{};
        var lifecycle = Lifecycle{};
        var item = TestSink.State{ .id = 1 };
        var value = Finalizer.init();
        _ = try value.recordBegun(&item);

        if (fail_begin) {
            item.begin_action = .fail_asynchronous;
            _ = (try lifecycle.startBegin(&runtime, &item, {})).request;
            try std.testing.expectError(
                error.Rejected,
                lifecycle.resumeBegin(&runtime, &item, syncSuccess()),
            );
        } else {
            _ = (try lifecycle.startBegin(&runtime, &item, {})).done;
            item.finish_action = .fail_asynchronous;
            _ = (try lifecycle.startFinish(
                &runtime,
                &item,
                .{ .bytes = 0 },
            )).request;
            try std.testing.expectError(
                error.Rejected,
                lifecycle.resumeFinish(&runtime, &item, syncSuccess()),
            );
        }

        try value.noteSinkFailure(0);
        const report = (try value.startAbort(&runtime, &lifecycle, .upload)).done;
        try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
        try std.testing.expectEqual(@as(usize, 1), report.abort_completed_count);
        try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
        try std.testing.expectEqual(@as(?usize, 0), report.primary.?.entry_index);
    }
}

test "latched begin sink failure cannot become a clean abort" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = TestSink.State{ .id = 1, .begin_action = .fail_synchronous };
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    try std.testing.expectError(
        error.Rejected,
        lifecycle.startBegin(&runtime, &item, {}),
    );
    const report = (try value.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expect(!report.responseAllowed());
    try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
    try std.testing.expectEqual(@as(?usize, null), report.primary.?.entry_index);
}

test "first observed sink failure keeps its exact begun identity" {
    const Finalizer = finalizer.Finalizer(TestSink, 2);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states = [_]TestSink.State{ makeState(1), makeState(2) };
    var value = Finalizer.init();
    for (&states) |*item| _ = try value.recordBegun(item);

    try value.noteSinkFailure(1);
    try value.noteSinkFailure(0);
    const report = (try value.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
    try std.testing.expectEqual(@as(?usize, 1), report.primary.?.entry_index);
}

test "latched invalid begin request is fatal before abort" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = TestSink.State{ .id = 1, .begin_action = .invalid_request };
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    try std.testing.expectError(
        error.InvalidRequest,
        lifecycle.startBegin(&runtime, &item, {}),
    );
    const fatal = (try value.startAbort(&runtime, &lifecycle, null)).fatal;
    try std.testing.expectEqual(finalizer.FatalClass.invalid_request, fatal.class);
    try std.testing.expectEqual(finalizer.FatalPhase.preflight, fatal.phase);
}

test "sink InvalidRequest begin error remains a recoverable sink failure" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = TestSink.State{ .id = 1, .begin_action = .sink_invalid_request };
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    try std.testing.expectError(
        error.InvalidRequest,
        lifecycle.startBegin(&runtime, &item, {}),
    );
    const report = (try value.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
}

test "poisoned borrowed lifecycle is fatal before finalization" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = TestSink.State{ .id = 1, .begin_action = .asynchronous };
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    _ = (try lifecycle.startBegin(&runtime, &item, {})).request;
    const malformed = upload.IoCompletion{ .success = .{ .write = 1 } };
    try std.testing.expectError(
        error.CompletionKindMismatch,
        lifecycle.resumeBegin(&runtime, &item, malformed),
    );
    const fatal = (try value.startAbort(&runtime, &lifecycle, .upload)).fatal;
    try std.testing.expectEqual(finalizer.FatalClass.ownership_unproven, fatal.class);
    try std.testing.expectEqual(finalizer.FatalPhase.preflight, fatal.phase);
    try std.testing.expectError(
        error.AlreadyStarted,
        value.startAbort(&runtime, &lifecycle, .upload),
    );
}

test "sink error sharing driver name remains recoverable" {
    const Finalizer = finalizer.Finalizer(TestSink, 1);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = stateWithCommit(1, .sink_invalid_request);
    var value = Finalizer.init();
    _ = try value.recordBegun(&item);

    const report = (try value.startCommit(&runtime, &lifecycle)).done;
    try std.testing.expectEqual(finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(finalizer.FailureClass.sink, report.primary.?.class);
    try std.testing.expectEqual(@as(usize, 1), report.abort_completed_count);
}

test "zero capacity and full bounds are deterministic" {
    const Empty = finalizer.Finalizer(TestSink, 0);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var item = makeState(1);
    var empty = Empty.init();
    try std.testing.expectError(error.CapacityExceeded, empty.recordBegun(&item));
    const committed = (try empty.startCommit(&runtime, &lifecycle)).done;
    try std.testing.expect(committed.responseAllowed());
    try std.testing.expect(!committed.cleanupFailed(0));

    var aborted = Empty.init();
    const abort_report = (try aborted.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(finalizer.Outcome.aborted, abort_report.outcome);
    try std.testing.expect(abort_report.responseAllowed());

    const One = finalizer.Finalizer(TestSink, 1);
    var one = One.init();
    _ = try one.recordBegun(&item);
    try std.testing.expectError(error.CapacityExceeded, one.recordBegun(&item));
}

test "cleanup failure mask spans every bounded entry" {
    const Finalizer = finalizer.Finalizer(TestSink, 65);
    var runtime = TestSink.Runtime{};
    var lifecycle = Lifecycle{};
    var states: [65]TestSink.State = undefined;
    var value = Finalizer.init();
    for (&states, 0..) |*item, index| {
        item.* = stateWithAbort(@intCast(index + 1), .synchronous);
        _ = try value.recordBegun(item);
    }
    states[64].abort_action = .fail_synchronous;

    const report = (try value.startAbort(&runtime, &lifecycle, null)).done;
    try std.testing.expectEqual(@as(usize, 1), report.cleanup_failure_count);
    try std.testing.expect(report.cleanupFailed(64));
    try std.testing.expect(!report.cleanupFailed(63));
    try std.testing.expect(!report.cleanupFailed(65));
}

fn makeState(id: u8) TestSink.State {
    return .{ .id = id };
}

fn stateWithCommit(id: u8, action: Action) TestSink.State {
    return .{ .id = id, .commit_action = action };
}

fn stateWithAbort(id: u8, action: Action) TestSink.State {
    return .{ .id = id, .abort_action = action };
}

fn syncRequest(id: u8) upload.IoRequest {
    return .{ .sync = .{ .file = upload.FileHandle.init(id) } };
}

fn syncSuccess() upload.IoCompletion {
    return .{ .success = .{ .sync = {} } };
}

fn expectSyncRequest(request: upload.IoRequest, id: u8) !void {
    try std.testing.expectEqual(upload.IoKind.sync, std.meta.activeTag(request));
    try std.testing.expect(request.sync.file.eql(upload.FileHandle.init(id)));
}

fn expectEvents(runtime: *const TestSink.Runtime, expected: []const Event) !void {
    try std.testing.expectEqualSlices(Event, expected, runtime.recorded());
}

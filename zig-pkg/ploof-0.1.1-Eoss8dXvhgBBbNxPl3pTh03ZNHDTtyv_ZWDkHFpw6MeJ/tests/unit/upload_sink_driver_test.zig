const std = @import("std");
const file_sink = @import("../../src/multipart/file_sink.zig");
const file_sink_config = @import("../../src/multipart/file_sink_config.zig");
const upload = @import("../../src/multipart/upload.zig");
const driver = @import("../../src/internal/upload/sink_driver.zig");

const directory = upload.FileHandle.init(3);
const file = upload.FileHandle.init(4);

const TestSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct { bytes: u64 = 0 };
    pub const WriteState = struct { calls: u8 = 0 };
    pub const Summary = struct { bytes: u64 };
    pub const BeginInput = u32;
    pub const StartupState = struct {
        action: Action = .normal,
        calls: u8 = 0,
        worker_index: u16 = 0,
    };
    pub const io_requirements = upload.IoRequirements{ .open = true, .write = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 1;
    pub const Error = error{ Rejected, InvalidRequest };
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = .{};
    pub const initial_startup_state: StartupState = .{};
    pub const Action = enum {
        normal,
        reject,
        invalid_request,
        undeclared_request,
        sink_invalid_request,
    };
    pub const Runtime = struct {
        action: Action = .normal,
        begin_calls: u8 = 0,
        write_calls: u8 = 0,
        delivered_write: u32 = 0,
        stop_async: bool = false,
        abandoned: bool = false,
    };

    pub fn runtimeStart(
        state: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        state.calls += 1;
        return switch (event) {
            .start => |input| startRuntime(state, input),
            .completion => switch (state.action) {
                .normal => .{ .done = .{} },
                .reject => error.Rejected,
                .invalid_request => .{ .request = invalidWrite() },
                .undeclared_request => .{ .request = undeclaredRequest() },
                .sink_invalid_request => error.InvalidRequest,
            },
        };
    }

    pub fn runtimeStop(
        runtime: *Runtime,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => if (runtime.stop_async) .{ .request = .{ .open = .{
                .base = .{ .handle = directory },
                .path = "stop",
                .access = .read_write,
            } } } else switch (runtime.action) {
                .normal => .{ .done = {} },
                .reject => error.Rejected,
                .invalid_request => .{ .request = invalidWrite() },
                .undeclared_request => .{ .request = undeclaredRequest() },
                .sink_invalid_request => error.InvalidRequest,
            },
            .completion => error.Rejected,
        };
    }

    pub fn abandonRuntimeStart(state: *StartupState) void {
        state.calls = 255;
    }

    pub fn abandonRuntimeStop(runtime: *Runtime) void {
        runtime.abandoned = true;
    }

    pub fn begin(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        runtime.begin_calls += 1;
        return switch (event) {
            .start => |input| startBegin(state, input),
            .completion => completeBegin(runtime),
        };
    }

    pub fn write(
        runtime: *Runtime,
        _: *State,
        write_state: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        runtime.write_calls += 1;
        write_state.calls += 1;
        return switch (event) {
            .start => |input| .{ .request = .{ .write = .{
                .file = file,
                .bytes = input.bytes,
                .offset = input.offset,
            } } },
            .completion => |completion| completeWrite(runtime, completion),
        };
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => |input| .{ .done = .{ .bytes = input.bytes } },
            .completion => error.Rejected,
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return lifecycleDone(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return lifecycleDone(event);
    }

    fn startBegin(state: *State, input: BeginInput) upload.Poll(void) {
        state.bytes = input;
        return .{ .request = .{ .open = .{
            .base = .{ .handle = directory },
            .path = "stage",
            .access = .read_write,
        } } };
    }

    fn startRuntime(
        state: *StartupState,
        input: upload.RuntimeStartInput,
    ) upload.Poll(Runtime) {
        state.worker_index = input.worker_index;
        state.action = switch (input.worker_index) {
            1 => .reject,
            2 => .invalid_request,
            3 => .sink_invalid_request,
            4 => .undeclared_request,
            else => .normal,
        };
        return .{ .request = .{ .open = .{
            .base = .{ .handle = directory },
            .path = "runtime",
            .access = .read_write,
        } } };
    }

    fn completeBegin(runtime: *Runtime) Error!upload.Poll(void) {
        return switch (runtime.action) {
            .normal => .{ .done = {} },
            .reject => error.Rejected,
            .invalid_request => .{ .request = .{ .write = .{
                .file = file,
                .bytes = "",
                .offset = 0,
            } } },
            .undeclared_request => .{ .request = undeclaredRequest() },
            .sink_invalid_request => error.InvalidRequest,
        };
    }

    fn completeWrite(
        runtime: *Runtime,
        completion: upload.IoCompletion,
    ) Error!upload.Poll(void) {
        return switch (runtime.action) {
            .normal => done: {
                runtime.delivered_write = completion.success.write;
                break :done .{ .done = {} };
            },
            .reject => error.Rejected,
            .invalid_request => .{ .request = invalidWrite() },
            .undeclared_request => .{ .request = undeclaredRequest() },
            .sink_invalid_request => error.InvalidRequest,
        };
    }

    fn invalidWrite() upload.IoRequest {
        return .{ .write = .{ .file = file, .bytes = "", .offset = 0 } };
    }

    fn undeclaredRequest() upload.IoRequest {
        return .{ .sync = .{ .file = file } };
    }

    fn lifecycleDone(event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }
};

const RequestOnlySink = struct {
    pub const ploof_multipart_request_sink = true;
    pub const State = TestSink.State;
    pub const WriteState = TestSink.WriteState;
    pub const Summary = TestSink.Summary;
    pub const BeginInput = TestSink.BeginInput;
    pub const Runtime = TestSink.Runtime;
    pub const Error = TestSink.Error;
    pub const io_requirements = TestSink.io_requirements;
    pub const initial_write_state = TestSink.initial_write_state;
    pub const begin = TestSink.begin;
    pub const write = TestSink.write;
    pub const finish = TestSink.finish;
    pub const commit = TestSink.commit;
    pub const abort = TestSink.abort;
};

test "request-only generated adapters need no worker lifecycle contract" {
    try std.testing.expect(upload.requestSinkIssue(RequestOnlySink) == null);
    try std.testing.expectEqual(
        upload.SinkIssue.missing_marker,
        upload.sinkIssue(RequestOnlySink).?,
    );
    try std.testing.expect(@sizeOf(driver.Lifecycle(RequestOnlySink)) > 0);
    try std.testing.expect(@sizeOf(driver.Write(RequestOnlySink)) > 0);
}

test "lifecycle driver reuses one poller across typed phases" {
    const Lifecycle = driver.Lifecycle(TestSink);
    var lifecycle = Lifecycle{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;

    _ = try lifecycle.startBegin(&runtime, &state, 7);
    try std.testing.expectError(
        error.Busy,
        lifecycle.startFinish(&runtime, &state, .{ .bytes = 7 }),
    );
    try std.testing.expectEqual(driver.FailureSource.control, lifecycle.lastFailureSource());
    try std.testing.expectError(
        error.Busy,
        lifecycle.startCommit(&runtime, &state),
    );
    _ = try lifecycle.resumeBegin(&runtime, &state, openSuccess());

    const finished = try lifecycle.startFinish(&runtime, &state, .{ .bytes = 7 });
    try std.testing.expectEqual(@as(u64, 7), finished.done.bytes);
    _ = try lifecycle.startCommit(&runtime, &state);
    _ = try lifecycle.startAbort(&runtime, &state);
    try std.testing.expectEqual(@as(u8, 2), runtime.begin_calls);
    try std.testing.expectError(
        error.NoActive,
        lifecycle.resumeAbort(&runtime, &state, .{ .failure = .canceled }),
    );
    try std.testing.expect(lifecycle.poller.isPoisoned());
}

test "lifecycle driver poisons malformed completion dispatch" {
    const Lifecycle = driver.Lifecycle(TestSink);
    inline for (.{ false, true }) |wrong_phase| {
        var lifecycle = Lifecycle{};
        var runtime = TestSink.Runtime{};
        var state = TestSink.initial_state;
        _ = try lifecycle.startBegin(&runtime, &state, 1);
        if (wrong_phase) {
            try std.testing.expectError(
                error.PhaseMismatch,
                lifecycle.resumeFinish(&runtime, &state, openSuccess()),
            );
        } else {
            try std.testing.expectError(
                error.CompletionKindMismatch,
                lifecycle.resumeBegin(&runtime, &state, .{ .success = .{ .write = 1 } }),
            );
        }
        try std.testing.expect(lifecycle.poller.isPoisoned());
        try std.testing.expectEqual(
            driver.FailureSource.completion,
            lifecycle.lastFailureSource(),
        );
        try std.testing.expect(lifecycle.poller.pendingRequest() == null);
        try std.testing.expectError(error.Poisoned, lifecycle.startCommit(&runtime, &state));
        try std.testing.expectError(
            error.Poisoned,
            lifecycle.resumeBegin(&runtime, &state, openSuccess()),
        );
    }
}

test "lifecycle driver latches failures and permits abort" {
    const Lifecycle = driver.Lifecycle(TestSink);
    inline for (.{
        TestSink.Action.reject,
        TestSink.Action.invalid_request,
        TestSink.Action.sink_invalid_request,
    }) |action| {
        var lifecycle = Lifecycle{};
        var runtime = TestSink.Runtime{ .action = action };
        var state = TestSink.initial_state;
        _ = try lifecycle.startBegin(&runtime, &state, 1);
        const expected = if (action == .reject) error.Rejected else error.InvalidRequest;
        try std.testing.expectError(
            expected,
            lifecycle.resumeBegin(&runtime, &state, openSuccess()),
        );
        try std.testing.expectEqual(
            if (action == .reject or action == .sink_invalid_request)
                driver.FailureSource.sink
            else
                driver.FailureSource.invalid_request,
            lifecycle.lastFailureSource(),
        );
        const latched = lifecycle.latchedFailureSource();
        try std.testing.expectError(
            error.Failed,
            lifecycle.startFinish(&runtime, &state, .{ .bytes = 1 }),
        );
        _ = try lifecycle.startAbort(&runtime, &state);
        try std.testing.expectEqual(latched, lifecycle.latchedFailureSource());
    }
}

test "write driver retries without sink reentry" {
    const Write = driver.Write(TestSink);
    var write = Write{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try write.start(&runtime, &state, .{ .bytes = "abcd", .offset = 9 });
    try std.testing.expectError(
        error.Busy,
        write.start(&runtime, &state, .{ .bytes = "x", .offset = 0 }),
    );

    const retry = try write.resumeWrite(&runtime, &state, .{ .success = .{ .write = 2 } });
    try std.testing.expectEqualStrings("cd", retry.request.write.bytes);
    try std.testing.expectEqual(@as(u64, 11), retry.request.write.offset);
    try std.testing.expectEqual(@as(u8, 1), runtime.write_calls);
    const done = try write.resumeWrite(&runtime, &state, .{ .success = .{ .write = 2 } });
    _ = done.done;
    try std.testing.expectEqual(@as(u32, 4), runtime.delivered_write);
    try std.testing.expectEqual(@as(u8, 2), write.write_state.calls);

    _ = try write.start(&runtime, &state, .{ .bytes = "x", .offset = 0 });
    try std.testing.expectEqual(@as(u8, 1), write.write_state.calls);
    _ = try write.resumeWrite(&runtime, &state, .{ .success = .{ .write = 1 } });
    try std.testing.expectError(
        error.NoActive,
        write.resumeWrite(&runtime, &state, .{ .success = .{ .write = 1 } }),
    );
    try std.testing.expect(write.poller.isPoisoned());
}

test "write driver latches sink errors and invalid requests" {
    const Write = driver.Write(TestSink);
    inline for (.{
        TestSink.Action.reject,
        TestSink.Action.invalid_request,
        TestSink.Action.sink_invalid_request,
    }) |action| {
        var write = Write{};
        var runtime = TestSink.Runtime{ .action = action };
        var state = TestSink.initial_state;
        _ = try write.start(&runtime, &state, .{ .bytes = "x", .offset = 0 });
        const expected = if (action == .reject) error.Rejected else error.InvalidRequest;
        try std.testing.expectError(
            expected,
            write.resumeWrite(&runtime, &state, .{ .success = .{ .write = 1 } }),
        );
        try std.testing.expectEqual(
            if (action == .reject or action == .sink_invalid_request)
                driver.FailureSource.sink
            else
                driver.FailureSource.invalid_request,
            write.lastFailureSource(),
        );
        try std.testing.expectError(
            error.Failed,
            write.start(&runtime, &state, .{ .bytes = "y", .offset = 0 }),
        );
    }
}

test "runtime driver constructs and stops one runtime" {
    const Runtime = driver.Runtime(TestSink);
    var runtime = Runtime{};
    _ = try runtime.startRuntime(runtimeInput(0));
    try std.testing.expectError(error.Busy, runtime.startRuntime(runtimeInput(0)));
    _ = try runtime.resumeStart(openSuccess());
    try std.testing.expect(runtime.runtimePointer() != null);
    try std.testing.expectEqual(@as(u8, 2), runtime.startup_state.calls);
    try std.testing.expectError(error.AlreadyConstructed, runtime.startRuntime(runtimeInput(0)));
    _ = try runtime.startStop();
    try std.testing.expect(runtime.runtimePointer() == null);
    try std.testing.expectError(error.NotConstructed, runtime.startStop());
}

test "custom runtime driver retains no first-party startup diagnostic storage" {
    const Runtime = driver.Runtime(TestSink);
    try std.testing.expect(!@hasField(Runtime, "startup_failure"));
    const runtime = Runtime{};
    try std.testing.expect(runtime.startupFailure() == null);
}

test "runtime driver latches startup failures" {
    const Runtime = driver.Runtime(TestSink);
    inline for (.{ @as(u16, 1), @as(u16, 2), @as(u16, 3) }) |worker_index| {
        var runtime = Runtime{};
        _ = try runtime.startRuntime(runtimeInput(worker_index));
        const expected = if (worker_index == 1) error.Rejected else error.InvalidRequest;
        try std.testing.expectError(expected, runtime.resumeStart(openSuccess()));
        try std.testing.expectEqual(
            if (worker_index == 1 or worker_index == 3)
                driver.FailureSource.sink
            else
                driver.FailureSource.invalid_request,
            runtime.lastFailureSource(),
        );
        try std.testing.expectError(error.Failed, runtime.startRuntime(runtimeInput(0)));
        try std.testing.expectError(error.Failed, runtime.startStop());
    }
}

test "runtime driver abandons one unsubmitted startup request" {
    const Runtime = driver.Runtime(TestSink);
    var runtime = Runtime{};
    try std.testing.expect(!runtime.abandonStartRequest());
    _ = try runtime.startRuntime(runtimeInput(0));
    try std.testing.expect(runtime.abandonStartRequest());
    try std.testing.expectEqual(@as(u8, 255), runtime.startup_state.calls);
    try std.testing.expect(!runtime.abandonStartRequest());
    try std.testing.expectEqual(driver.FailureSource.sink, runtime.lastFailureSource());
    try std.testing.expect(runtime.runtimePointer() == null);
    try std.testing.expectError(error.Failed, runtime.startRuntime(runtimeInput(0)));
    try std.testing.expectError(error.Failed, runtime.startStop());
}

test "runtime driver invokes an optional stop abandonment hook" {
    const Runtime = driver.Runtime(TestSink);
    var runtime = Runtime{};
    _ = try runtime.startRuntime(runtimeInput(0));
    _ = try runtime.resumeStart(openSuccess());
    runtime.runtimePointer().?.stop_async = true;
    _ = try runtime.startStop();
    try std.testing.expect(runtime.abandonStopRequest());
    try std.testing.expect(runtime.runtimePointer().?.abandoned);
}

test "FileSink abandonment hooks securely clear generator keys" {
    const supplied = file_sink_config.FileSinkConfig{
        .root = "uploads",
        .durability = .buffered,
    };
    const Sink = file_sink.FileSink(supplied);
    const Config = file_sink_config.Resolved(supplied);
    const Runtime = driver.Runtime(Sink);
    const entropy = [_]u8{0x6b} ** 32;

    var starting = Runtime{};
    _ = try starting.startRuntime(.{ .worker_index = 2, .entropy = &entropy });
    try std.testing.expect(starting.startup_state.generator_live);
    try std.testing.expect(starting.abandonStartRequest());
    try std.testing.expect(!starting.startup_state.generator_live);
    try std.testing.expectEqual(
        [_]u8{0} ** std.crypto.hash.Blake3.key_length,
        starting.startup_state.generator.key,
    );

    var stopping = Runtime{};
    stopping.value = .{
        .root = directory,
        .generator = Config.NameGenerator.init(&entropy, 2),
    };
    _ = try stopping.startStop();
    try std.testing.expect(stopping.abandonStopRequest());
    try std.testing.expectEqual(
        [_]u8{0} ** std.crypto.hash.Blake3.key_length,
        stopping.runtimePointer().?.generator.key,
    );
}

test "all sink drivers reject structurally valid undeclared I/O requests" {
    var sink_runtime = TestSink.Runtime{ .action = .undeclared_request };
    var state = TestSink.initial_state;

    var lifecycle = driver.Lifecycle(TestSink){};
    _ = try lifecycle.startBegin(&sink_runtime, &state, 1);
    try std.testing.expectError(
        error.InvalidRequest,
        lifecycle.resumeBegin(&sink_runtime, &state, openSuccess()),
    );
    try std.testing.expectEqual(
        driver.FailureSource.invalid_request,
        lifecycle.latchedFailureSource(),
    );

    var write = driver.Write(TestSink){};
    _ = try write.start(&sink_runtime, &state, .{ .bytes = "x", .offset = 0 });
    try std.testing.expectError(
        error.InvalidRequest,
        write.resumeWrite(&sink_runtime, &state, .{ .success = .{ .write = 1 } }),
    );
    try std.testing.expectEqual(driver.FailureSource.invalid_request, write.lastFailureSource());

    var runtime = driver.Runtime(TestSink){};
    _ = try runtime.startRuntime(runtimeInput(4));
    try std.testing.expectError(error.InvalidRequest, runtime.resumeStart(openSuccess()));
    try std.testing.expectEqual(driver.FailureSource.invalid_request, runtime.lastFailureSource());
}

test "runtime driver latches stop failure without retry" {
    const Runtime = driver.Runtime(TestSink);
    var runtime = Runtime{};
    _ = try runtime.startRuntime(runtimeInput(0));
    _ = try runtime.resumeStart(openSuccess());
    runtime.runtimePointer().?.action = .reject;
    try std.testing.expectError(error.Rejected, runtime.startStop());
    try std.testing.expect(runtime.runtimePointer() != null);
    try std.testing.expectError(error.Failed, runtime.startRuntime(runtimeInput(0)));
    runtime.runtimePointer().?.action = .normal;
    try std.testing.expectError(error.Failed, runtime.startStop());
    try std.testing.expect(runtime.runtimePointer() != null);
}

fn openSuccess() upload.IoCompletion {
    return .{ .success = .{ .open = file } };
}

fn runtimeInput(worker_index: u16) upload.RuntimeStartInput {
    return .{ .worker_index = worker_index, .entropy = &([_]u8{0xa5} ** 32) };
}

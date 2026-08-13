const std = @import("std");
const multipart = @import("../../src/multipart.zig");

const TestSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct { total: u64 = 0 };
    pub const WriteState = struct { calls: u8 = 0 };
    pub const Summary = struct { bytes: u64 };
    pub const BeginInput = u32;
    pub const Runtime = struct { begins: u8 = 0 };
    pub const StartupState = struct { worker: u16 = 0 };
    pub const io_requirements = multipart.IoRequirements.none;
    pub const request_handles_max: u8 = 2;
    pub const runtime_handles_max: u8 = 1;
    pub const Error = error{Rejected};
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = .{};
    pub const initial_startup_state: StartupState = .{};

    pub fn runtimeStart(
        state: *StartupState,
        event: multipart.PollEvent(multipart.RuntimeStartInput),
    ) Error!multipart.Poll(Runtime) {
        const input = switch (event) {
            .start => |value| value,
            .completion => return error.Rejected,
        };
        state.worker = input.worker_index;
        return .{ .done = .{} };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        if (event != .start) return error.Rejected;
        return .{ .done = {} };
    }

    pub fn begin(
        runtime: *Runtime,
        state: *State,
        event: multipart.PollEvent(BeginInput),
    ) Error!multipart.Poll(void) {
        const input = switch (event) {
            .start => |value| value,
            .completion => return error.Rejected,
        };
        state.total = input;
        runtime.begins += 1;
        return .{ .done = {} };
    }

    pub fn write(
        _: *Runtime,
        state: *State,
        write_state: *WriteState,
        event: multipart.PollEvent(multipart.WriteInput),
    ) Error!multipart.Poll(void) {
        const input = switch (event) {
            .start => |value| value,
            .completion => return error.Rejected,
        };
        state.total += input.bytes.len;
        write_state.calls += 1;
        return .{ .done = {} };
    }

    pub fn finish(
        _: *Runtime,
        state: *State,
        event: multipart.PollEvent(multipart.FinishInput),
    ) Error!multipart.Poll(Summary) {
        const input = switch (event) {
            .start => |value| value,
            .completion => return error.Rejected,
        };
        if (input.bytes + 7 != state.total) return error.Rejected;
        return .{ .done = .{ .bytes = input.bytes } };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        if (event != .start) return error.Rejected;
        return .{ .done = {} };
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        if (event != .start) return error.Rejected;
        return .{ .done = {} };
    }
};

const MissingState = struct {
    pub const ploof_multipart_sink = true;
};

const MissingWriteState = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
};

const MissingSummary = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
};

const MissingBeginInput = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
};

const MissingError = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
};

const OpenError = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = anyerror;
};

const MissingRuntime = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = error{};
};

const MissingStartupState = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = error{};
    pub const Runtime = void;
};

const MissingIoRequirements = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = error{};
    pub const Runtime = void;
    pub const StartupState = void;
};

const InvalidIoRequirements = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = error{};
    pub const Runtime = void;
    pub const StartupState = void;
    pub const io_requirements: u8 = 0;
};

const InvalidIoRequirementBits = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Error = error{};
    pub const Runtime = void;
    pub const StartupState = void;
    pub const io_requirements: multipart.IoRequirements = @bitCast(@as(u8, 0x80));
};

const HandleDefect = enum {
    request_type,
    request_above_maximum,
    runtime_type,
    runtime_above_maximum,
};

fn HandleDefectSink(comptime defect: HandleDefect) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = void;
        pub const WriteState = void;
        pub const Summary = void;
        pub const BeginInput = void;
        pub const Error = error{};
        pub const Runtime = void;
        pub const StartupState = void;
        pub const io_requirements = multipart.IoRequirements.none;
        pub const request_handles_max = switch (defect) {
            .request_type => @as(u16, 1),
            .request_above_maximum => @as(u8, 17),
            else => @as(u8, 0),
        };
        pub const runtime_handles_max = switch (defect) {
            .runtime_type => @as(u16, 1),
            .runtime_above_maximum => @as(u8, 17),
            else => @as(u8, 0),
        };
    };
}

fn InitialDefectSink(comptime issue: multipart.SinkIssue) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = struct {};
        pub const WriteState = struct {};
        pub const Summary = void;
        pub const BeginInput = void;
        pub const Error = error{};
        pub const Runtime = void;
        pub const StartupState = struct {};
        pub const io_requirements = multipart.IoRequirements.none;
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state = if (issue == .missing_initial_state)
            @as(u8, 0)
        else
            State{};
        pub const initial_write_state = if (issue == .missing_initial_write_state)
            @as(u8, 0)
        else
            WriteState{};
        pub const initial_startup_state = if (issue == .missing_initial_startup_state)
            @as(u8, 0)
        else
            StartupState{};
    };
}

const MethodState = struct {};
const MethodWriteState = struct {};
const MethodRuntime = struct {};
const MethodStartupState = struct {};
const MethodError = error{Rejected};

fn validRuntimeStart(
    _: *MethodStartupState,
    _: multipart.PollEvent(multipart.RuntimeStartInput),
) MethodError!multipart.Poll(MethodRuntime) {
    return .{ .done = .{} };
}

fn validRuntimeStop(
    _: *MethodRuntime,
    _: multipart.PollEvent(void),
) MethodError!multipart.Poll(void) {
    return .{ .done = {} };
}

fn validBegin(
    _: *MethodRuntime,
    _: *MethodState,
    _: multipart.PollEvent(void),
) MethodError!multipart.Poll(void) {
    return .{ .done = {} };
}

fn validWrite(
    _: *MethodRuntime,
    _: *MethodState,
    _: *MethodWriteState,
    _: multipart.PollEvent(multipart.WriteInput),
) MethodError!multipart.Poll(void) {
    return .{ .done = {} };
}

fn validFinish(
    _: *MethodRuntime,
    _: *MethodState,
    _: multipart.PollEvent(multipart.FinishInput),
) MethodError!multipart.Poll(void) {
    return .{ .done = {} };
}

fn validCommit(
    _: *MethodRuntime,
    _: *MethodState,
    _: multipart.PollEvent(void),
) MethodError!multipart.Poll(void) {
    return .{ .done = {} };
}

fn invalidMethod() void {}

fn MethodDefectSink(comptime issue: multipart.SinkIssue) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = MethodState;
        pub const WriteState = MethodWriteState;
        pub const Summary = void;
        pub const BeginInput = void;
        pub const Error = MethodError;
        pub const Runtime = MethodRuntime;
        pub const StartupState = MethodStartupState;
        pub const io_requirements = multipart.IoRequirements.none;
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = .{};
        pub const initial_startup_state: StartupState = .{};
        pub const runtimeStart = if (issue == .invalid_runtime_start)
            invalidMethod
        else
            validRuntimeStart;
        pub const runtimeStop = if (issue == .invalid_runtime_stop)
            invalidMethod
        else
            validRuntimeStop;
        pub const begin = if (issue == .invalid_begin) invalidMethod else validBegin;
        pub const write = if (issue == .invalid_write) invalidMethod else validWrite;
        pub const finish = if (issue == .invalid_finish) invalidMethod else validFinish;
        pub const commit = if (issue == .invalid_commit) invalidMethod else validCommit;
        pub const abort = if (issue == .invalid_abort) invalidMethod else validCommit;
    };
}

fn expectSinkIssue(expected: multipart.SinkIssue, comptime Sink: type) !void {
    try std.testing.expectEqual(expected, multipart.sinkIssue(Sink).?);
    try std.testing.expect(std.mem.startsWith(u8, expected.diagnostic(), "PLOOF-E"));
}

test "concrete multipart sink contract has exact fixed-state signatures" {
    try std.testing.expect(multipart.sinkIssue(TestSink) == null);
    try std.testing.expect(multipart.sinkIssue(multipart.DiscardSink) == null);

    var state = TestSink.initial_state;
    var write_state = TestSink.initial_write_state;
    var runtime = TestSink.Runtime{};
    var startup = TestSink.initial_startup_state;
    runtime = (try TestSink.runtimeStart(&startup, .{ .start = .{
        .worker_index = 9,
        .entropy = &([_]u8{0xa5} ** 32),
    } })).done;
    _ = try TestSink.begin(&runtime, &state, .{ .start = 7 });
    _ = try TestSink.write(
        &runtime,
        &state,
        &write_state,
        .{ .start = .{ .bytes = "abc", .offset = 0 } },
    );
    const finished = try TestSink.finish(
        &runtime,
        &state,
        .{ .start = .{ .bytes = 3 } },
    );
    try std.testing.expectEqual(@as(u64, 3), finished.done.bytes);
    try std.testing.expectEqual(@as(u8, 1), write_state.calls);
    try std.testing.expectEqual(@as(u8, 1), runtime.begins);
    try std.testing.expectEqual(@as(u16, 9), startup.worker);
}

test "sink diagnostics cover marker and type declarations" {
    const MissingMarker = struct {};
    const MarkerWrongType = struct {
        pub const ploof_multipart_sink = 1;
    };
    const MarkerFalse = struct {
        pub const ploof_multipart_sink = false;
    };

    try expectSinkIssue(.not_struct, u8);
    try expectSinkIssue(.missing_marker, MissingMarker);
    try expectSinkIssue(.missing_marker, MarkerWrongType);
    try expectSinkIssue(.missing_marker, MarkerFalse);
    try expectSinkIssue(.missing_state, MissingState);
    try expectSinkIssue(.missing_write_state, MissingWriteState);
    try expectSinkIssue(.missing_summary, MissingSummary);
    try expectSinkIssue(.missing_begin_input, MissingBeginInput);
    try expectSinkIssue(.missing_error, MissingError);
    try expectSinkIssue(.open_error_set, OpenError);
    try expectSinkIssue(.missing_runtime, MissingRuntime);
    try expectSinkIssue(.missing_startup_state, MissingStartupState);
    try expectSinkIssue(.missing_io_requirements, MissingIoRequirements);
    try expectSinkIssue(.invalid_io_requirements, InvalidIoRequirements);
    try expectSinkIssue(.invalid_io_requirements, InvalidIoRequirementBits);
}

test "sink diagnostics cover handle maximum type and hard ceiling" {
    try expectSinkIssue(
        .invalid_request_handles_max,
        HandleDefectSink(.request_type),
    );
    try expectSinkIssue(
        .invalid_request_handles_max,
        HandleDefectSink(.request_above_maximum),
    );
    try expectSinkIssue(
        .invalid_runtime_handles_max,
        HandleDefectSink(.runtime_type),
    );
    try expectSinkIssue(
        .invalid_runtime_handles_max,
        HandleDefectSink(.runtime_above_maximum),
    );
}

test "sink diagnostics cover initial value types" {
    try expectSinkIssue(
        .missing_initial_state,
        InitialDefectSink(.missing_initial_state),
    );
    try expectSinkIssue(
        .missing_initial_write_state,
        InitialDefectSink(.missing_initial_write_state),
    );
    try expectSinkIssue(
        .missing_initial_startup_state,
        InitialDefectSink(.missing_initial_startup_state),
    );
}

test "sink diagnostics cover every poll method signature" {
    const issues = [_]multipart.SinkIssue{
        .invalid_runtime_start,
        .invalid_runtime_stop,
        .invalid_begin,
        .invalid_write,
        .invalid_finish,
        .invalid_commit,
        .invalid_abort,
    };
    inline for (issues) |issue| {
        try expectSinkIssue(issue, MethodDefectSink(issue));
    }
}

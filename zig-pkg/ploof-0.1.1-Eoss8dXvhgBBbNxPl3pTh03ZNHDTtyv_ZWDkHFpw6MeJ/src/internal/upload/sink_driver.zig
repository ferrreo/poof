const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const startup_diagnostic = @import("../multipart/file_sink_startup_diagnostic.zig");
const upload_poller = @import("poller.zig");

pub const ControlError = error{
    Busy,
    NoActive,
    PhaseMismatch,
    Failed,
    AlreadyConstructed,
    NotConstructed,
};

pub const FailureSource = enum(u8) {
    none,
    control,
    sink,
    invalid_request,
    completion,
};

pub fn Lifecycle(comptime Sink: type) type {
    upload.validateRequestSink(Sink);
    return struct {
        const Self = @This();
        const Phase = enum(u8) { begin, finish, commit, abort };

        pub const Error = Sink.Error || ControlError ||
            upload_poller.SubmitError || upload_poller.ResumeError;

        poller: upload_poller.Poller = .{},
        active: ?Phase = null,
        failed: bool = false,
        last_failure: FailureSource = .none,
        latched_failure: FailureSource = .none,

        pub fn startBegin(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: Sink.BeginInput,
        ) Error!upload.Poll(void) {
            return self.start(runtime, state, .begin, input);
        }

        pub fn resumeBegin(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            return self.resumePhase(runtime, state, .begin, completion);
        }

        pub fn startFinish(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: upload.FinishInput,
        ) Error!upload.Poll(Sink.Summary) {
            return self.start(runtime, state, .finish, input);
        }

        pub fn resumeFinish(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Sink.Summary) {
            return self.resumePhase(runtime, state, .finish, completion);
        }

        pub fn startCommit(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
        ) Error!upload.Poll(void) {
            return self.start(runtime, state, .commit, {});
        }

        pub fn resumeCommit(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            return self.resumePhase(runtime, state, .commit, completion);
        }

        pub fn startAbort(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
        ) Error!upload.Poll(void) {
            return self.start(runtime, state, .abort, {});
        }

        pub fn resumeAbort(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            return self.resumePhase(runtime, state, .abort, completion);
        }

        fn start(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            comptime phase: Phase,
            input: Input(phase),
        ) Error!upload.Poll(Output(phase)) {
            self.last_failure = .none;
            if (self.poller.isPoisoned()) return self.failControl(
                error.Poisoned,
                .completion,
            );
            if (self.active != null) return self.failControl(error.Busy, .control);
            if (self.failed and phase != .abort) {
                return self.failControl(error.Failed, .control);
            }
            std.debug.assert(self.poller.pendingRequest() == null);
            const result = call(runtime, state, phase, .{ .start = input }) catch |problem| {
                self.latchFailure(lifecycleSinkFailureSource(Sink, runtime, state));
                return problem;
            };
            return self.accept(phase, result);
        }

        fn resumePhase(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            comptime phase: Phase,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Output(phase)) {
            self.last_failure = .none;
            if (self.poller.isPoisoned()) return self.failControl(
                error.Poisoned,
                .completion,
            );
            const active = self.active orelse {
                self.poisonLifecycle();
                return error.NoActive;
            };
            if (active != phase) {
                self.poisonLifecycle();
                return error.PhaseMismatch;
            }
            const step = self.poller.complete(completion) catch |problem| {
                self.poisonLifecycle();
                return problem;
            };
            switch (step) {
                .retry => |request| return .{ .request = request },
                .deliver => |deliver| {
                    std.debug.assert(self.poller.pendingRequest() == null);
                    const result = call(
                        runtime,
                        state,
                        phase,
                        .{ .completion = deliver },
                    ) catch |problem| {
                        self.latchFailure(lifecycleSinkFailureSource(Sink, runtime, state));
                        return problem;
                    };
                    return self.accept(phase, result);
                },
            }
        }

        fn accept(
            self: *Self,
            comptime phase: Phase,
            result: upload.Poll(Output(phase)),
        ) Error!upload.Poll(Output(phase)) {
            switch (result) {
                .request => |request| submitRequest(Sink, &self.poller, request) catch |problem| {
                    if (problem == error.InvalidRequest) {
                        self.latchFailure(.invalid_request);
                    } else {
                        self.last_failure = if (problem == error.Poisoned)
                            .completion
                        else
                            .control;
                    }
                    return problem;
                },
                .done => {
                    self.active = null;
                    return result;
                },
            }
            self.active = phase;
            return result;
        }

        pub fn quiescent(self: *const Self) bool {
            return self.active == null and self.poller.pendingRequest() == null;
        }

        pub fn ownershipProven(self: *const Self) bool {
            return self.poller.ownershipProven();
        }

        pub fn cancelActive(self: *Self) bool {
            if (self.active == null or !self.poller.abandonPending()) return false;
            self.active = null;
            self.last_failure = .none;
            return true;
        }

        pub fn lastFailureSource(self: *const Self) FailureSource {
            return self.last_failure;
        }

        pub fn latchedFailureSource(self: *const Self) FailureSource {
            return self.latched_failure;
        }

        fn failControl(
            self: *Self,
            problem: Error,
            source: FailureSource,
        ) Error {
            self.last_failure = source;
            return problem;
        }

        fn latchFailure(self: *Self, source: FailureSource) void {
            std.debug.assert(self.poller.pendingRequest() == null);
            self.active = null;
            self.failed = true;
            self.last_failure = source;
            self.latched_failure = source;
        }

        fn poisonLifecycle(self: *Self) void {
            self.poller.invalidateOwnership();
            self.active = null;
            self.failed = true;
            self.last_failure = .completion;
            self.latched_failure = .completion;
        }

        fn call(
            runtime: *Sink.Runtime,
            state: *Sink.State,
            comptime phase: Phase,
            event: upload.PollEvent(Input(phase)),
        ) Sink.Error!upload.Poll(Output(phase)) {
            return switch (phase) {
                .begin => Sink.begin(runtime, state, event),
                .finish => Sink.finish(runtime, state, event),
                .commit => Sink.commit(runtime, state, event),
                .abort => Sink.abort(runtime, state, event),
            };
        }

        fn Input(comptime phase: Phase) type {
            return switch (phase) {
                .begin => Sink.BeginInput,
                .finish => upload.FinishInput,
                .commit, .abort => void,
            };
        }

        fn Output(comptime phase: Phase) type {
            return switch (phase) {
                .finish => Sink.Summary,
                .begin, .commit, .abort => void,
            };
        }
    };
}

pub fn Write(comptime Sink: type) type {
    upload.validateRequestSink(Sink);
    return struct {
        const Self = @This();
        pub const Error = Sink.Error || ControlError ||
            upload_poller.SubmitError || upload_poller.ResumeError;

        write_state: Sink.WriteState = Sink.initial_write_state,
        poller: upload_poller.Poller = .{},
        active: bool = false,
        failed: bool = false,
        last_failure: FailureSource = .none,

        pub fn start(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: upload.WriteInput,
        ) Error!upload.Poll(void) {
            self.last_failure = .none;
            if (self.poller.isPoisoned()) return self.failControl(
                error.Poisoned,
                .completion,
            );
            if (self.active) return self.failControl(error.Busy, .control);
            if (self.failed) return self.failControl(error.Failed, .control);
            std.debug.assert(self.poller.pendingRequest() == null);
            self.write_state = Sink.initial_write_state;
            const result = Sink.write(
                runtime,
                state,
                &self.write_state,
                .{ .start = input },
            ) catch |problem| {
                self.latchFailure(writeSinkFailureSource(Sink, &self.write_state));
                return problem;
            };
            return self.accept(result);
        }

        pub fn resumeWrite(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            self.last_failure = .none;
            if (!self.active) {
                self.poller.invalidateOwnership();
                self.latchFailure(.completion);
                return error.NoActive;
            }
            const step = self.poller.complete(completion) catch |problem| {
                self.latchFailure(.completion);
                return problem;
            };
            switch (step) {
                .retry => |request| return .{ .request = request },
                .deliver => |deliver| {
                    std.debug.assert(self.poller.pendingRequest() == null);
                    const result = Sink.write(
                        runtime,
                        state,
                        &self.write_state,
                        .{ .completion = deliver },
                    ) catch |problem| {
                        self.latchFailure(writeSinkFailureSource(Sink, &self.write_state));
                        return problem;
                    };
                    return self.accept(result);
                },
            }
        }

        fn accept(self: *Self, result: upload.Poll(void)) Error!upload.Poll(void) {
            switch (result) {
                .request => |request| submitRequest(Sink, &self.poller, request) catch |problem| {
                    self.latchFailure(if (problem == error.InvalidRequest)
                        .invalid_request
                    else if (problem == error.Poisoned)
                        .completion
                    else
                        .control);
                    return problem;
                },
                .done => {
                    self.active = false;
                    return result;
                },
            }
            self.active = true;
            return result;
        }

        pub fn lastFailureSource(self: *const Self) FailureSource {
            return self.last_failure;
        }

        pub fn cancelActive(self: *Self) bool {
            if (!self.active or !self.poller.abandonPending()) return false;
            self.active = false;
            self.last_failure = .none;
            return true;
        }

        fn failControl(
            self: *Self,
            problem: Error,
            source: FailureSource,
        ) Error {
            self.last_failure = source;
            return problem;
        }

        fn latchFailure(self: *Self, source: FailureSource) void {
            std.debug.assert(self.poller.pendingRequest() == null);
            self.active = false;
            self.failed = true;
            self.last_failure = source;
        }
    };
}

fn lifecycleSinkFailureSource(
    comptime Sink: type,
    runtime: *const Sink.Runtime,
    state: *const Sink.State,
) FailureSource {
    if (comptime @hasDecl(Sink, "lifecycleStateFailureSource")) {
        return switch (Sink.lifecycleStateFailureSource(state)) {
            .sink => .sink,
            .invalid_request => .invalid_request,
        };
    }
    if (comptime @hasDecl(Sink, "ploof_multipart_request_sink") and
        @hasDecl(Sink, "lifecycleFailureSource"))
    {
        return switch (Sink.lifecycleFailureSource(runtime)) {
            .sink => .sink,
            .invalid_request => .invalid_request,
        };
    }
    return .sink;
}

fn writeSinkFailureSource(
    comptime Sink: type,
    write_state: *const Sink.WriteState,
) FailureSource {
    if (comptime @hasDecl(Sink, "ploof_multipart_request_sink") and
        @hasDecl(Sink, "writeFailureSource"))
    {
        return switch (Sink.writeFailureSource(write_state)) {
            .sink => .sink,
            .invalid_request => .invalid_request,
        };
    }
    return .sink;
}

pub fn Runtime(comptime Sink: type) type {
    upload.validateSink(Sink);
    return struct {
        const Self = @This();
        const Phase = enum(u1) { start, stop };
        pub const Error = Sink.Error || ControlError ||
            upload_poller.SubmitError || upload_poller.ResumeError;

        startup_state: Sink.StartupState = Sink.initial_startup_state,
        value: ?Sink.Runtime = null,
        poller: upload_poller.Poller = .{},
        active: ?Phase = null,
        failed: bool = false,
        last_failure: FailureSource = .none,

        pub fn startRuntime(
            self: *Self,
            input: upload.RuntimeStartInput,
        ) Error!upload.Poll(void) {
            self.last_failure = .none;
            if (self.poller.isPoisoned()) return self.failControl(
                error.Poisoned,
                .completion,
            );
            if (self.active != null) return self.failControl(error.Busy, .control);
            if (self.failed) return self.failControl(error.Failed, .control);
            if (self.value != null) return self.failControl(
                error.AlreadyConstructed,
                .control,
            );
            self.startup_state = Sink.initial_startup_state;
            const result = Sink.runtimeStart(
                &self.startup_state,
                .{ .start = input },
            ) catch |problem| {
                self.latchFailure(.sink);
                return problem;
            };
            return self.acceptStart(result);
        }

        pub fn resumeStart(
            self: *Self,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            const step = try self.complete(.start, completion);
            switch (step) {
                .retry => |request| return .{ .request = request },
                .deliver => |deliver| {
                    const result = Sink.runtimeStart(
                        &self.startup_state,
                        .{ .completion = deliver },
                    ) catch |problem| {
                        self.latchFailure(.sink);
                        return problem;
                    };
                    return self.acceptStart(result);
                },
            }
        }

        pub fn startStop(self: *Self) Error!upload.Poll(void) {
            self.last_failure = .none;
            if (self.poller.isPoisoned()) return self.failControl(
                error.Poisoned,
                .completion,
            );
            if (self.active != null) return self.failControl(error.Busy, .control);
            if (self.failed) return self.failControl(error.Failed, .control);
            const runtime = self.runtimePointer() orelse return self.failControl(
                error.NotConstructed,
                .control,
            );
            const result = Sink.runtimeStop(runtime, .{ .start = {} }) catch |problem| {
                self.latchFailure(.sink);
                return problem;
            };
            return self.acceptStop(result);
        }

        pub fn resumeStop(
            self: *Self,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            const step = try self.complete(.stop, completion);
            switch (step) {
                .retry => |request| return .{ .request = request },
                .deliver => |deliver| {
                    const runtime = self.runtimePointer() orelse {
                        self.poller.invalidateOwnership();
                        self.latchFailure(.completion);
                        return error.NotConstructed;
                    };
                    const result = Sink.runtimeStop(
                        runtime,
                        .{ .completion = deliver },
                    ) catch |problem| {
                        self.latchFailure(.sink);
                        return problem;
                    };
                    return self.acceptStop(result);
                },
            }
        }

        pub fn runtimePointer(self: *Self) ?*Sink.Runtime {
            return if (self.value) |*runtime| runtime else null;
        }

        pub fn startupFailure(self: *const Self) ?startup_diagnostic.Failure {
            return startup_diagnostic.capture(Sink, &self.startup_state);
        }

        pub fn abandonStartRequest(self: *Self) bool {
            if (self.active != .start or !self.poller.abandonPending()) return false;
            if (comptime @hasDecl(Sink, "abandonRuntimeStart")) {
                Sink.abandonRuntimeStart(&self.startup_state);
            }
            self.active = null;
            self.failed = true;
            self.last_failure = .sink;
            return true;
        }

        pub fn abandonStopRequest(self: *Self) bool {
            if (self.active != .stop or !self.poller.abandonPending()) return false;
            if (comptime @hasDecl(Sink, "abandonRuntimeStop")) {
                Sink.abandonRuntimeStop(&self.value.?);
            }
            self.active = null;
            self.failed = true;
            self.last_failure = .control;
            return true;
        }

        pub fn quiescent(self: *const Self) bool {
            return self.active == null and self.poller.pendingRequest() == null;
        }

        pub fn lastFailureSource(self: *const Self) FailureSource {
            return self.last_failure;
        }

        fn complete(
            self: *Self,
            expected: Phase,
            completion: upload.IoCompletion,
        ) Error!upload_poller.CompletionStep {
            self.last_failure = .none;
            const active = self.active orelse {
                self.poller.invalidateOwnership();
                self.latchFailure(.completion);
                return error.NoActive;
            };
            if (active != expected) {
                self.poller.invalidateOwnership();
                self.latchFailure(.completion);
                return error.PhaseMismatch;
            }
            return self.poller.complete(completion) catch |problem| {
                self.latchFailure(.completion);
                return problem;
            };
        }

        fn acceptStart(
            self: *Self,
            result: upload.Poll(Sink.Runtime),
        ) Error!upload.Poll(void) {
            return switch (result) {
                .request => |request| self.acceptRequest(.start, request),
                .done => |runtime| done: {
                    self.value = runtime;
                    self.active = null;
                    break :done .{ .done = {} };
                },
            };
        }

        fn acceptStop(self: *Self, result: upload.Poll(void)) Error!upload.Poll(void) {
            return switch (result) {
                .request => |request| self.acceptRequest(.stop, request),
                .done => done: {
                    self.value = null;
                    self.active = null;
                    break :done .{ .done = {} };
                },
            };
        }

        fn acceptRequest(
            self: *Self,
            phase: Phase,
            request: upload.IoRequest,
        ) Error!upload.Poll(void) {
            submitRequest(Sink, &self.poller, request) catch |problem| {
                self.latchFailure(if (problem == error.InvalidRequest)
                    .invalid_request
                else if (problem == error.Poisoned)
                    .completion
                else
                    .control);
                return problem;
            };
            self.active = phase;
            return .{ .request = request };
        }

        fn failControl(
            self: *Self,
            problem: Error,
            source: FailureSource,
        ) Error {
            self.last_failure = source;
            return problem;
        }

        fn latchFailure(self: *Self, source: FailureSource) void {
            std.debug.assert(self.poller.pendingRequest() == null);
            self.active = null;
            self.failed = true;
            self.last_failure = source;
        }
    };
}

fn submitRequest(
    comptime Sink: type,
    poller: *upload_poller.Poller,
    request: upload.IoRequest,
) upload_poller.SubmitError!void {
    if (!Sink.io_requirements.contains(std.meta.activeTag(request))) {
        return error.InvalidRequest;
    }
    try poller.submit(request);
}

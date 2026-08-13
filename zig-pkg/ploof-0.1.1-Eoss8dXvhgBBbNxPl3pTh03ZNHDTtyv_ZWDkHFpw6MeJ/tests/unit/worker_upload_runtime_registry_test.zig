const split = @import("worker_upload_runtime_registry_schedule_test_support.zig");
pub const std = @import("std");

pub const multipart = @import("../../src/multipart.zig");
pub const upload_sink_driver = @import("../../src/internal/upload/sink_driver.zig");
pub const reactor = @import("../../src/internal/runtime/reactor.zig");
pub const worker_upload = @import("../../src/internal/runtime/worker/upload_transport.zig");
pub const base = @import("worker_upload_transport_test.zig");

pub const TestApp = base.TestApp;
pub const TestStorage = base.TestStorage;
pub const TestReactor = base.TestReactor;

pub fn RuntimeSink(comptime marker: u8) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = void;
        pub const WriteState = void;
        pub const Summary = void;
        pub const BeginInput = void;
        pub const StartupState = struct { completion_count: u8 = 0 };
        pub const Runtime = struct { directory: multipart.FileHandle };
        pub const Error = error{Rejected};
        pub const io_requirements = multipart.IoRequirements{
            .open = true,
            .close = true,
        };
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 1;
        pub const initial_state: State = {};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = .{};

        pub fn runtimeStart(
            startup: *StartupState,
            event: multipart.PollEvent(multipart.RuntimeStartInput),
        ) Error!multipart.Poll(Runtime) {
            return switch (event) {
                .start => start: {
                    if (marker == 3) return error.Rejected;
                    break :start .{ .request = .{ .open = .{
                        .base = .working_directory,
                        .path = if (marker == 1) "." else "./.",
                        .access = .read_only,
                        .kind = .directory,
                    } } };
                },
                .completion => |completion| done: {
                    startup.completion_count += 1;
                    if (marker == 4) return error.Rejected;
                    break :done .{ .done = .{ .directory = switch (completion) {
                        .success => |success| switch (success) {
                            .open => |handle| handle,
                            else => return error.Rejected,
                        },
                        .failure => return error.Rejected,
                    } } };
                },
            };
        }

        pub fn runtimeStop(
            runtime: *Runtime,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return switch (event) {
                .start => if (marker == 5)
                    error.Rejected
                else if (marker == 6)
                    .{ .done = {} }
                else
                    .{ .request = .{ .close = .{ .file = runtime.directory } } },
                .completion => |completion| if (completion == .success and
                    completion.success == .close)
                    .{ .done = {} }
                else
                    error.Rejected,
            };
        }

        pub fn begin(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(BeginInput),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn write(
            _: *Runtime,
            _: *State,
            _: *WriteState,
            event: multipart.PollEvent(multipart.WriteInput),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn finish(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(multipart.FinishInput),
        ) Error!multipart.Poll(Summary) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => error.Rejected,
            };
        }

        pub fn commit(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn abort(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn done(event: anytype) Error!multipart.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => error.Rejected,
            };
        }
    };
}

pub const RuntimeSinkA = RuntimeSink(1);
pub const RuntimeSinkB = RuntimeSink(2);
pub const RuntimeSinkStartFailure = RuntimeSink(3);
pub const RuntimeSinkResumeFailure = RuntimeSink(4);
pub const RuntimeSinkStopFailure = RuntimeSink(5);
pub const RuntimeSinkStopDone = RuntimeSink(6);

pub const StartupStage = enum(u1) { first_open, second_open };

pub const TwoStageStartupSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const StartupState = struct {
        first: multipart.FileHandle = .{ .token = 0 },
        stage: StartupStage = .first_open,
    };
    pub const Runtime = struct {
        first: multipart.FileHandle,
        second: multipart.FileHandle,
    };
    pub const Error = error{Rejected};
    pub const io_requirements = multipart.IoRequirements{ .open = true, .close = true };
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 2;
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = .{};

    pub fn runtimeStart(
        state: *StartupState,
        event: multipart.PollEvent(multipart.RuntimeStartInput),
    ) Error!multipart.Poll(Runtime) {
        return switch (event) {
            .start => openRequest("first"),
            .completion => |completion| switch (state.stage) {
                .first_open => firstOpened(state, completion),
                .second_open => startupFailed(completion),
            },
        };
    }

    pub fn firstOpened(
        state: *StartupState,
        completion: multipart.IoCompletion,
    ) Error!multipart.Poll(Runtime) {
        state.first = completionHandle(completion) orelse return error.Rejected;
        state.stage = .second_open;
        return openRequest("second");
    }

    pub fn startupFailed(completion: multipart.IoCompletion) Error!multipart.Poll(Runtime) {
        if (completion != .failure or completion.failure != .canceled) {
            return error.Rejected;
        }
        return error.Rejected;
    }

    pub fn openRequest(path: [:0]const u8) multipart.Poll(Runtime) {
        return .{ .request = .{ .open = .{
            .base = .working_directory,
            .path = path,
            .access = .read_only,
            .kind = .directory,
        } } };
    }

    pub fn completionHandle(completion: multipart.IoCompletion) ?multipart.FileHandle {
        return switch (completion) {
            .success => |success| switch (success) {
                .open => |handle| handle,
                else => null,
            },
            .failure => null,
        };
    }

    pub fn runtimeStop(_: *Runtime, _: multipart.PollEvent(void)) Error!multipart.Poll(void) {
        return error.Rejected;
    }

    pub fn begin(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(BeginInput),
    ) Error!multipart.Poll(void) {
        return done(event);
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: multipart.PollEvent(multipart.WriteInput),
    ) Error!multipart.Poll(void) {
        return done(event);
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(multipart.FinishInput),
    ) Error!multipart.Poll(Summary) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        return done(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: multipart.PollEvent(void),
    ) Error!multipart.Poll(void) {
        return done(event);
    }

    pub fn done(event: anytype) Error!multipart.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }
};

pub const RuntimeRegistry = struct {
    a: upload_sink_driver.Runtime(RuntimeSinkA) = .{},
    b: upload_sink_driver.Runtime(RuntimeSinkB) = .{},
    start_failure: upload_sink_driver.Runtime(RuntimeSinkStartFailure) = .{},
    resume_failure: upload_sink_driver.Runtime(RuntimeSinkResumeFailure) = .{},
    stop_failure: upload_sink_driver.Runtime(RuntimeSinkStopFailure) = .{},
    stop_done: upload_sink_driver.Runtime(RuntimeSinkStopDone) = .{},
    two_stage: upload_sink_driver.Runtime(TwoStageStartupSink) = .{},

    pub fn driver(self: *@This(), comptime Sink: type) *upload_sink_driver.Runtime(Sink) {
        if (Sink == RuntimeSinkA) return &self.a;
        if (Sink == RuntimeSinkB) return &self.b;
        if (Sink == RuntimeSinkStartFailure) return &self.start_failure;
        if (Sink == RuntimeSinkResumeFailure) return &self.resume_failure;
        if (Sink == RuntimeSinkStopFailure) return &self.stop_failure;
        if (Sink == RuntimeSinkStopDone) return &self.stop_done;
        if (Sink == TwoStageStartupSink) return &self.two_stage;
        unreachable;
    }
};

pub const RuntimeApp = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max = TestApp.upload_request_handles_max;
    pub const upload_window_max = TestApp.upload_window_max;
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{ RuntimeSinkA, RuntimeSinkB };
    };
    pub const Workspace = TestApp.Workspace;
    pub const __peekUploadSubmission = TestApp.__peekUploadSubmission;
    pub const __markUploadSubmitted = TestApp.__markUploadSubmitted;
    pub const __completeUploadSubmission = TestApp.__completeUploadSubmission;
    pub const __resumeMultipart = TestApp.__resumeMultipart;
    pub const __multipartFinalizationFlow = TestApp.__multipartFinalizationFlow;
    pub const __multipartFinalizationOutcome = TestApp.__multipartFinalizationOutcome;
    pub const __multipartFinalizationReport = TestApp.__multipartFinalizationReport;
    pub const __startMultipartFinalization = TestApp.__startMultipartFinalization;
    pub const __cancelMultipart = TestApp.__cancelMultipart;
    pub const __multipartTerminalSource = TestApp.__multipartTerminalSource;
};

pub fn SingleRuntimeApp(comptime Sink: type) type {
    return struct {
        pub const upload_async_sink_present = true;
        pub const upload_request_handles_max = TestApp.upload_request_handles_max;
        pub const upload_window_max = TestApp.upload_window_max;
        pub const UploadCatalog = struct {
            pub const sink_types = [_]type{Sink};
        };
        pub const Workspace = TestApp.Workspace;
        pub const __peekUploadSubmission = TestApp.__peekUploadSubmission;
        pub const __markUploadSubmitted = TestApp.__markUploadSubmitted;
        pub const __completeUploadSubmission = TestApp.__completeUploadSubmission;
        pub const __resumeMultipart = TestApp.__resumeMultipart;
        pub const __multipartFinalizationFlow = TestApp.__multipartFinalizationFlow;
        pub const __multipartFinalizationOutcome = TestApp.__multipartFinalizationOutcome;
        pub const __multipartFinalizationReport = TestApp.__multipartFinalizationReport;
        pub const __startMultipartFinalization = TestApp.__startMultipartFinalization;
        pub const __cancelMultipart = TestApp.__cancelMultipart;
        pub const __multipartTerminalSource = TestApp.__multipartTerminalSource;
    };
}

pub fn RuntimeFailureApp(comptime FailureSink: type) type {
    return struct {
        pub const upload_async_sink_present = true;
        pub const upload_request_handles_max = TestApp.upload_request_handles_max;
        pub const upload_window_max = TestApp.upload_window_max;
        pub const UploadCatalog = struct {
            pub const sink_types = [_]type{ RuntimeSinkA, RuntimeSinkB, FailureSink };
        };
        pub const Workspace = TestApp.Workspace;
        pub const __peekUploadSubmission = TestApp.__peekUploadSubmission;
        pub const __markUploadSubmitted = TestApp.__markUploadSubmitted;
        pub const __completeUploadSubmission = TestApp.__completeUploadSubmission;
        pub const __resumeMultipart = TestApp.__resumeMultipart;
        pub const __multipartFinalizationFlow = TestApp.__multipartFinalizationFlow;
        pub const __multipartFinalizationOutcome = TestApp.__multipartFinalizationOutcome;
        pub const __multipartFinalizationReport = TestApp.__multipartFinalizationReport;
        pub const __startMultipartFinalization = TestApp.__startMultipartFinalization;
        pub const __cancelMultipart = TestApp.__cancelMultipart;
        pub const __multipartTerminalSource = TestApp.__multipartTerminalSource;
    };
}

pub const TwoStageApp = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max = TestApp.upload_request_handles_max;
    pub const upload_window_max = TestApp.upload_window_max;
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{TwoStageStartupSink};
    };
    pub const Workspace = TestApp.Workspace;
    pub const __peekUploadSubmission = TestApp.__peekUploadSubmission;
    pub const __markUploadSubmitted = TestApp.__markUploadSubmitted;
    pub const __completeUploadSubmission = TestApp.__completeUploadSubmission;
    pub const __resumeMultipart = TestApp.__resumeMultipart;
    pub const __multipartFinalizationFlow = TestApp.__multipartFinalizationFlow;
    pub const __multipartFinalizationOutcome = TestApp.__multipartFinalizationOutcome;
    pub const __multipartFinalizationReport = TestApp.__multipartFinalizationReport;
    pub const __startMultipartFinalization = TestApp.__startMultipartFinalization;
    pub const __cancelMultipart = TestApp.__cancelMultipart;
    pub const __multipartTerminalSource = TestApp.__multipartTerminalSource;
};

pub const RuntimeStorage = struct {
    pub const runtime_limits = TestStorage.runtime_limits;
    pub const Request = TestStorage.Request;
    pub const Connection = TestStorage.Connection;

    upload_registry: RuntimeRegistry = .{},
    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *@This(), request_index: u16) error{Invalid}![]u8 {
        if (request_index != 0) return error.Invalid;
        return &self.body;
    }
};

pub const RuntimeController = worker_upload.Controller(RuntimeApp, RuntimeStorage, TestReactor);

pub fn expectEntropyCleared(controller: anytype) !void {
    try std.testing.expectEqual([_]u8{0} ** 32, controller.runtime_entropy);
}

pub const completeTimedTarget = split.completeTimedTarget;

pub const targetWinnerSchedule = split.targetWinnerSchedule;

pub const deadlineWinnerSchedule = split.deadlineWinnerSchedule;

pub const FailureMode = split.FailureMode;

pub const rollbackScenario = split.rollbackScenario;

pub const startThreeRuntimes = split.startThreeRuntimes;

pub const drainEarlierRuntimes = split.drainEarlierRuntimes;

pub const normalStopFailureScenario = split.normalStopFailureScenario;

pub const expectRuntimeFatalMetric = split.expectRuntimeFatalMetric;

test {
    _ = @import("worker_upload_runtime_registry_test_part_1.zig");
}

const source = @import("worker_upload_transport_fuzz_check.zig");
const std = source.std;
const multipart = source.multipart;
const finalization = source.finalization;
const parser = source.parser;
const upload_dispatch = source.upload_dispatch;
const upload_finalizer = source.upload_finalizer;
const upload_sink_driver = source.upload_sink_driver;
const reactor = source.reactor;
const upload_transport = source.upload_transport;
const worker_upload = source.worker_upload;
const upload_metrics = source.upload_metrics;
const runtime_fuzz = source.runtime_fuzz;
const lanes = source.lanes;
const paths = source.paths;
const Behavior = source.Behavior;
const RequestApp = source.RequestApp;
const RequestStorage = source.RequestStorage;
const TestReactor = source.TestReactor;
const RequestController = source.RequestController;
const RequestOutcome = source.RequestOutcome;
const expectParserRejectionTerminal = source.expectParserRejectionTerminal;
const runRequestSchedule = source.runRequestSchedule;
const drainRequestSchedule = source.drainRequestSchedule;
const applyRequestCompletion = source.applyRequestCompletion;
const expectRequestOutcome = source.expectRequestOutcome;
const seedDirectory = source.seedDirectory;
const targetLane = source.targetLane;
const chooseLane = source.chooseLane;

pub const RuntimeMode = enum(u8) { clean, start_failure, resume_failure, submit_failure };

pub fn RuntimeSink(comptime marker: u8) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = void;
        pub const WriteState = void;
        pub const Summary = void;
        pub const BeginInput = void;
        pub const StartupState = void;
        pub const Runtime = struct { directory: multipart.FileHandle };
        pub const Error = error{Rejected};
        pub const io_requirements = multipart.IoRequirements{ .open = true, .close = true };
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 1;
        pub const initial_state: State = {};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            event: multipart.PollEvent(multipart.RuntimeStartInput),
        ) Error!multipart.Poll(Runtime) {
            return switch (event) {
                .start => if (marker == 3) error.Rejected else .{ .request = .{ .open = .{
                    .base = .working_directory,
                    .path = if (marker == 1) "." else "./.",
                    .access = .read_only,
                    .kind = .directory,
                } } },
                .completion => |completion| if (marker == 4)
                    error.Rejected
                else
                    .{ .done = .{ .directory = switch (completion) {
                        .success => |success| switch (success) {
                            .open => |handle| handle,
                            else => return error.Rejected,
                        },
                        .failure => return error.Rejected,
                    } } },
            };
        }

        pub fn runtimeStop(
            runtime: *Runtime,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return switch (event) {
                .start => .{ .request = .{ .close = .{ .file = runtime.directory } } },
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
            return syncDone(event);
        }
        pub fn write(
            _: *Runtime,
            _: *State,
            _: *WriteState,
            event: multipart.PollEvent(multipart.WriteInput),
        ) Error!multipart.Poll(void) {
            return syncDone(event);
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
            return syncDone(event);
        }
        pub fn abort(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return syncDone(event);
        }
        pub fn syncDone(event: anytype) Error!multipart.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => error.Rejected,
            };
        }
    };
}

pub const SinkA = RuntimeSink(1);

pub const SinkB = RuntimeSink(2);

pub const SinkStartFailure = RuntimeSink(3);

pub const SinkResumeFailure = RuntimeSink(4);

pub const RuntimeRegistry = struct {
    a: upload_sink_driver.Runtime(SinkA) = .{},
    b: upload_sink_driver.Runtime(SinkB) = .{},
    start_failure: upload_sink_driver.Runtime(SinkStartFailure) = .{},
    resume_failure: upload_sink_driver.Runtime(SinkResumeFailure) = .{},

    pub fn driver(self: *@This(), comptime Sink: type) *upload_sink_driver.Runtime(Sink) {
        if (Sink == SinkA) return &self.a;
        if (Sink == SinkB) return &self.b;
        if (Sink == SinkStartFailure) return &self.start_failure;
        if (Sink == SinkResumeFailure) return &self.resume_failure;
        unreachable;
    }
};

pub fn RuntimeApp(comptime mode: RuntimeMode) type {
    const catalog_types = switch (mode) {
        .clean => [_]type{ SinkA, SinkB },
        .start_failure => [_]type{ SinkA, SinkB, SinkStartFailure },
        .resume_failure, .submit_failure => [_]type{ SinkA, SinkB, SinkResumeFailure },
    };
    return struct {
        pub const upload_async_sink_present = true;
        pub const upload_request_handles_max: u32 = 1;
        pub const upload_window_max: u32 = 1;
        pub const UploadCatalog = struct {
            pub const sink_types = catalog_types;
        };
        pub const Workspace = RequestApp.Workspace;
        pub const __peekUploadSubmission = RequestApp.__peekUploadSubmission;
        pub const __markUploadSubmitted = RequestApp.__markUploadSubmitted;
        pub const __completeUploadSubmission = RequestApp.__completeUploadSubmission;
        pub const __resumeMultipart = RequestApp.__resumeMultipart;
        pub const __cancelMultipart = RequestApp.__cancelMultipart;
        pub const __startMultipartFinalization = RequestApp.__startMultipartFinalization;
        pub const __multipartFinalizationFlow = RequestApp.__multipartFinalizationFlow;
        pub const __multipartFinalizationReport = RequestApp.__multipartFinalizationReport;
        pub const __multipartTerminalSource = RequestApp.__multipartTerminalSource;
    };
}

pub const RuntimeStorage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    pub const Request = RequestStorage.Request;
    pub const Connection = RequestStorage.Connection;
    upload_registry: RuntimeRegistry = .{},
    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *@This(), index: u16) error{Invalid}![]u8 {
        if (index != 0) return error.Invalid;
        return &self.body;
    }
};

pub fn runRuntimeSchedule(comptime mode: RuntimeMode, cleanup_failure: bool) !void {
    const App = RuntimeApp(mode);
    const Controller = worker_upload.Controller(App, RuntimeStorage, TestReactor);
    var storage = RuntimeStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(4);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0xa5} ** 32),
    ) == .none);
    try std.testing.expect(try completeRuntimeOpen(
        &controller,
        &storage,
        &io,
        80,
        false,
    ) == .none);
    const second = completeRuntimeOpen(
        &controller,
        &storage,
        &io,
        81,
        mode == .submit_failure,
    );
    if (mode == .clean) {
        try std.testing.expect(try second == .registry_ready);
        return stopRuntime(&controller, &storage, &io);
    }
    try std.testing.expect(try second == .none);
    if (mode == .resume_failure) {
        const target = io.takeKind(.file_open);
        try std.testing.expect(try runtime_fuzz.completeTimedTarget(
            &controller,
            &storage,
            &io,
            target,
            .{ .failure = .io_failure },
            false,
        ) == .none);
    }
    try runtime_fuzz.drainRollback(
        &controller,
        &storage,
        &io,
        if (mode == .submit_failure) error.BackendFailure else error.ApplicationFailure,
        cleanup_failure,
    );
}

pub fn completeRuntimeOpen(
    controller: anytype,
    storage: anytype,
    io: *TestReactor,
    fd: i32,
    fail_before_resume: bool,
) !worker_upload.Event {
    return runtime_fuzz.completeTimedTarget(
        controller,
        storage,
        io,
        io.takeKind(.file_open),
        .{ .success = .{ .file_open = .{ .value = fd } } },
        fail_before_resume,
    );
}

pub fn stopRuntime(controller: anytype, storage: anytype, io: *TestReactor) !void {
    try std.testing.expect(try controller.beginRegistryStop(storage, io) == .none);
    const close_b = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 81), close_b.operation.file_close.file.value);
    try std.testing.expect(try runtime_fuzz.completeTimedTarget(
        controller,
        storage,
        io,
        close_b,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    const close_a = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 80), close_a.operation.file_close.file.value);
    try std.testing.expect(try runtime_fuzz.completeTimedTarget(
        controller,
        storage,
        io,
        close_a,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .registry_stopped);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
}

pub fn fuzzWorkerUpload(_: void, smith: *std.testing.Smith) !void {
    try runRequestSchedule(smith);
    const mode: RuntimeMode = @enumFromInt(smith.valueRangeAtMost(u8, 0, 3));
    switch (mode) {
        inline else => |selected| try runRuntimeSchedule(selected, smith.value(bool)),
    }
}

pub const fuzz_corpus = [_][]const u8{
    &([_]u8{0x00} ** 64),
    &([_]u8{0xff} ** 64),
    &([_]u8{ 0x01, 0x02, 0x03, 0x04 } ** 16),
    &([_]u8{ 0x04, 0x03, 0x02, 0x01 } ** 16),
};

pub fn writeLane(lane: upload_dispatch.Lane) ?u8 {
    return switch (lane) {
        .write => |index| if (index < lanes) index else null,
        .lifecycle => null,
    };
}

pub fn laneBit(lane: u8) u16 {
    return @as(u16, 1) << @intCast(lane);
}

pub fn requestReport(cause: ?upload_finalizer.UpstreamFailure) finalization.Report {
    return .{
        .outcome = if (cause == null) .committed else .failed,
        .primary = if (cause) |value| .{
            .class = .{ .upstream = value },
            .identity = null,
        } else null,
        .instance_count = 0,
        .commit_attempted_count = 0,
        .commit_completed_count = 0,
        .abort_attempted_count = 0,
        .abort_completed_count = 0,
        .cleanup_failure_count = 0,
    };
}

const std = @import("std");

const multipart = @import("../../src/multipart.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const upload_sink_driver = @import("../../src/internal/upload/sink_driver.zig");
const worker_upload = @import("../../src/internal/runtime/worker/upload_transport.zig");
const base = @import("worker_upload_transport_test.zig");

const Sink = multipart.FileSink(.{
    .root = "diagnostic-root",
    .durability = .buffered,
});

const Registry = struct {
    file: upload_sink_driver.Runtime(Sink) = .{},

    pub fn driver(self: *@This(), comptime SinkType: type) *upload_sink_driver.Runtime(SinkType) {
        if (SinkType == Sink) return &self.file;
        unreachable;
    }
};

const App = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max = base.TestApp.upload_request_handles_max;
    pub const upload_window_max = base.TestApp.upload_window_max;
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{Sink};
    };
    pub const Workspace = base.TestApp.Workspace;
    pub const __peekUploadSubmission = base.TestApp.__peekUploadSubmission;
    pub const __markUploadSubmitted = base.TestApp.__markUploadSubmitted;
    pub const __completeUploadSubmission = base.TestApp.__completeUploadSubmission;
    pub const __resumeMultipart = base.TestApp.__resumeMultipart;
    pub const __multipartFinalizationFlow = base.TestApp.__multipartFinalizationFlow;
    pub const __multipartFinalizationOutcome = base.TestApp.__multipartFinalizationOutcome;
    pub const __multipartFinalizationReport = base.TestApp.__multipartFinalizationReport;
    pub const __startMultipartFinalization = base.TestApp.__startMultipartFinalization;
    pub const __cancelMultipart = base.TestApp.__cancelMultipart;
    pub const __multipartTerminalSource = base.TestApp.__multipartTerminalSource;
};

const Storage = struct {
    pub const runtime_limits = base.TestStorage.runtime_limits;
    pub const Request = base.TestStorage.Request;
    pub const Connection = base.TestStorage.Connection;

    upload_registry: Registry = .{},
    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *@This(), request_index: u16) error{Invalid}![]u8 {
        if (request_index != 0) return error.Invalid;
        return &self.body;
    }
};

const TestReactor = base.TestReactor;
const Controller = worker_upload.Controller(App, Storage, TestReactor);

const DurableSink = multipart.FileSink(.{
    .root = "durable-diagnostic-root",
    .durability = .crash_durable,
    .staging = .{ .named_staging = "staging" },
});

const DurableRegistry = struct {
    file: upload_sink_driver.Runtime(DurableSink) = .{},

    pub fn driver(
        self: *@This(),
        comptime SinkType: type,
    ) *upload_sink_driver.Runtime(SinkType) {
        if (SinkType == DurableSink) return &self.file;
        unreachable;
    }
};

const DurableApp = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max = base.TestApp.upload_request_handles_max;
    pub const upload_window_max = base.TestApp.upload_window_max;
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{DurableSink};
    };
    pub const Workspace = base.TestApp.Workspace;
    pub const __peekUploadSubmission = base.TestApp.__peekUploadSubmission;
    pub const __markUploadSubmitted = base.TestApp.__markUploadSubmitted;
    pub const __completeUploadSubmission = base.TestApp.__completeUploadSubmission;
    pub const __resumeMultipart = base.TestApp.__resumeMultipart;
    pub const __multipartFinalizationFlow = base.TestApp.__multipartFinalizationFlow;
    pub const __multipartFinalizationOutcome = base.TestApp.__multipartFinalizationOutcome;
    pub const __multipartFinalizationReport = base.TestApp.__multipartFinalizationReport;
    pub const __startMultipartFinalization = base.TestApp.__startMultipartFinalization;
    pub const __cancelMultipart = base.TestApp.__cancelMultipart;
    pub const __multipartTerminalSource = base.TestApp.__multipartTerminalSource;
};

const DurableStorage = struct {
    pub const runtime_limits = base.TestStorage.runtime_limits;
    pub const Request = base.TestStorage.Request;
    pub const Connection = base.TestStorage.Connection;

    upload_registry: DurableRegistry = .{},
    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *@This(), request_index: u16) error{Invalid}![]u8 {
        if (request_index != 0) return error.Invalid;
        return &self.body;
    }
};

const RepeatedFailureReactor = struct {
    pub const file_handle_capacity = 4;
    pub const file_target_capacity = 2;

    submissions: [8]reactor.Submission = undefined,
    submission_head: u8 = 0,
    submission_count: u8 = 0,
    fail_submits_remaining: u8 = 0,

    pub fn submit(self: *@This(), submission: reactor.Submission) error{Full}!void {
        if (self.fail_submits_remaining != 0) {
            self.fail_submits_remaining -= 1;
            return error.Full;
        }
        if (self.submission_count == self.submissions.len) return error.Full;
        const index = (self.submission_head + self.submission_count) %
            @as(u8, self.submissions.len);
        self.submissions[index] = submission;
        self.submission_count += 1;
    }

    pub fn take(self: *@This()) reactor.Submission {
        std.debug.assert(self.submission_count != 0);
        const submission = self.submissions[self.submission_head];
        self.submission_head = (self.submission_head + 1) %
            @as(u8, self.submissions.len);
        self.submission_count -= 1;
        return submission;
    }
};

const DurableController = worker_upload.Controller(
    DurableApp,
    DurableStorage,
    RepeatedFailureReactor,
);

fn completeRepeated(
    controller: *DurableController,
    storage: *DurableStorage,
    io: *RepeatedFailureReactor,
    submission: reactor.Submission,
    result: reactor.CompletionResult,
    fail_before_resume: u8,
) !worker_upload.Event {
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = submission.token,
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
    io.fail_submits_remaining = fail_before_resume;
    return controller.complete(storage, io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    });
}

fn complete(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    submission: reactor.Submission,
    result: reactor.CompletionResult,
) !worker_upload.Event {
    return completeTimed(controller, storage, io, submission, result, false);
}

fn completeTimed(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    submission: reactor.Submission,
    result: reactor.CompletionResult,
    fail_before_resume: bool,
) !worker_upload.Event {
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = submission.token,
        .result = result,
        .more = false,
    }) == .none);
    const timeout = io.takeKind(.timeout);
    const cancel = io.takeKind(.cancel);
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

test "FileSink deadline detail survives capture cleanup and rendering" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(6);
    const started_ns: u64 = 100;

    try std.testing.expect(try controller.beginRegistryStartAt(
        &storage,
        &io,
        &([_]u8{0x95} ** 32),
        started_ns,
    ) == .none);
    const root_open = io.takeKind(.file_open);
    const timeout = io.takeKind(.timeout);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = timeout.token,
        .result = .{ .success = .{ .timeout = {} } },
        .more = false,
    }, started_ns + 1) == .none);
    const cancel = io.takeKind(.upload_cancel);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = root_open.token,
        .result = .{ .success = .{ .file_open = .{ .value = 90 } } },
        .more = false,
    }, started_ns + 2) == .none);
    try std.testing.expect(try controller.completeAt(&storage, &io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .upload_cancel = .not_found } },
        .more = false,
    }, started_ns + 3) == .none);

    const diagnostic = controller.startupDiagnostic().?;
    const deadline = diagnostic.failure.deadline.?;
    try std.testing.expectEqual(@TypeOf(deadline.kind).deadline, deadline.kind);
    try std.testing.expectEqual(
        Storage.runtime_limits.timeouts.startup_io_ns,
        deadline.timeout_ns,
    );
    try std.testing.expectEqual(started_ns, deadline.started_ns);
    try std.testing.expectEqual(timeout.operation.timeout.deadline_ns, deadline.deadline_ns);
    var buffer: [worker_upload.StartupDiagnostic.rendered_bytes_max]u8 = undefined;
    const rendered = try diagnostic.render(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "startup_deadline(kind=deadline") != null);

    const root_close = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 90), root_close.operation.file_close.file.value);
    try std.testing.expectError(error.ApplicationFailure, complete(
        &controller,
        &storage,
        &io,
        root_close,
        .{ .success = .{ .file_close = {} } },
    ));
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
}

test "real FileSink startup failure survives worker controller rollback" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(7);

    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x96} ** 32),
    ) == .none);
    const root_open = io.take();
    try std.testing.expectEqualStrings("diagnostic-root", root_open.operation.file_open.path);
    try std.testing.expect(try complete(&controller, &storage, &io, root_open, .{
        .success = .{ .file_open = .{ .value = 91 } },
    }) == .none);

    const probe_open = io.take();
    try std.testing.expectEqual(multipart.Create.anonymous, probe_open.operation.file_open.create);
    try std.testing.expect(try complete(&controller, &storage, &io, probe_open, .{
        .failure = .unsupported,
    }) == .none);

    const root_close = io.take();
    try std.testing.expectEqual(@as(i32, 91), root_close.operation.file_close.file.value);
    try std.testing.expectError(error.ApplicationFailure, complete(
        &controller,
        &storage,
        &io,
        root_close,
        .{ .success = .{ .file_close = {} } },
    ));
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expect(storage.upload_registry.file.quiescent());

    const diagnostic = controller.startupDiagnostic().?;
    try std.testing.expectEqual(@as(u16, 0), diagnostic.sink_registry_index);
    try std.testing.expectEqualStrings("Unsupported", diagnostic.failure.cause.name());
    var buffer: [1024]u8 = undefined;
    const rendered = try diagnostic.render(&buffer);
    try std.testing.expectEqualStrings(
        "PLOOF-E3519 FileSink startup probe failed sink_registry_index=0 " ++
            "root(15)=diagnostic-root staging=anonymous_required durability=buffered " ++
            "mode=0o600 phase=open_probe operation=open cause=Unsupported " ++
            "cleanup(destination_unlink=not_needed,source_unlink=not_needed," ++
            "staging_sync=not_needed,root_sync=not_needed,probe_close=not_needed," ++
            "staging_close=not_needed,root_close=succeeded,generator_cleared=true); " ++
            "anonymous staging remains required and Ploof did not fall back; " ++
            "to use compatibility mode, explicitly select " ++
            ".staging = .{ .named_staging = \"relative/pre-existing-directory\" }\n",
        rendered,
    );
}

test "FileSink submit failure does not report synthetic cancellation as primary" {
    var storage = Storage{};
    var io = TestReactor{ .fail_next_submit = true };
    var controller = try Controller.init(8);

    try std.testing.expectError(error.BackendFailure, controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x97} ** 32),
    ));
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(@as(?u16, 0), controller.startup_failure_index);
    try std.testing.expect(controller.startupDiagnostic() == null);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expect(storage.upload_registry.file.quiescent());
}

test "FileSink rollback submit failure preserves the real startup diagnostic" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(9);

    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x98} ** 32),
    ) == .none);
    const root_open = io.take();
    try std.testing.expect(try complete(&controller, &storage, &io, root_open, .{
        .success = .{ .file_open = .{ .value = 92 } },
    }) == .none);

    const probe_open = io.take();
    try std.testing.expect(try completeTimed(
        &controller,
        &storage,
        &io,
        probe_open,
        .{ .failure = .unsupported },
        true,
    ) == .none);
    const root_close = io.take();
    try std.testing.expectError(error.ApplicationFailure, complete(
        &controller,
        &storage,
        &io,
        root_close,
        .{ .success = .{ .file_close = {} } },
    ));

    const diagnostic = controller.startupDiagnostic().?;
    try std.testing.expectEqualStrings("Unsupported", diagnostic.failure.cause.name());
    try std.testing.expectEqual(
        @TypeOf(diagnostic.failure.cleanup.root_close).failed,
        diagnostic.failure.cleanup.root_close,
    );
    try std.testing.expect(diagnostic.failure.cleanup.generator_cleared);
    try std.testing.expect(controller.rollback_cleanup_failed);
    try std.testing.expect(storage.upload_registry.file.quiescent());
    try std.testing.expect(controller.ownershipProven());
}

test "FileSink repeated rollback submit failures refresh scrubbed diagnostic" {
    var storage = DurableStorage{};
    var io = RepeatedFailureReactor{};
    var controller = try DurableController.init(11);

    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x9a} ** 32),
    ) == .none);
    var raw_fd: i32 = 110;
    inline for (0..3) |_| {
        const opened = io.take();
        try std.testing.expect(opened.operation == .file_open);
        try std.testing.expect(try completeRepeated(
            &controller,
            &storage,
            &io,
            opened,
            .{ .success = .{ .file_open = .{ .value = raw_fd } } },
            0,
        ) == .none);
        raw_fd += 1;
    }

    const write = io.take();
    try std.testing.expect(write.operation == .file_write);
    try std.testing.expect(try completeRepeated(
        &controller,
        &storage,
        &io,
        write,
        .{ .success = .{
            .file_write = @intCast(write.operation.file_write.bytes.len),
        } },
        0,
    ) == .none);
    const probe_sync = io.take();
    try std.testing.expect(probe_sync.operation == .file_sync);
    try std.testing.expect(try completeRepeated(
        &controller,
        &storage,
        &io,
        probe_sync,
        .{ .success = .{ .file_sync = {} } },
        0,
    ) == .none);

    const publish = io.take();
    try std.testing.expect(publish.operation == .file_rename_no_replace);
    try std.testing.expect(try completeRepeated(
        &controller,
        &storage,
        &io,
        publish,
        .{ .failure = .unsupported },
        2,
    ) == .none);
    try std.testing.expectEqual(@as(u8, 0), io.fail_submits_remaining);

    var owner_closes: u8 = 0;
    while (true) {
        const close = io.take();
        try std.testing.expect(close.operation == .file_close);
        owner_closes += 1;
        const completed = completeRepeated(
            &controller,
            &storage,
            &io,
            close,
            .{ .success = .{ .file_close = {} } },
            0,
        );
        if (completed) |event| {
            try std.testing.expect(event == .none);
        } else |problem| {
            try std.testing.expectEqual(error.ApplicationFailure, problem);
            break;
        }
    }
    try std.testing.expectEqual(@as(u8, 3), owner_closes);

    const diagnostic = controller.startupDiagnostic().?;
    try std.testing.expectEqualStrings("Unsupported", diagnostic.failure.cause.name());
    try std.testing.expectEqual(
        @TypeOf(diagnostic.failure.cleanup.source_unlink).failed,
        diagnostic.failure.cleanup.source_unlink,
    );
    try std.testing.expect(diagnostic.failure.cleanup.generator_cleared);
    const generator = &storage.upload_registry.file.startup_state.generator;
    try std.testing.expect(std.mem.allEqual(u8, &generator.key, 0));
    try std.testing.expect(controller.rollback_cleanup_failed);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expect(storage.upload_registry.file.quiescent());
}

test "FileSink stop submit failure scrubs its key before owner cleanup" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(10);
    try startFileSink(&controller, &storage, &io);

    const zero_key = [_]u8{0} ** std.crypto.hash.Blake3.key_length;
    const runtime = storage.upload_registry.file.runtimePointer().?;
    try std.testing.expect(!std.mem.eql(u8, &zero_key, &runtime.generator.key));

    io.fail_next_submit = true;
    try std.testing.expect(try controller.beginRegistryStop(&storage, &io) == .none);
    try std.testing.expect(std.mem.eql(u8, &zero_key, &runtime.generator.key));
    const owner_close = io.take();
    try std.testing.expectError(error.BackendFailure, complete(
        &controller,
        &storage,
        &io,
        owner_close,
        .{ .success = .{ .file_close = {} } },
    ));
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(storage.upload_registry.file.quiescent());
}

fn startFileSink(controller: *Controller, storage: *Storage, io: *TestReactor) !void {
    var event = try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{0x99} ** 32),
    );
    var raw_fd: i32 = 100;
    while (event == .none) {
        const submission = io.take();
        const result: reactor.CompletionResult = switch (submission.operation) {
            .file_open => result: {
                const result = reactor.CompletionResult{
                    .success = .{ .file_open = .{ .value = raw_fd } },
                };
                raw_fd += 1;
                break :result result;
            },
            .file_write => |write| .{ .success = .{
                .file_write = @intCast(write.bytes.len),
            } },
            .file_link => .{ .success = .{ .file_link = {} } },
            .file_unlink => .{ .success = .{ .file_unlink = {} } },
            .file_close => .{ .success = .{ .file_close = {} } },
            else => return error.TestUnexpectedResult,
        };
        event = try complete(controller, storage, io, submission, result);
    }
    try std.testing.expect(event == .registry_ready);
}

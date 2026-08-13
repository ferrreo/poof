const source = @import("worker_upload_file_sink_cleanup_test.zig");
const std = source.std;
const application = source.application;
const endpoint = source.endpoint;
const multipart = source.multipart;
const parser = source.parser;
const reactor = source.reactor;
const response = source.response;
const route = source.route;
const upload = source.upload;
const upload_finalizer = source.upload_finalizer;
const worker_upload = source.worker_upload;
const worker_upload_metrics = source.worker_upload_metrics;
const Sink = source.Sink;
const AsyncFinishSink = source.AsyncFinishSink;
const Body = source.Body;
const Definition = source.Definition;
const Spec = source.Spec;
const Context = source.Context;
const Consumer = source.Consumer;
const App = source.App;
const AsyncBody = source.AsyncBody;
const AsyncDefinition = source.AsyncDefinition;
const AsyncSpec = source.AsyncSpec;
const AsyncConsumer = source.AsyncConsumer;
const AsyncApp = source.AsyncApp;
const workspace_bytes = source.workspace_bytes;
const async_workspace_bytes = source.async_workspace_bytes;
const wire = source.wire;
const async_missing_required_wire = source.async_missing_required_wire;
const Storage = source.Storage;
const AsyncStorage = source.AsyncStorage;

pub const TestReactor = struct {
    pub const file_handle_capacity = 4;
    pub const file_target_capacity = 4;

    submissions: [8]reactor.Submission = undefined,
    count: u8 = 0,

    pub fn submit(self: *TestReactor, submission: reactor.Submission) error{Full}!void {
        if (self.count == self.submissions.len) return error.Full;
        self.submissions[self.count] = submission;
        self.count += 1;
    }

    pub fn take(self: *TestReactor) reactor.Submission {
        const submission = self.submissions[0];
        self.count -= 1;
        std.mem.copyForwards(
            reactor.Submission,
            self.submissions[0..self.count],
            self.submissions[1..][0..self.count],
        );
        return submission;
    }

    pub fn takeKind(self: *TestReactor, kind: reactor.OperationKind) reactor.Submission {
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            if (std.meta.activeTag(self.submissions[index].operation) != kind) continue;
            const submission = self.submissions[index];
            self.count -= 1;
            std.mem.copyForwards(
                reactor.Submission,
                self.submissions[index..self.count],
                self.submissions[index + 1 ..][0 .. self.count - index],
            );
            return submission;
        }
        unreachable;
    }
};

pub const Controller = worker_upload.Controller(App, Storage, TestReactor);

pub const AsyncController = worker_upload.Controller(AsyncApp, AsyncStorage, TestReactor);

pub fn beginFourWrites(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
) ![4]reactor.Submission {
    try prepareMultipart(storage);
    var offset: usize = 0;
    var open_completed = false;
    var steps: u8 = 0;
    while (io.count < 4) : (steps += 1) {
        if (steps == 8 or offset == wire.len) return error.TestUnexpectedResult;
        const progress = try App.__feedMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
            wire[offset..],
        );
        offset += progress.consumed;
        if (progress.flow == .ready) continue;
        if (progress.flow != .paused) return error.TestUnexpectedResult;
        const event = try controller.submitParserWork(storage, io, 0);
        if (event == .request_resumed) continue;
        if (event != .none) return error.TestUnexpectedResult;
        if (open_completed) break;
        const open = io.take();
        try std.testing.expect(open.operation == .file_open);
        const resumed = try controller.complete(storage, io, .{
            .token = open.token,
            .result = .{ .success = .{ .file_open = .{ .value = 82 } } },
            .more = false,
        });
        try std.testing.expect(resumed == .request_resumed);
        open_completed = true;
    }
    try std.testing.expect(open_completed);
    var writes: [4]reactor.Submission = undefined;
    for (&writes) |*submission| submission.* = io.take();
    return writes;
}

pub fn completeCanceled(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    submission: reactor.Submission,
) !worker_upload.Event {
    return controller.complete(storage, io, .{
        .token = submission.token,
        .result = .{ .failure = .canceled },
        .more = false,
    });
}

pub fn completeCancel(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    submission: reactor.Submission,
    result: reactor.CancelResult,
) !worker_upload.Event {
    return controller.complete(storage, io, .{
        .token = submission.token,
        .result = .{ .success = .{ .upload_cancel = result } },
        .more = false,
    });
}

pub fn exerciseAsyncFinishCancellation(target_first: bool) !void {
    var storage = AsyncStorage{};
    var io = TestReactor{};
    var controller = try AsyncController.init(3);
    try startAsyncRegistry(&controller, &storage, &io);
    const target = try beginAsyncFinishOpen(&controller, &storage, &io);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    const cancel = io.take();
    try std.testing.expect(cancel.operation == .upload_cancel);

    var event: worker_upload.Event = .none;
    if (target_first) {
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = target.token,
            .result = .{ .failure = .canceled },
            .more = false,
        }) == .none);
        event = try controller.complete(&storage, &io, .{
            .token = cancel.token,
            .result = .{ .success = .{ .upload_cancel = .not_found } },
            .more = false,
        });
    } else {
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = cancel.token,
            .result = .{ .success = .{ .upload_cancel = .canceled } },
            .more = false,
        }) == .none);
        event = try controller.complete(&storage, &io, .{
            .token = target.token,
            .result = .{ .failure = .canceled },
            .more = false,
        });
    }
    try std.testing.expect(event == .request_finalized);
    const report = event.request_finalized.report;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(@as(u32, 0), report.cleanup_failure_count);
    const primary = report.primary orelse return error.TestUnexpectedResult;
    switch (primary.class) {
        .upstream => |cause| try std.testing.expectEqual(
            upload_finalizer.UpstreamFailure.peer_disconnect,
            cause,
        ),
        .sink => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    const metrics = controller.metricsSnapshot();
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, 0),
        metrics.recoverable_failures[
            @intFromEnum(worker_upload_metrics.RecoverableFailureClass.canceled)
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.cancellations[
            @intFromEnum(worker_upload_metrics.CancellationOutcome.target_canceled)
        ],
    );
}

pub fn exerciseFileSinkOpenCancellation(target_first: bool) !void {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    const target = try beginFileSinkOpen(&controller, &storage, &io);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    const cancel = io.take();
    try std.testing.expect(cancel.operation == .upload_cancel);

    var event: worker_upload.Event = .none;
    if (target_first) {
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = target.token,
            .result = .{ .failure = .canceled },
            .more = false,
        }) == .none);
        event = try controller.complete(&storage, &io, .{
            .token = cancel.token,
            .result = .{ .success = .{ .upload_cancel = .not_found } },
            .more = false,
        });
    } else {
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = cancel.token,
            .result = .{ .success = .{ .upload_cancel = .canceled } },
            .more = false,
        }) == .none);
        event = try controller.complete(&storage, &io, .{
            .token = target.token,
            .result = .{ .failure = .canceled },
            .more = false,
        });
    }
    try expectCleanPeerCancellation(event, controller.metricsSnapshot());
    try std.testing.expectEqual(@as(u32, 0), sinkReport(&storage).live_anonymous);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
}

pub fn expectCleanPeerCancellation(
    event: worker_upload.Event,
    metrics: worker_upload_metrics.Snapshot,
) !void {
    try std.testing.expect(event == .request_finalized);
    const report = event.request_finalized.report;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(@as(u32, 0), report.cleanup_failure_count);
    const primary = report.primary orelse return error.TestUnexpectedResult;
    switch (primary.class) {
        .upstream => |cause| try std.testing.expectEqual(
            upload_finalizer.UpstreamFailure.peer_disconnect,
            cause,
        ),
        .sink => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 1), report.abort_attempted_count);
    try std.testing.expectEqual(@as(u32, 1), report.abort_completed_count);
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, 0),
        metrics.recoverable_failures[
            @intFromEnum(worker_upload_metrics.RecoverableFailureClass.canceled)
        ],
    );
}

pub fn beginFileSinkOpen(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
) !reactor.Submission {
    try prepareMultipart(storage);
    var offset: usize = 0;
    while (offset < wire.len) {
        const progress = try App.__feedMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
            wire[offset..],
        );
        offset += progress.consumed;
        if (progress.flow == .ready) continue;
        if (progress.flow != .paused) return error.TestUnexpectedResult;
        const event = try controller.submitParserWork(storage, io, 0);
        if (io.count != 0) {
            const target = io.take();
            try std.testing.expect(target.operation == .file_open);
            return target;
        }
        if (event != .request_resumed) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

pub fn beginAsyncFinishOpen(
    controller: *AsyncController,
    storage: *AsyncStorage,
    io: *TestReactor,
) !reactor.Submission {
    try prepareAsyncMultipart(storage);
    var offset: usize = 0;
    while (offset < async_missing_required_wire.len) {
        const progress = try AsyncApp.__feedMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
            async_missing_required_wire[offset..],
        );
        offset += progress.consumed;
        if (progress.flow == .ready) continue;
        if (progress.flow != .paused) return error.TestUnexpectedResult;
        const event = try controller.submitParserWork(storage, io, 0);
        if (io.count != 0) {
            const target = io.take();
            try std.testing.expect(target.operation == .file_open);
            return target;
        }
        if (event != .request_resumed) return error.TestUnexpectedResult;
    }
    for (0..8) |_| {
        const progress = try AsyncApp.__finishMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
        );
        if (progress.flow != .paused) return error.TestUnexpectedResult;
        const event = try controller.submitParserWork(storage, io, 0);
        if (io.count != 0) {
            const target = io.take();
            try std.testing.expect(target.operation == .file_open);
            return target;
        }
        if (event != .request_resumed) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

pub fn startRegistry(controller: *Controller, storage: *Storage, io: *TestReactor) !void {
    try startRegistryWith(controller, storage, io, 80, 0x51);
}

pub fn startAsyncRegistry(
    controller: *AsyncController,
    storage: *AsyncStorage,
    io: *TestReactor,
) !void {
    try startRegistryWith(controller, storage, io, 90, 0x52);
}

pub fn startRegistryWith(
    controller: anytype,
    storage: anytype,
    io: *TestReactor,
    first_descriptor: i32,
    entropy_byte: u8,
) !void {
    var event = try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{entropy_byte} ** 32),
    );
    var raw_fd = first_descriptor;
    while (event == .none) {
        const target = io.take();
        const result: reactor.CompletionResult = switch (target.operation) {
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
            .file_close => .{ .success = .{ .file_close = {} } },
            .file_link => .{ .success = .{ .file_link = {} } },
            .file_unlink => .{ .success = .{ .file_unlink = {} } },
            else => return error.TestUnexpectedResult,
        };
        event = try completeTimedRuntimeTarget(controller, storage, io, target, result);
    }
    try std.testing.expect(event == .registry_ready);
}

pub fn completeTimedRuntimeTarget(
    controller: anytype,
    storage: anytype,
    io: *TestReactor,
    target: reactor.Submission,
    result: reactor.CompletionResult,
) !worker_upload.Event {
    const timeout = io.takeKind(.timeout);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = target.token,
        .result = result,
        .more = false,
    }) == .none);
    const cancel = io.takeKind(.cancel);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = timeout.token,
        .result = .{ .failure = .canceled },
        .more = false,
    }) == .none);
    return controller.complete(storage, io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    });
}

pub fn prepareMultipart(storage: *Storage) !void {
    var state: void = {};
    var route_workspace = App.RouteSearchWorkspace{};
    var output: [256]u8 = undefined;
    var plan = App.plan(requestInput(), &route_workspace);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        &state,
        &storage.requests[0].workspace,
        &storage.body,
        &output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
    try App.__beginMultipart(
        &storage.requests[0].workspace,
        &storage.body,
        "B",
        &storage.upload_registry,
    );
}

pub fn prepareAsyncMultipart(storage: *AsyncStorage) !void {
    var state: void = {};
    var route_workspace = AsyncApp.RouteSearchWorkspace{};
    var output: [256]u8 = undefined;
    var plan = AsyncApp.plan(asyncRequestInput(), &route_workspace);
    try AsyncApp.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try AsyncApp.prepareHeadPlannedIn(
        &state,
        &storage.requests[0].workspace,
        &storage.body,
        &output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
    try AsyncApp.__beginMultipart(
        &storage.requests[0].workspace,
        &storage.body,
        "B",
        &storage.upload_registry,
    );
}

pub fn driveBody(controller: *Controller, storage: *Storage, io: *TestReactor) !void {
    var offset: usize = 0;
    while (offset < wire.len) {
        const progress = try App.__feedMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
            wire[offset..],
        );
        offset += progress.consumed;
        if (progress.flow == .paused) {
            _ = try driveParserWork(controller, storage, io);
        } else if (progress.consumed == 0) return error.TestUnexpectedResult;
    }
    while (true) {
        const progress = try App.__finishMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
        );
        switch (progress.flow) {
            .complete => return,
            .paused => if ((try driveParserWork(controller, storage, io)).flow == .complete) {
                return;
            },
            .ready => return error.TestUnexpectedResult,
        }
    }
}

pub fn driveParserWork(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
) !parser.Progress {
    const submitted = try controller.submitParserWork(storage, io, 0);
    switch (submitted) {
        .request_resumed => |resumed| return resumed.progress,
        .none => {},
        else => return error.TestUnexpectedResult,
    }
    while (io.count != 0) {
        const submission = io.take();
        const result: reactor.CompletionResult = switch (submission.operation) {
            .file_open => .{ .success = .{ .file_open = .{ .value = 82 } } },
            .file_write => |write| .{ .success = .{
                .file_write = @intCast(write.bytes.len),
            } },
            else => return error.TestUnexpectedResult,
        };
        const event = try controller.complete(storage, io, .{
            .token = submission.token,
            .result = result,
            .more = false,
        });
        switch (event) {
            .none => {},
            .request_resumed => |resumed| return resumed.progress,
            else => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

pub fn driveParserForRejection(
    controller: *AsyncController,
    storage: *AsyncStorage,
    io: *TestReactor,
) !?worker_upload.RejectionStatus {
    const submitted = try controller.submitParserWork(storage, io, 0);
    switch (submitted) {
        .none, .request_resumed => {},
        .request_rejected => |rejected| return rejected.status,
        else => return error.TestUnexpectedResult,
    }
    while (io.count != 0) {
        const submission = io.take();
        const result: reactor.CompletionResult = switch (submission.operation) {
            .file_open => .{ .success = .{ .file_open = .{ .value = 82 } } },
            .file_write => |write| .{ .success = .{
                .file_write = @intCast(write.bytes.len),
            } },
            else => return error.TestUnexpectedResult,
        };
        const event = try controller.complete(storage, io, .{
            .token = submission.token,
            .result = result,
            .more = false,
        });
        switch (event) {
            .none, .request_resumed => {},
            .request_rejected => |rejected| return rejected.status,
            else => return error.TestUnexpectedResult,
        }
    }
    return null;
}

pub fn sinkReport(storage: *Storage) Sink.Report {
    return Sink.report(storage.upload_registry.get(Sink).?);
}

pub fn requestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

pub fn asyncRequestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/async-upload",
        .raw_target = "/async-upload",
        .raw_path = "/async-upload",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

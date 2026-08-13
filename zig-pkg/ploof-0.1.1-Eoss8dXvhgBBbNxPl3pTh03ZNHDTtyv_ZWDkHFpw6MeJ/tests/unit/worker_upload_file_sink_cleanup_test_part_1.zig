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
const TestReactor = source.TestReactor;
const Controller = source.Controller;
const AsyncController = source.AsyncController;
const beginFourWrites = source.beginFourWrites;
const completeCanceled = source.completeCanceled;
const completeCancel = source.completeCancel;
const exerciseAsyncFinishCancellation = source.exerciseAsyncFinishCancellation;
const exerciseFileSinkOpenCancellation = source.exerciseFileSinkOpenCancellation;
const expectCleanPeerCancellation = source.expectCleanPeerCancellation;
const beginFileSinkOpen = source.beginFileSinkOpen;
const beginAsyncFinishOpen = source.beginAsyncFinishOpen;
const startRegistry = source.startRegistry;
const startAsyncRegistry = source.startAsyncRegistry;
const startRegistryWith = source.startRegistryWith;
const completeTimedRuntimeTarget = source.completeTimedRuntimeTarget;
const prepareMultipart = source.prepareMultipart;
const prepareAsyncMultipart = source.prepareAsyncMultipart;
const driveBody = source.driveBody;
const driveParserWork = source.driveParserWork;
const driveParserForRejection = source.driveParserForRejection;
const sinkReport = source.sinkReport;
const requestInput = source.requestInput;
const asyncRequestInput = source.asyncRequestInput;

test "real multipart parser fills four upload SQEs before any write CQE" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    const writes = try beginFourWrites(&controller, &storage, &io);

    try std.testing.expectEqual(@as(u8, 0), io.count);
    try std.testing.expectEqual(@as(u32, 4), controller.pending());
    for (writes, 0..) |submission, index| {
        try std.testing.expect(submission.operation == .file_write);
        for (writes[0..index]) |earlier| {
            try std.testing.expect(!submission.token.eql(earlier.token));
        }
    }
    const route_snapshot = controller.routeMetricsSnapshot(0).?;
    try std.testing.expectEqual(@as(u8, 4), route_snapshot.window);
    try std.testing.expect(controller.requests.store.states[0].window_full_since_ns != null);
}

test "FileSink peer abort abandons four canceled writes and keeps peer primary" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    const writes = try beginFourWrites(&controller, &storage, &io);

    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    var cancels: [4]reactor.Submission = undefined;
    for (&cancels) |*cancel| {
        cancel.* = io.take();
        try std.testing.expect(cancel.operation == .upload_cancel);
    }

    try std.testing.expect(try completeCancel(&controller, &storage, &io, cancels[0], .canceled) ==
        .none);
    try std.testing.expect(try completeCanceled(&controller, &storage, &io, writes[0]) == .none);
    try std.testing.expect(try completeCanceled(&controller, &storage, &io, writes[1]) == .none);
    try std.testing.expect(try completeCancel(&controller, &storage, &io, cancels[1], .not_found) ==
        .none);
    try std.testing.expect(try completeCancel(&controller, &storage, &io, cancels[2], .canceled) ==
        .none);
    try std.testing.expect(try completeCanceled(&controller, &storage, &io, writes[2]) == .none);
    try std.testing.expect(try completeCancel(&controller, &storage, &io, cancels[3], .not_found) ==
        .none);
    try std.testing.expect(try completeCanceled(&controller, &storage, &io, writes[3]) == .none);

    const close = io.take();
    try std.testing.expect(close.operation == .file_close);
    const event = try controller.complete(&storage, &io, .{
        .token = close.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    });
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
    try std.testing.expectEqual(@as(u32, 0), sinkReport(&storage).live_anonymous);
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
        @as(u64, 4),
        metrics.cancellations[
            @intFromEnum(worker_upload_metrics.CancellationOutcome.target_canceled)
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.primary_failures[
            @intFromEnum(worker_upload_metrics.PrimaryFailureClass.peer_disconnect)
        ],
    );
}

test "FileSink begin open cancellation leaves no partial staging state" {
    inline for (.{ false, true }) |target_first| {
        try exerciseFileSinkOpenCancellation(target_first);
    }
}

test "async multipart EOF missing a required field becomes a bounded bad request" {
    var storage = AsyncStorage{};
    var io = TestReactor{};
    var controller = try AsyncController.init(3);
    try startAsyncRegistry(&controller, &storage, &io);
    try prepareAsyncMultipart(&storage);

    var offset: usize = 0;
    while (offset < async_missing_required_wire.len) {
        const progress = try AsyncApp.__feedMultipartProgress(
            &storage.requests[0].workspace,
            &storage.body,
            async_missing_required_wire[offset..],
        );
        offset += progress.consumed;
        if (progress.flow == .paused) {
            if (try driveParserForRejection(&controller, &storage, &io)) |status| {
                try std.testing.expectEqual(
                    worker_upload.RejectionStatus.bad_request,
                    status,
                );
                try std.testing.expectEqual(@as(u32, 0), controller.pending());
                try std.testing.expect(controller.ownershipProven());
                return;
            }
        } else if (progress.consumed == 0) return error.TestUnexpectedResult;
    }
    const finish = try AsyncApp.__finishMultipartProgress(
        &storage.requests[0].workspace,
        &storage.body,
    );
    try std.testing.expectEqual(parser.Flow.paused, finish.flow);
    const status = (try driveParserForRejection(&controller, &storage, &io)) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(worker_upload.RejectionStatus.bad_request, status);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

test "async finish open cancellation drains without invoking sink completion" {
    inline for (.{ false, true }) |target_first| {
        try exerciseAsyncFinishCancellation(target_first);
    }
}

test "FileSink canceled abort close reconciles owner runtime and registry stop" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    try prepareMultipart(&storage);
    try driveBody(&controller, &storage, &io);

    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    inline for (0..2) |_| {
        const close = io.take();
        try std.testing.expect(close.operation == .file_close);
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = close.token,
            .result = .{ .failure = .canceled },
            .more = false,
        }) == .none);
        try std.testing.expectEqual(@as(u32, 1), sinkReport(&storage).live_anonymous);
        try std.testing.expectEqual(@as(u32, 2), controller.activeHandles());
    }
    try std.testing.expectEqual(
        @as(u64, 0),
        controller.metricsSnapshot().finalization_outcomes[
            @intFromEnum(upload_finalizer.Outcome.failed)
        ],
    );
    const close = io.take();
    const event = try controller.complete(&storage, &io, .{
        .token = close.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    });
    try std.testing.expect(event == .request_finalized);
    try std.testing.expect(event.request_finalized.response_failed);
    try std.testing.expectEqual(@as(u32, 1), event.request_finalized.report.cleanup_failure_count);
    try std.testing.expectEqual(@as(u32, 0), sinkReport(&storage).live_anonymous);
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());

    try std.testing.expect(try controller.beginRegistryStop(&storage, &io) == .none);
    const root_close = io.take();
    try std.testing.expect(try completeTimedRuntimeTarget(
        &controller,
        &storage,
        &io,
        root_close,
        .{ .success = .{ .file_close = {} } },
    ) == .registry_stopped);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
    const metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.failed)],
    );
}

test "FileSink canceled abort close bound enters fatal owner cleanup" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    try prepareMultipart(&storage);
    try driveBody(&controller, &storage, &io);

    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    inline for (0..8) |_| {
        const close = io.take();
        try std.testing.expect(close.operation == .file_close);
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = close.token,
            .result = .{ .failure = .canceled },
            .more = false,
        }) == .none);
        try std.testing.expectEqual(@as(u32, 1), sinkReport(&storage).live_anonymous);
        try std.testing.expectEqual(@as(u32, 2), controller.activeHandles());
    }

    const owner_close = io.take();
    try std.testing.expect(owner_close.operation == .file_close);
    try std.testing.expectError(error.ApplicationFailure, controller.complete(
        &storage,
        &io,
        .{
            .token = owner_close.token,
            .result = .{ .success = .{ .file_close = {} } },
            .more = false,
        },
    ));
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(@as(u32, 1), sinkReport(&storage).live_anonymous);
    try std.testing.expectEqual(
        @as(u64, 0),
        controller.metricsSnapshot().finalization_outcomes[
            @intFromEnum(upload_finalizer.Outcome.failed)
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        controller.metricsSnapshot().fatal_failures[
            @intFromEnum(worker_upload_metrics.FatalFailureClass.application)
        ],
    );
}

test "FileSink non-canceled abort close failure makes ownership unproven" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(3);
    try startRegistry(&controller, &storage, &io);
    try prepareMultipart(&storage);
    try driveBody(&controller, &storage, &io);

    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    const close = io.take();
    try std.testing.expect(close.operation == .file_close);
    try std.testing.expectError(error.TransportFailure, controller.complete(&storage, &io, .{
        .token = close.token,
        .result = .{ .failure = .io_failure },
        .more = false,
    }));
    try std.testing.expectEqual(@as(u8, 0), io.count);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 2), controller.activeHandles());
    try std.testing.expect(!controller.ownershipProven());
    try std.testing.expectEqual(@as(u32, 1), sinkReport(&storage).live_anonymous);
    try std.testing.expectEqual(
        @as(u64, 1),
        controller.metricsSnapshot().fatal_failures[
            @intFromEnum(worker_upload_metrics.FatalFailureClass.transport)
        ],
    );
}

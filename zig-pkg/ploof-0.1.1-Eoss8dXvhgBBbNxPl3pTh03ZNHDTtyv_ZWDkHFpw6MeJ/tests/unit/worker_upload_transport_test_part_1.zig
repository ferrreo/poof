const source = @import("worker_upload_transport_test.zig");
const std = source.std;
const application = source.application;
const endpoint = source.endpoint;
const multipart = source.multipart;
const multipart_finalization = source.multipart_finalization;
const application_types = source.application_types;
const multipart_parser = source.multipart_parser;
const upload_finalizer = source.upload_finalizer;
const upload_dispatch = source.upload_dispatch;
const reactor = source.reactor;
const upload_transport = source.upload_transport;
const worker_upload_transport = source.worker_upload_transport;
const upload_metrics = source.upload_metrics;
const response = source.response;
const route = source.route;
const Stage = source.Stage;
const GeneratedSink = source.GeneratedSink;
const GeneratedAsyncSink = source.GeneratedAsyncSink;
const GeneratedSyncSink = source.GeneratedSyncSink;
const GeneratedContext = source.GeneratedContext;
const GeneratedFileConsumer = source.GeneratedFileConsumer;
const generated_async_spec = source.generated_async_spec;
const GeneratedAsyncDefinition = source.GeneratedAsyncDefinition;
const generated_async_handler = source.generated_async_handler;
const generated_sync_spec = source.generated_sync_spec;
const GeneratedSyncDefinition = source.GeneratedSyncDefinition;
const generated_sync_handler = source.generated_sync_handler;
const generated_field_spec = source.generated_field_spec;
const GeneratedFieldDefinition = source.GeneratedFieldDefinition;
const GeneratedFieldConsumer = source.GeneratedFieldConsumer;
const generated_field_handler = source.generated_field_handler;
const GeneratedApp = source.GeneratedApp;
const TestApp = source.TestApp;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const generated_workspace_bytes = source.generated_workspace_bytes;
const GeneratedStorage = source.GeneratedStorage;
const GeneratedReactor = source.GeneratedReactor;
const GeneratedController = source.GeneratedController;
const generatedInput = source.generatedInput;
const beginGenerated = source.beginGenerated;
const startGeneratedSync = source.startGeneratedSync;
const generated_sync_wire = source.generated_sync_wire;
const Controller = source.Controller;
const expectFailureIdentity = source.expectFailureIdentity;
const expectFatalMetricIdentity = source.expectFatalMetricIdentity;
const runtimeOwner = source.runtimeOwner;
const seedDirectory = source.seedDirectory;

test "worker upload transport preserves request owner and lane across follow-up io" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(5);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x5a} ** 32),
    ) == .registry_ready);
    try seedDirectory(&controller, &storage, 5);

    _ = try controller.submitParserWork(&storage, &io, 0);
    const opened = io.take();
    const open_fields = try opened.token.fields();
    try std.testing.expectEqual(reactor.OperationKind.file_open, open_fields.kind);
    try std.testing.expectEqual(@as(u16, 5), open_fields.worker_index);
    try std.testing.expectEqual(@as(u16, 0), open_fields.slot_index);
    try std.testing.expectEqual(@as(u16, 9), open_fields.slot_generation);
    try std.testing.expectEqual(@as(u16, 11), open_fields.sequence);
    try std.testing.expect(storage.requests[0].flags.upload_inflight);
    try std.testing.expect(storage.requests[0].flags.upload_parser_paused);

    const follow = try controller.complete(&storage, &io, .{
        .token = opened.token,
        .result = .{ .success = .{ .file_open = .{ .value = 91 } } },
        .more = false,
    });
    try std.testing.expect(follow == .none);
    const closed = io.take();
    const close_fields = try closed.token.fields();
    try std.testing.expectEqual(reactor.OperationKind.file_close, close_fields.kind);
    try std.testing.expectEqual(@as(u16, 12), close_fields.sequence);
    try std.testing.expect(storage.requests[0].flags.upload_inflight);

    const event = try controller.complete(&storage, &io, .{
        .token = closed.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    });
    const resumed = event.request_resumed;
    try std.testing.expectEqual(@as(u16, 0), resumed.connection_index);
    try std.testing.expectEqual(@as(u16, 0), resumed.request_index);
    try std.testing.expectEqual(multipart_parser.Flow.ready, resumed.progress.flow);
    try std.testing.expectEqual(@as(u8, 2), storage.requests[0].workspace.completion_count);
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.resume_count);
    try std.testing.expect(!storage.requests[0].flags.upload_inflight);
    try std.testing.expect(!storage.requests[0].flags.upload_parser_paused);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

test "request submit failure retains exact sink identity" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(5);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x31} ** 32),
    ) == .registry_ready);
    try seedDirectory(&controller, &storage, 5);

    io.fail_next_submit = true;
    try std.testing.expectError(
        error.BackendFailure,
        controller.submitParserWork(&storage, &io, 0),
    );
    try expectFailureIdentity(&controller, 7, 3);
    try expectFatalMetricIdentity(&controller, 7, 3);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

test "request cancel submit failure retains exact sink identity" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(6);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x32} ** 32),
    ) == .registry_ready);
    try seedDirectory(&controller, &storage, 6);
    _ = try controller.submitParserWork(&storage, &io, 0);
    const opened = io.take();

    io.fail_next_submit = true;
    try std.testing.expectError(error.BackendFailure, controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ));
    try expectFailureIdentity(&controller, 7, 3);
    try expectFatalMetricIdentity(&controller, 7, 3);
    try std.testing.expectEqual(@as(u32, 1), controller.pending());

    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = opened.token,
        .result = .{ .success = .{ .file_open = .{ .value = 93 } } },
        .more = false,
    }) == .none);
    const closed = io.take();
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = closed.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    }) == .request_finalized);
    try std.testing.expect(controller.requests.failureIdentity() == null);
}

test "in-flight peer abort drains exact request io before finalization" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(6);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x6b} ** 32),
    ) == .registry_ready);
    try seedDirectory(&controller, &storage, 6);

    _ = try controller.submitParserWork(&storage, &io, 0);
    const opened = io.take();
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    try std.testing.expect(storage.requests[0].flags.upload_cancel_requested);
    const canceled = io.take();
    try std.testing.expect(canceled.operation == .upload_cancel);
    try std.testing.expect(canceled.operation.upload_cancel.target.eql(opened.token));

    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = canceled.token,
        .result = .{ .success = .{ .upload_cancel = .not_found } },
        .more = false,
    }) == .none);
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = opened.token,
        .result = .{ .success = .{ .file_open = .{ .value = 92 } } },
        .more = false,
    }) == .none);
    const closed = io.take();
    try std.testing.expectEqual(@as(i32, 92), closed.operation.file_close.file.value);
    const event = try controller.complete(&storage, &io, .{
        .token = closed.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    });
    const finalized = event.request_finalized;
    try std.testing.expectEqual(@as(u16, 0), finalized.connection_index);
    try std.testing.expect(finalized.response_failed);
    try std.testing.expect(finalized.report.primary.?.class == .upstream);
    try std.testing.expectEqual(
        upload_finalizer.UpstreamFailure.peer_disconnect,
        finalized.report.primary.?.class.upstream,
    );
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
}

test "synchronous abort stamps terminal generation before record and release" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(7);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x41} ** 32),
    ) == .registry_ready);
    storage.requests[0].workspace.stage = .done;
    storage.requests[0].workspace.cleanup_failure = true;

    const event = try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .framework_canceled,
    );
    try std.testing.expect(event == .request_finalized);
    try std.testing.expectEqual(
        storage.requests[0].generation,
        controller.finalization_generations[0],
    );
    try controller.recordFinalizationIfTerminal(&storage, 0);

    const snapshot = controller.metricsSnapshot();
    const failed = @intFromEnum(upload_finalizer.Outcome.failed);
    const cleanup = @intFromEnum(multipart_finalization.CleanupFailureClass.sink);
    try std.testing.expectEqual(@as(u64, 1), snapshot.finalization_outcomes[failed]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cleanup_failures[cleanup]);
    try std.testing.expectEqual(@as(u64, 2), snapshot.events_recorded);
    try std.testing.expectEqual(@as(?u16, 12), snapshot.events[0].route_id);
    try std.testing.expectEqual(@as(?u16, 12), snapshot.events[1].route_id);
    const route_snapshot = controller.routeMetricsSnapshot(12).?;
    try std.testing.expectEqual(
        snapshot.finalization_outcomes,
        route_snapshot.cell.finalization_outcomes,
    );
    try std.testing.expectEqual(snapshot.cleanup_failures, route_snapshot.cell.cleanup_failures);

    try controller.retireRequest(&storage, 0);
    try std.testing.expectEqual(@as(u16, 0), controller.finalization_generations[0]);
    try std.testing.expectEqual(@as(u64, 2), controller.metricsSnapshot().events_recorded);
}

test "enabled app terminal recording makes a later peer abort a no-op" {
    var storage = TestStorage{};
    var io = TestReactor{};
    var controller = try Controller.init(8);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x42} ** 32),
    ) == .registry_ready);
    storage.requests[0].workspace.stage = .done;
    storage.requests[0].workspace.multipart_finalization = .committed;

    try controller.recordFinalizationIfTerminal(&storage, 0);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    try controller.recordFinalizationIfTerminal(&storage, 0);

    const snapshot = controller.metricsSnapshot();
    const committed = @intFromEnum(upload_finalizer.Outcome.committed);
    try std.testing.expectEqual(@as(u64, 1), snapshot.finalization_outcomes[committed]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.events_recorded);
    for (snapshot.fatal_failures) |count| {
        try std.testing.expectEqual(@as(u64, 0), count);
    }
    try std.testing.expect(storage.requests[0].workspace.cancel_cause == null);
    try std.testing.expectEqual(@as(u8, 0), io.submit_count);
    try std.testing.expect(controller.requests.store.states[0].finalized);
    const route_snapshot = controller.routeMetricsSnapshot(12).?;
    try std.testing.expectEqual(
        snapshot.finalization_outcomes,
        route_snapshot.cell.finalization_outcomes,
    );
}

test "generated mixed app records a synchronous route without worker io" {
    try std.testing.expectEqual(@as(usize, 1), GeneratedApp.upload_route_profiles.len);
    try std.testing.expectEqual(@as(u16, 0), GeneratedApp.upload_route_profiles[0].route_id);
    try std.testing.expectEqual(@as(u8, 4), GeneratedApp.upload_route_profiles[0].window);

    var storage = GeneratedStorage{};
    var io = GeneratedReactor{};
    var state: void = {};
    var output: [512]u8 = undefined;
    var gzip = GeneratedApp.ResponseGzipWorkspace{};
    try startGeneratedSync(&storage);
    try beginGenerated(&storage, &state, &output, "/sync");
    try GeneratedApp.__feedMultipart(
        &storage.requests[0].workspace,
        &storage.body,
        generated_sync_wire,
    );
    try GeneratedApp.__finishMultipart(&storage.requests[0].workspace, &storage.body);
    _ = try GeneratedApp.__prepareBodyWithResponseGzip(
        &storage.requests[0].workspace,
        .none,
        .{},
        &storage.body,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(
        .complete,
        try GeneratedApp.__startMultipartFinalization(
            &storage.requests[0].workspace,
            &storage.body,
        ),
    );

    var controller = try GeneratedController.init(0);
    controller.phase = .ready;
    try controller.recordFinalizationIfTerminal(&storage, 0);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);

    const snapshot = controller.metricsSnapshot();
    const committed = @intFromEnum(upload_finalizer.Outcome.committed);
    try std.testing.expectEqual(@as(u64, 1), snapshot.finalization_outcomes[committed]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.events_recorded);
    try std.testing.expectEqual(@as(?u16, 1), snapshot.events[0].route_id);
    try std.testing.expectEqual(@as(u8, 0), io.submit_count);
    try std.testing.expect(controller.routeMetricsSnapshot(1) == null);
    try std.testing.expect(controller.requests.store.states[0].route_captured);
    try std.testing.expectEqual(
        @as(u8, 0),
        controller.requests.store.states[0].route_window,
    );
}

test "generated synchronous route abort finalizes without worker io" {
    var storage = GeneratedStorage{};
    var io = GeneratedReactor{};
    var state: void = {};
    var output: [512]u8 = undefined;
    try startGeneratedSync(&storage);
    try beginGenerated(&storage, &state, &output, "/sync");
    try GeneratedApp.__feedMultipart(
        &storage.requests[0].workspace,
        &storage.body,
        generated_sync_wire,
    );
    try GeneratedApp.__finishMultipart(&storage.requests[0].workspace, &storage.body);

    var controller = try GeneratedController.init(0);
    controller.phase = .ready;
    const event = try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    );
    try std.testing.expect(event == .request_finalized);
    const finalized = event.request_finalized;
    const snapshot = controller.metricsSnapshot();
    const outcome = @intFromEnum(finalized.report.outcome);
    try std.testing.expectEqual(@as(u64, 1), snapshot.finalization_outcomes[outcome]);
    try std.testing.expectEqual(@as(u64, 1), snapshot.events_recorded);
    try std.testing.expectEqual(@as(?u16, 1), snapshot.events[0].route_id);
    try std.testing.expectEqual(@as(u8, 0), io.submit_count);
    try std.testing.expect(controller.routeMetricsSnapshot(1) == null);
    try std.testing.expect(controller.requests.store.states[0].route_captured);
    try std.testing.expectEqual(
        @as(u8, 0),
        controller.requests.store.states[0].route_window,
    );
    for (snapshot.fatal_failures) |count| {
        try std.testing.expectEqual(@as(u64, 0), count);
    }
}

test "generated field-only route bypasses upload abort before route capture" {
    var storage = GeneratedStorage{};
    var io = GeneratedReactor{};
    var state: void = {};
    var output: [512]u8 = undefined;
    try beginGenerated(&storage, &state, &output, "/field");
    try std.testing.expectEqual(
        .not_required,
        storage.requests[0].workspace.multipart_finalization,
    );

    var controller = try GeneratedController.init(0);
    controller.phase = .ready;
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    const snapshot = controller.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), snapshot.events_recorded);
    try std.testing.expectEqual(@as(u8, 0), io.submit_count);
    try std.testing.expect(!controller.requests.store.states[0].route_captured);
    for (snapshot.fatal_failures) |count| {
        try std.testing.expectEqual(@as(u64, 0), count);
    }
}

test "disabled upload controller needs no reactor upload capacity" {
    const NoUploadApp = struct {
        pub const upload_async_sink_present = false;
    };
    const PlainReactor = struct {};
    const Plain = worker_upload_transport.Controller(NoUploadApp, void, PlainReactor);
    var controller = try Plain.init(0);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expect(controller.routeMetricsSnapshot(0) == null);
}

test "synchronous upload finalization records once without an upload CQE" {
    const SyncApp = struct {
        pub const upload_async_sink_present = false;
        pub const upload_request_handles_max: u32 = 0;
        pub const upload_finalization_instances_max: u16 = 1;

        pub fn __multipartFinalizationReport(
            _: *@This().Workspace,
            _: []u8,
        ) error{}!?multipart_finalization.Report {
            return .{
                .outcome = .committed,
                .primary = null,
                .instance_count = 0,
                .commit_attempted_count = 1,
                .commit_completed_count = 1,
                .abort_attempted_count = 0,
                .abort_completed_count = 0,
                .cleanup_failure_count = 0,
            };
        }

        pub const Workspace = struct {
            multipart_finalization: application_types.MultipartFinalization = .committed,
        };
    };
    const SyncStorage = struct {
        pub const runtime_limits = struct {
            pub const request_slots: usize = 1;
        };
        pub const Request = struct {
            generation: u16 = 4,
            workspace: SyncApp.Workspace = .{},
        };

        requests: [1]Request = .{.{}},
        workspace: [1]u8 = .{0},

        pub fn bodyWorkspace(self: *@This(), _: u16) ![]u8 {
            return &self.workspace;
        }
    };
    const SyncController = worker_upload_transport.Controller(SyncApp, SyncStorage, void);
    var storage = SyncStorage{};
    var controller = try SyncController.init(0);
    try controller.recordFinalizationIfTerminal(&storage, 0);
    try controller.recordFinalizationIfTerminal(&storage, 0);
    var snapshot = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.committed)],
    );
    try std.testing.expectEqual(@as(u64, 1), snapshot.commit_attempted);
    try std.testing.expectEqual(@as(u64, 1), snapshot.commit_completed);

    try controller.retireRequest(&storage, 0);
    try controller.recordFinalizationIfTerminal(&storage, 0);
    snapshot = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 2),
        snapshot.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.committed)],
    );
    try std.testing.expectEqual(@as(u64, 2), snapshot.commit_attempted);
    try std.testing.expectEqual(@as(u64, 2), snapshot.commit_completed);
}

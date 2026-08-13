const std = @import("std");

const multipart = @import("../../src/multipart.zig");
const finalization = @import("../../src/internal/application/multipart_finalization.zig");
const parser = @import("../../src/internal/multipart/parser.zig");
const upload_dispatch = @import("../../src/internal/application/multipart_upload_dispatch.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const upload_transport = @import("../../src/internal/runtime/upload/transport.zig");
const worker_upload = @import("../../src/internal/runtime/worker/upload_transport.zig");
const worker_upload_metrics = @import("../../src/internal/runtime/worker/upload_metrics.zig");

const lanes = 4;

const App = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max: u32 = 1;
    pub const upload_window_max: u32 = lanes;
    pub const upload_route_profiles = [_]struct { route_id: u16, window: u8 }{
        .{ .route_id = 0, .window = 4 },
        .{ .route_id = 7, .window = 1 },
    };
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{};
    };

    pub const Workspace = struct {
        route_id: u16 = 0,
        file: multipart.FileHandle = .{ .token = 0 },
        pending: u16 = 0b1111,
        submitted: u16 = 0,
        completed: u16 = 0,
        canceled: u16 = 0,
        remaining: [lanes]u8 = @splat(4),
        offsets: [lanes]u64 = @splat(0),
        resume_count: u8 = 0,
        finalization_starts: u8 = 0,
        cancel_cause: ?upload_finalizer.UpstreamFailure = null,
    };

    pub fn __multipartUploadRouteId(workspace: *Workspace) error{}!u16 {
        return workspace.route_id;
    }

    pub fn __peekUploadSubmission(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!?upload_dispatch.Submission {
        if (workspace.pending == 0) return null;
        const lane: u8 = @intCast(@ctz(workspace.pending));
        return .{
            .lane = .{ .write = lane },
            .request = .{ .write = .{
                .file = workspace.file,
                .bytes = "data"[0..workspace.remaining[lane]],
                .offset = workspace.offsets[lane],
            } },
            .registry_index = 7,
            .instance_index = 0,
        };
    }

    pub fn __markUploadSubmitted(
        workspace: *Workspace,
        _: []u8,
        lane: upload_dispatch.Lane,
    ) error{TestFailure}!void {
        const slot = writeLane(lane) orelse return error.TestFailure;
        const bit = laneBit(slot);
        if (workspace.pending & bit == 0 or workspace.submitted & bit != 0) {
            return error.TestFailure;
        }
        workspace.pending &= ~bit;
        workspace.submitted |= bit;
    }

    pub fn __completeUploadSubmission(
        workspace: *Workspace,
        _: []u8,
        lane: upload_dispatch.Lane,
        completion: multipart.IoCompletion,
    ) error{TestFailure}!void {
        const slot = writeLane(lane) orelse return error.TestFailure;
        const bit = laneBit(slot);
        if (workspace.submitted & bit == 0) return error.TestFailure;
        workspace.submitted &= ~bit;
        const written = switch (completion) {
            .failure => 0,
            .success => |success| switch (success) {
                .write => |count| count,
                else => return error.TestFailure,
            },
        };
        if (written != 0 and written < workspace.remaining[slot]) {
            workspace.remaining[slot] -= @intCast(written);
            workspace.offsets[slot] += written;
            workspace.pending |= bit;
            return;
        }
        workspace.completed |= bit;
    }

    pub fn __completeCanceledUploadSubmission(
        workspace: *Workspace,
        _: []u8,
        lane: upload_dispatch.Lane,
    ) error{TestFailure}!void {
        const slot = writeLane(lane) orelse return error.TestFailure;
        const bit = laneBit(slot);
        if (workspace.submitted & bit == 0) return error.TestFailure;
        workspace.submitted &= ~bit;
        workspace.completed |= bit;
        workspace.canceled |= bit;
    }

    pub fn __resumeMultipart(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!parser.Progress {
        workspace.resume_count += 1;
        return .{
            .consumed = 0,
            .flow = if (workspace.pending != 0 or workspace.submitted != 0)
                .paused
            else
                .ready,
        };
    }

    pub fn __cancelMultipart(
        workspace: *Workspace,
        cause: upload_finalizer.UpstreamFailure,
    ) error{TestFailure}!void {
        workspace.cancel_cause = cause;
    }

    pub fn __startMultipartFinalization(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.FinalizationFlow {
        workspace.finalization_starts += 1;
        return .complete;
    }

    pub fn __multipartFinalizationFlow(
        _: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.FinalizationFlow {
        return .complete;
    }

    pub fn __multipartFinalizationReport(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!?finalization.Report {
        return report(workspace.cancel_cause);
    }

    pub fn __multipartTerminalSource(
        _: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.TerminalSource {
        return .fatal;
    }
};

const Storage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    const Phase = enum(u8) { free, live };
    pub const Connection = struct { active_request: ?u16 = 0 };
    const Flags = packed struct(u8) {
        response_dirty_full: bool = false,
        upload_inflight: bool = false,
        upload_parser_paused: bool = false,
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
        upload_cancel_requested: bool = false,
        upload_cancel_peer: bool = false,
        upload_rejection_pending: bool = false,
    };
    pub const Request = struct {
        phase: Phase = .live,
        generation: u16 = 4,
        sequence: u16 = 20,
        connection_index: u16 = 0,
        flags: Flags = .{},
        workspace: App.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *Storage, index: u16) error{Invalid}![]u8 {
        if (index != 0) return error.Invalid;
        return &self.body;
    }
};

const TestReactor = struct {
    pub const file_handle_capacity = 8;
    pub const file_target_capacity = lanes;

    submissions: [16]reactor.Submission = undefined,
    count: u8 = 0,

    pub fn submit(self: *TestReactor, submission: reactor.Submission) error{Full}!void {
        if (self.count == self.submissions.len) return error.Full;
        self.submissions[self.count] = submission;
        self.count += 1;
    }

    fn take(self: *TestReactor) reactor.Submission {
        const result = self.submissions[0];
        self.count -= 1;
        std.mem.copyForwards(
            reactor.Submission,
            self.submissions[0..self.count],
            self.submissions[1..][0..self.count],
        );
        return result;
    }
};

const Controller = worker_upload.Controller(App, Storage, TestReactor);

test "configured upload window submits four lanes and follows a short write" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try readyController(&storage, &io, 3);
    storage.requests[0].workspace.file = try seedFile(&controller, &storage, 3, 90);

    _ = try controller.submitParserWorkAt(&storage, &io, 0, 100);
    try std.testing.expectEqual(@as(u8, lanes), io.count);
    try std.testing.expectEqual(@as(u32, lanes), controller.pending());
    var targets: [lanes]reactor.Submission = undefined;
    for (&targets) |*target| target.* = io.take();
    try expectDistinctSequences(targets);

    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[3].token,
        2,
        150,
    ) == .none);
    const followup = io.take();
    try std.testing.expectEqual(@as(u64, 2), followup.operation.file_write.offset);
    try std.testing.expectEqual(@as(usize, 2), followup.operation.file_write.bytes.len);
    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[2].token,
        4,
        160,
    ) == .none);
    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[1].token,
        4,
        170,
    ) == .none);
    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[0].token,
        4,
        180,
    ) == .none);
    const event = try completeWriteAt(
        &controller,
        &storage,
        &io,
        followup.token,
        2,
        200,
    );
    try std.testing.expect(event == .request_resumed);
    try std.testing.expectEqual(@as(u16, 0b1111), storage.requests[0].workspace.completed);
    try std.testing.expect(!storage.requests[0].flags.upload_inflight);
    try std.testing.expect(!storage.requests[0].flags.upload_parser_paused);
    const metrics = controller.metricsSnapshot();
    const write_index = @intFromEnum(multipart.IoKind.write);
    try std.testing.expectEqual(@as(u64, 1), metrics.window_full_count);
    try std.testing.expectEqual(@as(u64, 100), metrics.window_full_duration_ns_total);
    try std.testing.expectEqual(@as(u64, 5), metrics.sink_operation_count[write_index]);
    try std.testing.expectEqual(
        @as(u64, 310),
        metrics.sink_operation_latency_ns_total[write_index],
    );
}

test "route windows share one sink and metrics retain captured route across reuse" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try readyController(&storage, &io, 6);
    storage.requests[0].workspace.route_id = 7;
    storage.requests[0].workspace.file = try seedFile(&controller, &storage, 6, 93);

    _ = try controller.submitParserWorkAt(&storage, &io, 0, 100);
    try std.testing.expectEqual(@as(u8, 1), io.count);
    var now_ns: u64 = 130;
    for (0..lanes) |index| {
        const target = io.take();
        const event = try completeWriteAt(
            &controller,
            &storage,
            &io,
            target.token,
            4,
            now_ns,
        );
        if (index + 1 == lanes) {
            try std.testing.expect(event == .request_resumed);
            try std.testing.expectEqual(@as(u8, 0), io.count);
        } else {
            try std.testing.expect(event == .none);
            try std.testing.expectEqual(@as(u8, 1), io.count);
        }
        now_ns += 10;
    }

    const narrow = controller.routeMetricsSnapshot(7).?;
    const wide_before = controller.routeMetricsSnapshot(0).?;
    const write = @intFromEnum(multipart.IoKind.write);
    try std.testing.expectEqual(@as(u16, 6), narrow.worker_index);
    try std.testing.expectEqual(@as(u16, 7), narrow.route_id);
    try std.testing.expectEqual(@as(u8, 1), narrow.window);
    try std.testing.expectEqual(@as(u64, 1), narrow.cell.window_full_count);
    try std.testing.expectEqual(@as(u64, lanes), narrow.cell.sink_operation_count[write]);
    try std.testing.expectEqual(@as(u64, 0), wide_before.cell.sink_operation_count[write]);

    try controller.retireRequest(&storage, 0);
    storage.requests[0].generation = 5;
    storage.requests[0].sequence = 40;
    storage.requests[0].workspace = .{};
    storage.requests[0].workspace.file = try seedFile(&controller, &storage, 6, 94);
    _ = try controller.submitParserWorkAt(&storage, &io, 0, 300);
    try std.testing.expectEqual(@as(u8, lanes), io.count);
    const target = io.take();
    storage.requests[0].workspace.route_id = 7;
    try std.testing.expect(try completeFailureAt(
        &controller,
        &storage,
        &io,
        target.token,
        350,
    ) == .none);

    const wide = controller.routeMetricsSnapshot(0).?;
    const aggregate = controller.metricsSnapshot();
    const canceled = @intFromEnum(worker_upload_metrics.RecoverableFailureClass.canceled);
    try std.testing.expectEqual(@as(u8, 4), wide.window);
    try std.testing.expectEqual(@as(u64, 1), wide.cell.sink_operation_count[write]);
    try std.testing.expectEqual(@as(u64, 1), wide.cell.recoverable_failures[canceled]);
    try std.testing.expectEqual(
        narrow.cell.sink_operation_count[write] + wide.cell.sink_operation_count[write],
        aggregate.sink_operation_count[write],
    );
    try std.testing.expectEqual(
        narrow.cell.recoverable_failures[canceled] + wide.cell.recoverable_failures[canceled],
        aggregate.recoverable_failures[canceled],
    );
    try std.testing.expectEqual(@as(?u16, 0), aggregate.events[0].route_id);
}

test "abort cancels every lane and reaps target cancel pairs in either order" {
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try readyController(&storage, &io, 4);
    storage.requests[0].workspace.file = try seedFile(&controller, &storage, 4, 91);
    _ = try controller.submitParserWorkAt(&storage, &io, 0, 100);
    var targets: [lanes]reactor.Submission = undefined;
    for (&targets) |*target| target.* = io.take();

    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    try std.testing.expectEqual(@as(u8, lanes), io.count);
    var cancels: [lanes]reactor.Submission = undefined;
    for (&cancels) |*cancel| {
        cancel.* = io.take();
        try std.testing.expect(cancel.operation == .upload_cancel);
    }
    try expectCancelTargets(targets, cancels);

    try std.testing.expect(try completeCancelAt(
        &controller,
        &storage,
        &io,
        cancels[0].token,
        .canceled,
        120,
    ) == .none);
    try std.testing.expect(try completeFailureAt(
        &controller,
        &storage,
        &io,
        targets[0].token,
        130,
    ) == .none);
    try std.testing.expect(try completeFailureAt(
        &controller,
        &storage,
        &io,
        targets[1].token,
        140,
    ) == .none);
    try std.testing.expect(try completeCancelAt(
        &controller,
        &storage,
        &io,
        cancels[1].token,
        .canceled,
        200,
    ) == .none);
    try std.testing.expect(try completeCancelAt(
        &controller,
        &storage,
        &io,
        cancels[2].token,
        .not_found,
        150,
    ) == .none);
    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[2].token,
        4,
        160,
    ) == .none);
    try std.testing.expect(try completeWriteAt(
        &controller,
        &storage,
        &io,
        targets[3].token,
        4,
        170,
    ) == .none);
    const waiting = try completeCancelAt(
        &controller,
        &storage,
        &io,
        cancels[3].token,
        .not_found,
        220,
    );
    try std.testing.expect(waiting == .none);
    try std.testing.expectError(
        error.StateInvariant,
        controller.retireRequest(&storage, 0),
    );
    const cleanup = io.take();
    const event = try controller.completeAt(&storage, &io, .{
        .token = cleanup.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    }, 230);
    try std.testing.expect(event == .request_finalized);
    try std.testing.expect(event.request_finalized.response_failed);
    const report_value = event.request_finalized.report;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report_value.outcome);
    try std.testing.expectEqual(@as(u32, 0), report_value.cleanup_failure_count);
    const primary = report_value.primary orelse return error.TestUnexpectedResult;
    try std.testing.expect(primary.identity == null);
    switch (primary.class) {
        .upstream => |cause| try std.testing.expectEqual(
            upload_finalizer.UpstreamFailure.peer_disconnect,
            cause,
        ),
        .sink => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.finalization_starts);
    try std.testing.expectEqual(@as(u16, 0b0011), storage.requests[0].workspace.canceled);
    try std.testing.expectEqual(@as(u16, 0b1111), storage.requests[0].workspace.completed);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    const metrics = controller.metricsSnapshot();
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, 0),
        metrics.recoverable_failures[
            @intFromEnum(worker_upload_metrics.RecoverableFailureClass.canceled)
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        metrics.cancellations[
            @intFromEnum(
                worker_upload_metrics.CancellationOutcome.target_canceled,
            )
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        metrics.cancellations[
            @intFromEnum(
                worker_upload_metrics.CancellationOutcome.target_completed,
            )
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.failed)],
    );
    const write_index = @intFromEnum(multipart.IoKind.write);
    try std.testing.expectEqual(@as(u64, 4), metrics.sink_operation_count[write_index]);
    try std.testing.expectEqual(
        @as(u64, 200),
        metrics.sink_operation_latency_ns_total[write_index],
    );
    const route_metrics = controller.routeMetricsSnapshot(0).?;
    try std.testing.expectEqual(metrics.cancellations, route_metrics.cell.cancellations);
    try std.testing.expectEqual(
        metrics.finalization_outcomes,
        route_metrics.cell.finalization_outcomes,
    );
    for (metrics.events[0..metrics.event_count]) |metric_event| {
        try std.testing.expectEqual(@as(?u16, 0), metric_event.route_id);
    }
}

fn readyController(storage: *Storage, io: *TestReactor, worker: u16) !Controller {
    var controller = try Controller.init(worker);
    try std.testing.expect(try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{0x33} ** 32),
    ) == .registry_ready);
    return controller;
}

fn seedFile(
    controller: *Controller,
    storage: *Storage,
    worker: u16,
    raw_fd: i32,
) !multipart.FileHandle {
    const owner = requestOwner(worker, &storage.requests[0], 0);
    const handle = try controller.transport.table().reserveOpen(owner);
    try controller.transport.table().completeOpenPositive(
        handle,
        owner,
        raw_fd,
        .file,
        .write_only,
        .none,
    );
    return handle;
}

fn requestOwner(
    worker: u16,
    request: *const Storage.Request,
    instance: u16,
) upload_transport.Owner {
    return .{
        .scope = .request,
        .registry_index = 7,
        .instance_index = instance,
        .slot = .{
            .worker_index = worker,
            .index = 0,
            .generation = request.generation,
        },
    };
}

fn completeWrite(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
    written: u32,
) !worker_upload.Event {
    return completeWriteAt(controller, storage, io, token, written, 0);
}

fn completeWriteAt(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
    written: u32,
    now_ns: u64,
) !worker_upload.Event {
    return controller.completeAt(storage, io, .{
        .token = token,
        .result = .{ .success = .{ .file_write = written } },
        .more = false,
    }, now_ns);
}

fn completeFailure(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
) !worker_upload.Event {
    return completeFailureAt(controller, storage, io, token, 0);
}

fn completeFailureAt(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
    now_ns: u64,
) !worker_upload.Event {
    return controller.completeAt(storage, io, .{
        .token = token,
        .result = .{ .failure = .canceled },
        .more = false,
    }, now_ns);
}

fn completeCancel(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
    result: reactor.CancelResult,
) !worker_upload.Event {
    return completeCancelAt(controller, storage, io, token, result, 0);
}

fn completeCancelAt(
    controller: *Controller,
    storage: *Storage,
    io: *TestReactor,
    token: reactor.OperationToken,
    result: reactor.CancelResult,
    now_ns: u64,
) !worker_upload.Event {
    return controller.completeAt(storage, io, .{
        .token = token,
        .result = .{ .success = .{ .upload_cancel = result } },
        .more = false,
    }, now_ns);
}

fn expectDistinctSequences(targets: [lanes]reactor.Submission) !void {
    var seen: u64 = 0;
    for (targets) |target| {
        const sequence = (try target.token.fields()).sequence;
        const bit = @as(u64, 1) << @intCast(sequence - 20);
        try std.testing.expect(seen & bit == 0);
        seen |= bit;
    }
}

fn expectCancelTargets(
    targets: [lanes]reactor.Submission,
    cancels: [lanes]reactor.Submission,
) !void {
    for (targets) |target| {
        var found = false;
        for (cancels) |cancel| {
            found = found or cancel.operation.upload_cancel.target.eql(target.token);
        }
        try std.testing.expect(found);
    }
}

fn writeLane(lane: upload_dispatch.Lane) ?u8 {
    return switch (lane) {
        .write => |slot| if (slot < lanes) slot else null,
        .lifecycle => null,
    };
}

fn laneBit(lane: u8) u16 {
    return @as(u16, 1) << @intCast(lane);
}

fn report(cause: ?upload_finalizer.UpstreamFailure) finalization.Report {
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

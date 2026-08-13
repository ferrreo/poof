const split = @import("worker_upload_transport_runtime_fuzz_support.zig");
pub const std = @import("std");

pub const multipart = @import("../src/multipart.zig");
pub const finalization = @import("../src/internal/application/multipart_finalization.zig");
pub const parser = @import("../src/internal/multipart/parser.zig");
pub const upload_dispatch = @import("../src/internal/application/multipart_upload_dispatch.zig");
pub const upload_finalizer = @import("../src/internal/upload/finalizer.zig");
pub const upload_sink_driver = @import("../src/internal/upload/sink_driver.zig");
pub const reactor = @import("../src/internal/runtime/reactor.zig");
pub const upload_transport = @import("../src/internal/runtime/upload/transport.zig");
pub const worker_upload = @import("../src/internal/runtime/worker/upload_transport.zig");
pub const upload_metrics = @import("../src/internal/runtime/worker/upload_metrics.zig");
pub const runtime_fuzz = @import("internal/runtime/worker_upload_runtime_fuzz_support.zig");
pub const lanes = 4;
pub const paths = [_][:0]const u8{ "a", "b", "c", "d" };
pub const Behavior = enum(u8) { normal, sink_failure, fatal, parser_failure };
pub const RequestApp = struct {
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
        directory: multipart.FileHandle = .{ .token = 0 },
        pending: u16 = 1,
        submitted: u16 = 0,
        behavior: Behavior = .normal,
        failure_raised: bool = false,
        terminal: upload_dispatch.TerminalSource = .none,
        cancel_cause: ?upload_finalizer.UpstreamFailure = null,
        finalization_count: u8 = 0,
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
            .request = .{ .unlink = .{
                .directory = workspace.directory,
                .path = paths[lane],
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
        const index = writeLane(lane) orelse return error.TestFailure;
        const bit = laneBit(index);
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
    ) error{ TestFailure, InvalidMultipart }!void {
        const index = writeLane(lane) orelse return error.TestFailure;
        const bit = laneBit(index);
        if (workspace.submitted & bit == 0) return error.TestFailure;
        workspace.submitted &= ~bit;
        if (!workspace.failure_raised and workspace.behavior != .normal) {
            workspace.failure_raised = true;
            workspace.terminal = switch (workspace.behavior) {
                .sink_failure => .sink,
                .fatal => .fatal,
                .parser_failure => .parser,
                .normal => unreachable,
            };
            if (workspace.behavior == .sink_failure and
                (completion != .failure or completion.failure != .no_space))
            {
                return error.TestFailure;
            }
            return if (workspace.behavior == .parser_failure)
                error.InvalidMultipart
            else
                error.TestFailure;
        }
    }

    pub fn __resumeMultipart(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!parser.Progress {
        return .{
            .consumed = 0,
            .flow = if (workspace.pending == 0 and workspace.submitted == 0)
                .ready
            else
                .paused,
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
        workspace.finalization_count += 1;
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
        return requestReport(workspace.cancel_cause);
    }

    pub fn __multipartTerminalSource(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.TerminalSource {
        return workspace.terminal;
    }
};
pub const RequestStorage = struct {
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
        generation: u16 = 1,
        sequence: u16 = 1,
        connection_index: u16 = 0,
        flags: Flags = .{},
        workspace: RequestApp.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *@This(), index: u16) error{Invalid}![]u8 {
        if (index != 0) return error.Invalid;
        return &self.body;
    }
};
pub const TestReactor = struct {
    pub const file_handle_capacity = 8;
    pub const file_target_capacity = 8;

    submissions: [16]reactor.Submission = undefined,
    count: u8 = 0,
    fail_next_submit: bool = false,

    pub fn submit(self: *@This(), submission: reactor.Submission) error{Full}!void {
        if (self.fail_next_submit) {
            self.fail_next_submit = false;
            return error.Full;
        }
        if (self.count == self.submissions.len) return error.Full;
        self.submissions[self.count] = submission;
        self.count += 1;
    }

    pub fn take(self: *@This()) reactor.Submission {
        const submission = self.submissions[0];
        self.count -= 1;
        std.mem.copyForwards(
            reactor.Submission,
            self.submissions[0..self.count],
            self.submissions[1..][0..self.count],
        );
        return submission;
    }

    pub fn takeKind(self: *@This(), kind: reactor.OperationKind) reactor.Submission {
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
pub const RequestController = worker_upload.Controller(RequestApp, RequestStorage, TestReactor);

pub const RequestOutcome = struct {
    resumed: u8 = 0,
    finalized: u8 = 0,
    fatal: u8 = 0,
};

pub fn expectParserRejectionTerminal(
    controller: *RequestController,
    storage: *RequestStorage,
    event: worker_upload.Event,
) !void {
    const finalized = event.request_finalized;
    try std.testing.expectEqual(finalization.Outcome.failed, finalized.report.outcome);
    try std.testing.expectEqual(
        upload_finalizer.UpstreamFailure.body,
        finalized.report.primary.?.class.upstream,
    );
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.finalization_count);
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    const metrics = controller.metricsSnapshot();
    for (metrics.fatal_failures) |count| try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(
        @as(u64, lanes - 1),
        metrics.cancellations[@intFromEnum(upload_metrics.CancellationOutcome.target_canceled)],
    );
}

pub fn runRequestSchedule(smith: *std.testing.Smith) !void {
    const behavior: Behavior = @enumFromInt(smith.valueRangeAtMost(u8, 0, 2));
    const route_id: u16 = if (smith.value(bool)) 0 else 7;
    const route_window: u8 = if (route_id == 0) lanes else 1;
    const lane_count = smith.valueRangeAtMost(u8, 1, route_window);
    const generation = smith.valueRangeAtMost(u16, 1, 60_000);
    var storage = RequestStorage{};
    storage.requests[0].generation = generation;
    storage.requests[0].sequence = smith.valueRangeAtMost(u16, 1, reactor.max_sequence);
    storage.requests[0].workspace.behavior = behavior;
    storage.requests[0].workspace.route_id = route_id;
    storage.requests[0].workspace.pending = (@as(u16, 1) << @intCast(lane_count)) - 1;
    var io = TestReactor{};
    var controller = try RequestController.init(3);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x5a} ** 32),
    ) == .registry_ready);
    storage.requests[0].workspace.directory = try seedDirectory(&controller, generation);
    _ = try controller.submitParserWorkAt(&storage, &io, 0, 10);

    var targets: [lanes]reactor.Submission = undefined;
    for (0..lane_count) |lane| {
        targets[lane] = io.take();
        const fields = try targets[lane].token.fields();
        try std.testing.expectEqual(generation, fields.slot_generation);
        try std.testing.expectEqualStrings(paths[lane], targets[lane].operation.file_unlink.path);
    }
    for (lane_count..lanes) |lane| targets[lane] = targets[0];
    var active_targets: u16 = (@as(u16, 1) << @intCast(lane_count)) - 1;
    var outcome = RequestOutcome{};
    if (behavior != .normal) {
        const lane = smith.valueRangeAtMost(u8, 0, lane_count - 1);
        active_targets &= ~laneBit(lane);
        try applyRequestCompletion(
            &controller,
            &storage,
            &io,
            targets[lane].token,
            if (behavior == .sink_failure)
                .{ .failure = .no_space }
            else
                .{ .success = .{ .file_unlink = {} } },
            behavior,
            &outcome,
        );
    } else if (smith.value(bool)) {
        try std.testing.expect(try controller.beginRequestAbort(
            &storage,
            &io,
            0,
            .peer_disconnect,
        ) == .none);
    }
    try drainRequestSchedule(
        smith,
        &controller,
        &storage,
        &io,
        targets,
        active_targets,
        behavior,
        &outcome,
    );
    try expectRequestOutcome(&controller, &storage, behavior, outcome);
}

pub fn drainRequestSchedule(
    smith: *std.testing.Smith,
    controller: *RequestController,
    storage: *RequestStorage,
    io: *TestReactor,
    targets: [lanes]reactor.Submission,
    initial_targets: u16,
    behavior: Behavior,
    outcome: *RequestOutcome,
) !void {
    var cancels: [lanes]?reactor.Submission = @splat(null);
    var active_cancels: u16 = 0;
    while (io.count != 0) {
        const cancel = io.take();
        const lane = targetLane(targets, cancel.operation.upload_cancel.target) orelse {
            return error.TestUnexpectedResult;
        };
        cancels[lane] = cancel;
        active_cancels |= laneBit(lane);
    }
    var active_targets = initial_targets;
    var canceled_targets: u16 = 0;
    while (active_targets != 0 or active_cancels != 0) {
        const choose_cancel = active_cancels != 0 and
            (active_targets == 0 or smith.value(bool));
        if (choose_cancel) {
            const lane = chooseLane(smith, active_cancels);
            const target_active = active_targets & laneBit(lane) != 0;
            try applyRequestCompletion(
                controller,
                storage,
                io,
                cancels[lane].?.token,
                .{ .success = .{ .upload_cancel = if (target_active)
                    .canceled
                else
                    .not_found } },
                behavior,
                outcome,
            );
            active_cancels &= ~laneBit(lane);
            if (target_active) canceled_targets |= laneBit(lane);
        } else {
            const lane = chooseLane(smith, active_targets);
            try applyRequestCompletion(
                controller,
                storage,
                io,
                targets[lane].token,
                if (canceled_targets & laneBit(lane) != 0)
                    .{ .failure = .canceled }
                else
                    .{ .success = .{ .file_unlink = {} } },
                behavior,
                outcome,
            );
            active_targets &= ~laneBit(lane);
        }
    }
    try std.testing.expectEqual(@as(u8, 0), io.count);
}

pub fn applyRequestCompletion(
    controller: *RequestController,
    storage: *RequestStorage,
    io: *TestReactor,
    token: reactor.OperationToken,
    result: reactor.CompletionResult,
    behavior: Behavior,
    outcome: *RequestOutcome,
) !void {
    const event = controller.completeAt(storage, io, .{
        .token = token,
        .result = result,
        .more = false,
    }, 20) catch |problem| {
        if (behavior != .fatal or problem != error.ApplicationFailure or outcome.fatal != 0) {
            return problem;
        }
        outcome.fatal = 1;
        return;
    };
    switch (event) {
        .none => {},
        .request_resumed => outcome.resumed += 1,
        .request_finalized => outcome.finalized += 1,
        .registry_ready, .registry_stopped, .request_rejected => {
            return error.TestUnexpectedResult;
        },
    }
}

pub fn expectRequestOutcome(
    controller: *RequestController,
    storage: *RequestStorage,
    behavior: Behavior,
    outcome: RequestOutcome,
) !void {
    const aborted = storage.requests[0].workspace.cancel_cause != null;
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    if (behavior == .fatal) {
        try std.testing.expectEqual(@as(u8, 1), outcome.fatal);
        try std.testing.expectEqual(@as(u8, 0), outcome.finalized);
    } else if (behavior == .sink_failure or aborted) {
        try std.testing.expectEqual(@as(u8, 1), outcome.finalized);
        try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.finalization_count);
    } else {
        try std.testing.expectEqual(@as(u8, 1), outcome.resumed);
    }
    const metrics = controller.metricsSnapshot();
    const route = controller.routeMetricsSnapshot(storage.requests[0].workspace.route_id).?;
    try std.testing.expectEqual(
        storage.requests[0].workspace.route_id,
        route.route_id,
    );
    try std.testing.expectEqual(metrics.sink_operation_count, route.cell.sink_operation_count);
    if (behavior == .sink_failure) {
        try std.testing.expectEqual(
            @as(u64, 1),
            metrics.recoverable_failures[@intFromEnum(multipart.IoError.no_space)],
        );
    }
    if (behavior == .fatal) {
        try std.testing.expectEqual(
            @as(u64, 1),
            metrics.fatal_failures[@intFromEnum(upload_metrics.FatalFailureClass.application)],
        );
    }
}

pub fn seedDirectory(controller: *RequestController, generation: u16) !multipart.FileHandle {
    const owner = upload_transport.Owner{
        .scope = .runtime,
        .registry_index = 7,
        .instance_index = 0,
        .slot = .{
            .worker_index = 3,
            .index = reactor.upload_runtime_control_slot,
            .generation = generation,
        },
    };
    const handle = try controller.transport.table().reserveOpen(owner);
    try controller.transport.table().completeOpenPositive(
        handle,
        owner,
        70,
        .directory,
        .read_only,
        .none,
    );
    return handle;
}

pub fn targetLane(
    targets: [lanes]reactor.Submission,
    token: reactor.OperationToken,
) ?u8 {
    for (targets, 0..) |target, lane| {
        if (target.token.eql(token)) return @intCast(lane);
    }
    return null;
}

pub fn chooseLane(smith: *std.testing.Smith, mask: u16) u8 {
    std.debug.assert(mask != 0);
    var ordinal = smith.valueRangeAtMost(u8, 0, @as(u8, @intCast(@popCount(mask))) - 1);
    for (0..lanes) |lane| {
        if (mask & laneBit(@intCast(lane)) == 0) continue;
        if (ordinal == 0) return @intCast(lane);
        ordinal -= 1;
    }
    unreachable;
}

pub const RuntimeMode = split.RuntimeMode;

pub const RuntimeSink = split.RuntimeSink;

pub const SinkA = split.SinkA;
pub const SinkB = split.SinkB;
pub const SinkStartFailure = split.SinkStartFailure;
pub const SinkResumeFailure = split.SinkResumeFailure;

pub const RuntimeRegistry = split.RuntimeRegistry;

pub const RuntimeApp = split.RuntimeApp;

pub const RuntimeStorage = split.RuntimeStorage;

pub const runRuntimeSchedule = split.runRuntimeSchedule;

pub const completeRuntimeOpen = split.completeRuntimeOpen;

pub const stopRuntime = split.stopRuntime;

pub const fuzzWorkerUpload = split.fuzzWorkerUpload;

pub const fuzz_corpus = split.fuzz_corpus;

pub const writeLane = split.writeLane;

pub const laneBit = split.laneBit;

pub const requestReport = split.requestReport;

test {
    _ = @import("worker_upload_transport_fuzz_check_part_1.zig");
}

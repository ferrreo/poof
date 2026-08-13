const source = @import("../../../tests/unit/internal/runtime/worker_live_static_test.zig");
const std = source.std;
const application = source.application;
const response = source.response;
const static_file = source.static_file;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const App = source.App;
const limits = source.limits;
const Storage = source.Storage;
const TestReactor = source.TestReactor;
const Driver = source.Driver;
const Worker = source.Worker;
const TinyTestReactor = source.TinyTestReactor;
const TinyWorker = source.TinyWorker;
const MultiRootApp = source.MultiRootApp;
const MultiRootStorage = source.MultiRootStorage;
const live_static = @import("../../../src/internal/runtime/worker/live_static.zig");
const MultiRootDriver = source.MultiRootDriver;
const LiveHarness = source.LiveHarness;
const isDrainOperation = source.isDrainOperation;
const CancelSendStage = source.CancelSendStage;
const PendingSend = source.PendingSend;
const long_content = source.long_content;
const reachPendingSend = source.reachPendingSend;
const expectRootOperation = source.expectRootOperation;
const findRootSubmission = source.findRootSubmission;
const settleDriverRootTarget = source.settleDriverRootTarget;
const settleWorkerRootTarget = source.settleWorkerRootTarget;
const completeAllStaticCloses = source.completeAllStaticCloses;
const fillDirectoryStat = source.fillDirectoryStat;
const expectZeroed = source.expectZeroed;

pub const ScheduleStage = enum(u8) {
    open,
    initial_stat,
    index_open,
    directory_close,
    file_stat,
    head_send,
    read,
    verify,
    body_send,
    terminal_send,
    complete,
};

pub const RootSchedule = enum(u8) {
    success,
    timeout_late_open,
    open_failure,
    stat_failure_rollback,
    close_failure,
    stop_during_start,
};

pub fn fuzzLiveStaticControllerSchedule(_: void, smith: *std.testing.Smith) !void {
    const root_schedule: RootSchedule = @enumFromInt(smith.valueRangeAtMost(
        u8,
        0,
        @intFromEnum(RootSchedule.stop_during_start),
    ));
    try fuzzRootSchedule(root_schedule, smith);
    const stage: ScheduleStage = @enumFromInt(smith.valueRangeAtMost(
        u8,
        0,
        @intFromEnum(ScheduleStage.complete),
    ));
    const index_request = switch (stage) {
        .index_open, .directory_close, .file_stat => true,
        else => smith.value(bool),
    };
    try fuzzRequestSchedule(stage, index_request, smith);
}

pub fn fuzzRootSchedule(schedule: RootSchedule, smith: *std.testing.Smith) !void {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var io = TestReactor{};
    var state = App.StateType{};
    var driver = try Driver.init(&state, &storage, &io, 0, .{ .date = fixed_date });

    try std.testing.expectEqual(.pending, try driver.beginLiveStaticRoots(1));
    if (schedule == .stop_during_start) {
        try std.testing.expectEqual(.pending, try driver.beginLiveStaticStop());
    }
    const open = findRootSubmission(&io, .file_open).?;
    if (try finishRootOpenFailure(schedule, smith, &driver, &io, open)) return;
    const open_event = try settleFuzzRootTarget(
        &driver,
        &io,
        open,
        .{ .success = .{ .file_open = .{ .value = 41 } } },
        smith.value(bool),
    );
    try std.testing.expectEqual(live_static.Event.none, open_event);
    const stat_event = (try finishRootStat(schedule, smith, &driver, &io)) orelse return;
    const expected_stat_event: live_static.Event =
        if (schedule == .stop_during_start) .none else .roots_ready;
    try std.testing.expectEqual(expected_stat_event, stat_event);

    if (schedule != .stop_during_start) {
        try std.testing.expectEqual(.pending, try driver.beginLiveStaticStop());
    }
    try finishRootClose(schedule, &driver, &io);
}

fn finishRootOpenFailure(
    schedule: RootSchedule,
    smith: *std.testing.Smith,
    driver: *Driver,
    io: *TestReactor,
    open: reactor.Submission,
) !bool {
    if (schedule == .timeout_late_open) {
        try settleLatePositiveRootTimeout(driver, io, open, smith.value(bool));
        const rollback = findRootSubmission(io, .file_close).?;
        try std.testing.expectEqual(@as(i32, 41), rollback.operation.file_close.file.value);
        try std.testing.expectError(
            error.BackendFailure,
            settleFuzzRootTarget(
                driver,
                io,
                rollback,
                .{ .success = .{ .file_close = {} } },
                smith.value(bool),
            ),
        );
        try expectFuzzRootIdle(driver, io);
        try std.testing.expectEqual(.deadline, driver.liveStaticStartupDiagnostic().?.kind);
        return true;
    }
    if (schedule != .open_failure) return false;
    try std.testing.expectError(
        error.BackendFailure,
        settleFuzzRootTarget(
            driver,
            io,
            open,
            .{ .failure = .not_found },
            smith.value(bool),
        ),
    );
    try expectFuzzRootIdle(driver, io);
    return true;
}

fn finishRootStat(
    schedule: RootSchedule,
    smith: *std.testing.Smith,
    driver: *Driver,
    io: *TestReactor,
) !?live_static.Event {
    const stat = findRootSubmission(io, .file_stat).?;
    fillDirectoryStat(stat.operation.file_stat.output);
    if (schedule != .stat_failure_rollback) {
        return try settleFuzzRootTarget(
            driver,
            io,
            stat,
            .{ .success = .{ .file_stat = {} } },
            smith.value(bool),
        );
    }
    try std.testing.expectEqual(
        live_static.Event.none,
        try settleFuzzRootTarget(
            driver,
            io,
            stat,
            .{ .failure = .io_failure },
            smith.value(bool),
        ),
    );
    const rollback = findRootSubmission(io, .file_close).?;
    try std.testing.expectEqual(@as(i32, 41), rollback.operation.file_close.file.value);
    try std.testing.expectError(
        error.BackendFailure,
        settleFuzzRootTarget(
            driver,
            io,
            rollback,
            .{ .success = .{ .file_close = {} } },
            smith.value(bool),
        ),
    );
    try expectFuzzRootIdle(driver, io);
    return null;
}

fn finishRootClose(schedule: RootSchedule, driver: *Driver, io: *TestReactor) !void {
    const close = findRootSubmission(io, .file_close).?;
    try std.testing.expectEqual(@as(i32, 41), close.operation.file_close.file.value);
    const close_result: reactor.CompletionResult = if (schedule == .close_failure)
        .{ .failure = .io_failure }
    else
        .{ .success = .{ .file_close = {} } };
    try io.complete(close.token, close_result, false);
    if (schedule == .close_failure) {
        try std.testing.expectError(
            error.BackendFailure,
            driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
        );
        try expectFuzzRootIdle(driver, io);
        try std.testing.expect(!driver.liveStaticStopped());
        return;
    }
    try std.testing.expectEqual(
        live_static.Event.stopped,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
    try expectFuzzRootIdle(driver, io);
}

pub fn settleLatePositiveRootTimeout(
    driver: *Driver,
    io: *TestReactor,
    target: reactor.Submission,
    cancel_first: bool,
) !void {
    const timeout = findRootSubmission(io, .timeout).?;
    try io.complete(timeout.token, .{ .success = .{ .timeout = {} } }, false);
    try std.testing.expectEqual(
        live_static.Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
    const cancel = findRootSubmission(io, .file_cancel).?;
    const target_result = reactor.CompletionResult{
        .success = .{ .file_open = .{ .value = 41 } },
    };
    const cancel_result = reactor.CompletionResult{
        .success = .{ .file_cancel = .not_found },
    };
    const first = if (cancel_first) cancel else target;
    const first_result = if (cancel_first) cancel_result else target_result;
    const second = if (cancel_first) target else cancel;
    const second_result = if (cancel_first) target_result else cancel_result;
    try io.complete(first.token, first_result, false);
    try std.testing.expectEqual(
        live_static.Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
    try io.complete(second.token, second_result, false);
    try std.testing.expectEqual(
        live_static.Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
}

pub fn expectFuzzRootIdle(driver: *const Driver, io: *const TestReactor) !void {
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
    try std.testing.expectEqual(@as(u16, 0), io.borrowedCount());
    try std.testing.expectEqual(@as(u16, 0), driver.liveStaticPending());
}

pub fn settleFuzzRootTarget(
    driver: *Driver,
    io: *TestReactor,
    target: reactor.Submission,
    result: reactor.CompletionResult,
    cancel_first: bool,
) !live_static.Event {
    try io.complete(target.token, result, false);
    try std.testing.expectEqual(
        live_static.Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2),
    );
    const cancel = findRootSubmission(io, .cancel).?;
    const timeout = findRootSubmission(io, .timeout).?;
    const first = if (cancel_first) cancel else timeout;
    const second = if (cancel_first) timeout else cancel;
    _ = try completeRootControl(driver, io, first);
    return completeRootControl(driver, io, second);
}

pub fn completeRootControl(
    driver: *Driver,
    io: *TestReactor,
    submission: reactor.Submission,
) !live_static.Event {
    const kind = (try submission.token.fields()).kind;
    const result: reactor.CompletionResult = switch (kind) {
        .cancel => .{ .success = .{ .cancel = .canceled } },
        .timeout => .{ .failure = .canceled },
        else => return error.TestUnexpectedResult,
    };
    try io.complete(submission.token, result, false);
    return driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, 2);
}

pub fn fuzzRequestSchedule(
    stage: ScheduleStage,
    index_request: bool,
    smith: *std.testing.Smith,
) !void {
    const content: []const u8 = if (stage == .body_send)
        &long_content
    else
        "controller schedule body";
    var harness: LiveHarness = undefined;
    try harness.init(content);
    if (index_request) harness.directory_path = "docs";
    const connection = try reachScheduleStage(&harness, stage, index_request);
    if (stage != .complete) {
        try std.testing.expectEqual(
            connection_driver.Disposition.retained,
            try harness.driver.stop(connection),
        );
    } else {
        _ = try harness.driver.stop(connection);
    }

    var schedule = RandomDrain{};
    try schedule.run(&harness, connection, smith);
    try expectScheduleClean(&harness, stage, schedule.terminal_send_succeeded);
}

pub fn reachScheduleStage(
    harness: *LiveHarness,
    stage: ScheduleStage,
    index_request: bool,
) !u16 {
    const connection = try harness.request(
        if (index_request)
            "GET /assets/docs/ HTTP/1.1\r\nHost: example.test\r\n\r\n"
        else
            "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    if (stage == .open) return connection;
    try harness.completeStatic(harness.findStatic(.file_open).?);
    if (stage == .initial_stat) return connection;
    try harness.completeStatic(harness.findStatic(.file_stat).?);
    if (index_request) {
        if (stage == .index_open) return connection;
        try harness.completeStatic(harness.findStatic(.file_open).?);
        if (stage == .directory_close) return connection;
        try harness.completeStatic(harness.findStatic(.file_close).?);
        if (stage == .file_stat) return connection;
        try harness.completeStatic(harness.findStatic(.file_stat).?);
    }
    if (stage == .head_send) return connection;
    try harness.completeSend(harness.currentSend(connection).?);
    if (stage == .read) return connection;
    try harness.completeStatic(harness.findStatic(.file_read).?);
    if (stage == .verify or stage == .body_send) return connection;
    try harness.completeStatic(harness.findStatic(.file_stat).?);
    if (stage == .terminal_send) return connection;
    try harness.runResponse(connection);
    return connection;
}

pub const RandomDrain = struct {
    canceled: [16]reactor.OperationToken = undefined,
    canceled_count: u8 = 0,
    repeated_close: bool = false,
    terminal_send_succeeded: bool = false,

    pub fn run(
        self: *RandomDrain,
        harness: *LiveHarness,
        connection: u16,
        smith: *std.testing.Smith,
    ) !void {
        var steps: u16 = 0;
        while (harness.storage.connections[connection].phase != .free) : (steps += 1) {
            if (steps == 128) return error.TestUnexpectedResult;
            try self.maybeRepeatClose(harness, connection, smith);
            const active = harness.io.activeCount();
            if (active == 0) return error.TestUnexpectedResult;
            const selected = smith.valueRangeAtMost(u16, 0, active - 1);
            try self.complete(
                harness,
                connection,
                harness.io.activeSubmission(selected).?,
                smith,
            );
        }
    }

    pub fn maybeRepeatClose(
        self: *RandomDrain,
        harness: *LiveHarness,
        connection: u16,
        smith: *std.testing.Smith,
    ) !void {
        if (self.repeated_close or !smith.value(bool) or
            harness.findStatic(.file_close) == null or
            harness.findStatic(.file_cancel) != null) return;
        _ = try harness.driver.stop(connection);
        self.repeated_close = true;
    }

    pub fn complete(
        self: *RandomDrain,
        harness: *LiveHarness,
        connection: u16,
        submission: reactor.Submission,
        smith: *std.testing.Smith,
    ) !void {
        const fields = try submission.token.fields();
        if (reactor.liveStaticRequestIndex(fields.slot_index) != null) {
            return self.completeStatic(harness, submission);
        }
        return self.completeConnection(harness, connection, submission, smith);
    }

    pub fn completeStatic(
        self: *RandomDrain,
        harness: *LiveHarness,
        submission: reactor.Submission,
    ) !void {
        const fields = try submission.token.fields();
        if (fields.kind == .file_cancel) {
            const target = submission.operation.file_cancel.target;
            const active = harness.io.tokenActive(target);
            if (active) try self.markCanceled(target);
            return harness.completeStaticResult(submission, .{ .success = .{
                .file_cancel = if (active) .canceled else .not_found,
            } });
        }
        if (self.wasCanceled(submission.token)) {
            return harness.completeStaticResult(submission, .{ .failure = .canceled });
        }
        return harness.completeStatic(submission);
    }

    pub fn completeConnection(
        self: *RandomDrain,
        harness: *LiveHarness,
        connection: u16,
        submission: reactor.Submission,
        smith: *std.testing.Smith,
    ) !void {
        const fields = try submission.token.fields();
        if (fields.kind == .send) {
            const success = !self.wasCanceled(submission.token) and smith.value(bool);
            if (success) {
                const request_index = harness.storage.connections[connection].active_request;
                if (request_index) |active_request| {
                    if (harness.storage.requests[active_request].live_static_slot) |slot_index| {
                        self.terminal_send_succeeded =
                            harness.driver.live_static.slots[slot_index].remaining == 0;
                    }
                }
            }
            return harness.completeSendResult(
                submission,
                success,
            );
        }
        const result: reactor.CompletionResult = switch (submission.operation) {
            .cancel => |cancel| result: {
                const active = harness.io.tokenActive(cancel.target);
                if (active) try self.markCanceled(cancel.target);
                break :result .{ .success = .{
                    .cancel = if (active) .canceled else .not_found,
                } };
            },
            .receive, .timeout => .{ .failure = .canceled },
            .close => .{ .success = .{ .close = {} } },
            else => return error.TestUnexpectedResult,
        };
        try harness.io.complete(submission.token, result, false);
        _ = try harness.driver.handle(harness.io.nextCompletion().?, 3);
    }

    pub fn markCanceled(self: *RandomDrain, token: reactor.OperationToken) !void {
        if (self.wasCanceled(token)) return;
        if (self.canceled_count == self.canceled.len) return error.TestUnexpectedResult;
        self.canceled[self.canceled_count] = token;
        self.canceled_count += 1;
    }

    pub fn wasCanceled(self: *const RandomDrain, token: reactor.OperationToken) bool {
        for (self.canceled[0..self.canceled_count]) |value| {
            if (value.eql(token)) return true;
        }
        return false;
    }
};

pub fn expectScheduleClean(
    harness: *LiveHarness,
    stage: ScheduleStage,
    terminal_send_succeeded: bool,
) !void {
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticPending());
    try std.testing.expectEqual(@as(u16, 0), harness.io.activeCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.pendingCompletionCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.borrowedCount());
    try std.testing.expectEqual(
        limits.connection_slots,
        harness.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(limits.request_slots, harness.storage.request_pool.available());
    try expectDescriptorLedgerClosed(harness);
    const completed: u16 = @intFromBool(stage == .complete or terminal_send_succeeded);
    try std.testing.expectEqual(completed, harness.state.completed);
    try std.testing.expectEqual(@as(u16, 1) - completed, harness.state.aborted);
    try expectZeroed(harness.storage.liveStaticPath(0));
    try expectZeroed(harness.storage.liveStaticRead(0));
}

pub fn expectDescriptorLedgerClosed(harness: *const LiveHarness) !void {
    try std.testing.expectEqual(harness.opened_count, harness.closed_count);
    for (harness.opened_descriptors[0..harness.opened_count]) |opened_descriptor| {
        var close_count: u8 = 0;
        for (harness.closed_descriptors[0..harness.closed_count]) |closed_descriptor| {
            close_count += @intFromBool(opened_descriptor == closed_descriptor);
        }
        try std.testing.expectEqual(@as(u8, 1), close_count);
    }
}

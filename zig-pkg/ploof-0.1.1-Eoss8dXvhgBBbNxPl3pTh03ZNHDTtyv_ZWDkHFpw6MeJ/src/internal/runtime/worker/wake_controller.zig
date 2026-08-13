const std = @import("std");

const reactor = @import("../reactor.zig");

pub const Phase = enum(u8) {
    idle,
    armed,
    ready,
    stopping,
    stopped,
    failed,
};

/// A ready event requires draining the wake source and scanning notifications.
/// This remains required when ready and stopped are both set.
pub const Event = packed struct(u2) {
    ready: bool = false,
    stopped: bool = false,
};

pub const Error = error{
    InvalidWorkerIndex,
    InvalidControlSlot,
    InvalidPhase,
    SubmitFailed,
    InvalidCompletion,
    WakeFailed,
    CancelFailed,
};

const TargetTerminal = enum(u8) { ready, canceled, failed };
const CancelTerminal = enum(u8) { canceled, not_found, failed };

/// Owns wake operation tokens. The caller retains ownership of the wake source.
pub const Controller = struct {
    worker_index: u16,
    control_slot: u16,
    generation: u16 = 1,
    sequence: u16 = 1,
    state: Phase = .idle,
    poll_token: ?reactor.OperationToken = null,
    cancel_token: ?reactor.OperationToken = null,
    target_terminal: ?TargetTerminal = null,
    cancel_terminal: ?CancelTerminal = null,

    pub fn init(worker_index: u16) Error!Controller {
        return initAt(worker_index, reactor.wake_control_slot);
    }

    pub fn initAt(worker_index: u16, control_slot: u16) Error!Controller {
        if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
        if (!reactor.isWakeControlSlot(control_slot)) return error.InvalidControlSlot;
        const controller = Controller{
            .worker_index = worker_index,
            .control_slot = control_slot,
        };
        controller.assertInvariants();
        return controller;
    }

    pub fn arm(self: *Controller, source: reactor.WakeSource, backend: anytype) Error!void {
        if (self.state != .idle) return error.InvalidPhase;
        try self.submitPoll(source, backend);
        self.state = .armed;
        self.assertInvariants();
    }

    /// Caller invokes this only after draining the source and scanning notifications.
    pub fn rearm(self: *Controller, source: reactor.WakeSource, backend: anytype) Error!void {
        if (self.state != .ready) return error.InvalidPhase;
        try self.submitPoll(source, backend);
        self.target_terminal = null;
        self.state = .armed;
        self.assertInvariants();
    }

    pub fn stop(self: *Controller, backend: anytype) Error!Event {
        switch (self.state) {
            .idle => {
                self.state = .stopped;
                self.assertInvariants();
                return .{ .stopped = true };
            },
            .armed => {
                try self.submitCancel(backend);
                self.state = .stopping;
                self.assertInvariants();
                return .{};
            },
            .ready => {
                self.target_terminal = null;
                self.state = .stopped;
                self.assertInvariants();
                return .{ .stopped = true };
            },
            .stopping => return .{},
            .stopped => return .{ .stopped = true },
            .failed => return error.InvalidPhase,
        }
    }

    pub fn handle(self: *Controller, completion: reactor.Completion) Error!Event {
        if (completion.validate() != null) return error.InvalidCompletion;
        const fields = completion.token.fields() catch return error.InvalidCompletion;
        if (fields.worker_index != self.worker_index or
            fields.slot_index != self.control_slot or
            fields.slot_generation != self.generation)
        {
            return error.InvalidCompletion;
        }
        const event = switch (fields.kind) {
            .wake => try self.handlePoll(completion),
            .cancel => try self.handleCancel(completion),
            else => return error.InvalidCompletion,
        };
        self.assertInvariants();
        return event;
    }

    pub fn phase(self: *const Controller) Phase {
        self.assertInvariants();
        return self.state;
    }

    pub fn currentPollToken(self: *const Controller) ?reactor.OperationToken {
        self.assertInvariants();
        return self.poll_token;
    }

    pub fn currentCancelToken(self: *const Controller) ?reactor.OperationToken {
        self.assertInvariants();
        return self.cancel_token;
    }

    pub fn isStopped(self: *const Controller) bool {
        self.assertInvariants();
        return self.state == .stopped;
    }

    /// Fatal-only reset after the backend has resolved ownership of every token.
    pub fn abortAfterBackend(self: *Controller) void {
        self.poll_token = null;
        self.cancel_token = null;
        self.target_terminal = null;
        self.cancel_terminal = null;
        self.generation = reactor.nextGeneration(self.generation);
        self.sequence = 1;
        self.state = .stopped;
        self.assertInvariants();
    }

    fn submitPoll(
        self: *Controller,
        source: reactor.WakeSource,
        backend: anytype,
    ) Error!void {
        const token = try self.nextToken(.wake);
        backend.submit(.{
            .token = token,
            .operation = .{ .wake = .{ .source = source } },
        }) catch return error.SubmitFailed;
        self.poll_token = token;
        self.sequence = reactor.nextSequence(self.sequence);
    }

    fn submitCancel(self: *Controller, backend: anytype) Error!void {
        const target = self.poll_token orelse return error.InvalidPhase;
        const token = try self.nextToken(.cancel);
        backend.submit(.{
            .token = token,
            .operation = .{ .cancel = .{ .target = target } },
        }) catch return error.SubmitFailed;
        self.cancel_token = token;
        self.sequence = reactor.nextSequence(self.sequence);
    }

    fn nextToken(
        self: *const Controller,
        kind: reactor.OperationKind,
    ) Error!reactor.OperationToken {
        return reactor.OperationToken.init(.{
            .kind = kind,
            .worker_index = self.worker_index,
            .slot_index = self.control_slot,
            .slot_generation = self.generation,
            .sequence = self.sequence,
        }) catch return error.InvalidPhase;
    }

    fn handlePoll(self: *Controller, completion: reactor.Completion) Error!Event {
        const current = self.poll_token orelse return error.InvalidCompletion;
        if (!current.eql(completion.token)) return error.InvalidCompletion;
        if (self.state != .armed and self.state != .stopping) {
            return error.InvalidCompletion;
        }
        self.poll_token = null;
        const terminal = pollTerminal(completion.result);
        if (self.state == .armed) {
            if (terminal != .ready) {
                self.state = .failed;
                return error.WakeFailed;
            }
            self.target_terminal = terminal;
            self.state = .ready;
            return .{ .ready = true };
        }
        self.target_terminal = terminal;
        var event = try self.settleStopping();
        if (terminal == .failed) return error.WakeFailed;
        event.ready = terminal == .ready;
        return event;
    }

    fn handleCancel(self: *Controller, completion: reactor.Completion) Error!Event {
        if (self.state != .stopping) return error.InvalidCompletion;
        const current = self.cancel_token orelse return error.InvalidCompletion;
        if (!current.eql(completion.token)) return error.InvalidCompletion;
        self.cancel_token = null;
        const terminal = cancelTerminal(completion.result);
        self.cancel_terminal = terminal;
        const event = try self.settleStopping();
        if (terminal == .failed) return error.CancelFailed;
        return event;
    }

    fn settleStopping(self: *Controller) Error!Event {
        const target = self.target_terminal orelse return .{};
        const cancel = self.cancel_terminal orelse return .{};
        self.target_terminal = null;
        self.cancel_terminal = null;
        if (target == .failed) {
            self.state = .failed;
            return error.WakeFailed;
        }
        if (cancel == .failed) {
            self.state = .failed;
            return error.CancelFailed;
        }
        if (target == .canceled and cancel != .canceled) {
            self.state = .failed;
            return error.InvalidCompletion;
        }
        self.state = .stopped;
        return .{ .stopped = true };
    }

    fn assertInvariants(self: *const Controller) void {
        std.debug.assert(self.worker_index <= reactor.max_worker_index);
        std.debug.assert(reactor.isWakeControlSlot(self.control_slot));
        std.debug.assert(self.generation != 0 and self.sequence != 0);
        switch (self.state) {
            .idle => assertEmpty(self),
            .armed => {
                std.debug.assert(self.poll_token != null and self.cancel_token == null);
                std.debug.assert(self.target_terminal == null and self.cancel_terminal == null);
            },
            .ready => {
                std.debug.assert(self.poll_token == null and self.cancel_token == null);
                std.debug.assert(self.target_terminal == .ready);
                std.debug.assert(self.cancel_terminal == null);
            },
            .stopping => {
                std.debug.assert((self.poll_token == null) == (self.target_terminal != null));
                std.debug.assert((self.cancel_token == null) == (self.cancel_terminal != null));
            },
            .stopped, .failed => assertEmpty(self),
        }
    }
};

fn pollTerminal(result: reactor.CompletionResult) TargetTerminal {
    return switch (result) {
        .success => |success| switch (success) {
            .wake => .ready,
            else => .failed,
        },
        .failure => |failure| if (failure == .canceled) .canceled else .failed,
    };
}

fn cancelTerminal(result: reactor.CompletionResult) CancelTerminal {
    return switch (result) {
        .success => |success| switch (success) {
            .cancel => |cancel| switch (cancel) {
                .canceled => .canceled,
                .not_found => .not_found,
            },
            else => .failed,
        },
        .failure => .failed,
    };
}

fn assertEmpty(controller: *const Controller) void {
    std.debug.assert(controller.poll_token == null and controller.cancel_token == null);
    std.debug.assert(controller.target_terminal == null and controller.cancel_terminal == null);
}

const deterministic_reactor = @import("../deterministic_reactor.zig");
const TestIo = deterministic_reactor.DeterministicReactor(8);
const test_source = reactor.WakeSource{ .value = 41 };

const StopTokens = struct {
    poll: reactor.OperationToken,
    cancel: reactor.OperationToken,
};

fn completeOperation(
    io: *TestIo,
    controller: *Controller,
    token: reactor.OperationToken,
    result: reactor.CompletionResult,
) !Event {
    try io.complete(token, result, false);
    return controller.handle(io.nextCompletion().?);
}

fn expectEvent(expected: Event, actual: Event) !void {
    try std.testing.expectEqual(
        @as(u2, @bitCast(expected)),
        @as(u2, @bitCast(actual)),
    );
}

fn testCompletion(
    token: reactor.OperationToken,
    result: reactor.CompletionResult,
    more: bool,
) reactor.Completion {
    return .{ .token = token, .result = result, .more = more };
}

fn testToken(
    kind: reactor.OperationKind,
    worker_index: u16,
    slot_index: u16,
    generation: u16,
    sequence: u16,
) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = worker_index,
        .slot_index = slot_index,
        .slot_generation = generation,
        .sequence = sequence,
    });
}

fn armStopping(controller: *Controller, io: *TestIo) !StopTokens {
    try controller.arm(test_source, io);
    const poll = controller.currentPollToken().?;
    const event = try controller.stop(io);
    try expectEvent(.{}, event);
    return .{ .poll = poll, .cancel = controller.currentCancelToken().? };
}

test "wake controller requires explicit processing before rearm" {
    try std.testing.expectError(
        error.InvalidWorkerIndex,
        Controller.init(reactor.max_worker_index + 1),
    );
    var controller = try Controller.init(7);
    var io = TestIo{};
    try controller.arm(test_source, &io);
    const first = controller.currentPollToken().?;
    const first_fields = try first.fields();
    try std.testing.expectEqual(reactor.OperationKind.wake, first_fields.kind);
    try std.testing.expectEqual(reactor.wake_control_slot, first_fields.slot_index);
    try std.testing.expectEqual(@as(u16, 1), first_fields.slot_generation);
    try std.testing.expectEqual(@as(u16, 1), first_fields.sequence);
    try std.testing.expectEqual(@as(u64, 41), io.operation(first).?.wake.source.value);
    try std.testing.expectError(error.InvalidPhase, controller.rearm(test_source, &io));

    const first_event = try completeOperation(
        &io,
        &controller,
        first,
        .{ .success = .{ .wake = {} } },
    );
    try expectEvent(.{ .ready = true }, first_event);
    try std.testing.expectEqual(Phase.ready, controller.phase());
    try std.testing.expect(controller.currentPollToken() == null);
    try std.testing.expectError(error.InvalidPhase, controller.arm(test_source, &io));

    try controller.rearm(.{ .value = 42 }, &io);
    const second = controller.currentPollToken().?;
    const second_fields = try second.fields();
    try std.testing.expectEqual(first_fields.slot_generation, second_fields.slot_generation);
    try std.testing.expectEqual(@as(u16, 2), second_fields.sequence);
    try std.testing.expect(!first.eql(second));
    try std.testing.expectError(error.InvalidCompletion, controller.handle(testCompletion(
        first,
        .{ .success = .{ .wake = {} } },
        false,
    )));
    _ = try completeOperation(&io, &controller, second, .{ .success = .{ .wake = {} } });
    try expectEvent(.{ .stopped = true }, try controller.stop(&io));
    try std.testing.expect(controller.currentCancelToken() == null);
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
    try expectEvent(.{ .stopped = true }, try controller.stop(&io));
}

test "wake controller initAt owns the distinct stream control slot" {
    try std.testing.expectError(error.InvalidControlSlot, Controller.initAt(0, 0));
    var controller = try Controller.initAt(2, reactor.stream_wake_control_slot);
    var io = TestIo{};
    try controller.arm(test_source, &io);
    const token = controller.currentPollToken().?;
    try std.testing.expectEqual(
        reactor.stream_wake_control_slot,
        (try token.fields()).slot_index,
    );
    _ = try completeOperation(
        &io,
        &controller,
        token,
        .{ .success = .{ .wake = {} } },
    );
    try expectEvent(.{ .stopped = true }, try controller.stop(&io));
}

test "wake controller submission failures roll back arm and stop" {
    var controller = try Controller.init(0);
    var io = TestIo{};
    io.injectSubmitFailure();
    try std.testing.expectError(error.SubmitFailed, controller.arm(test_source, &io));
    try std.testing.expectEqual(Phase.idle, controller.phase());
    try std.testing.expect(controller.currentPollToken() == null);
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());

    try controller.arm(test_source, &io);
    const poll = controller.currentPollToken().?;
    try std.testing.expectEqual(@as(u16, 1), (try poll.fields()).sequence);
    io.injectSubmitFailure();
    try std.testing.expectError(error.SubmitFailed, controller.stop(&io));
    try std.testing.expectEqual(Phase.armed, controller.phase());
    try std.testing.expect(controller.currentPollToken().?.eql(poll));
    try std.testing.expect(controller.currentCancelToken() == null);

    try expectEvent(.{}, try controller.stop(&io));
    const cancel = controller.currentCancelToken().?;
    try std.testing.expectEqual(@as(u16, 2), (try cancel.fields()).sequence);
    try expectEvent(.{}, try controller.stop(&io));
    _ = try completeOperation(
        &io,
        &controller,
        cancel,
        .{ .success = .{ .cancel = .canceled } },
    );
    const event = try completeOperation(&io, &controller, poll, .{ .failure = .canceled });
    try expectEvent(.{ .stopped = true }, event);
}

test "wake controller stop before arm is idempotent and submits nothing" {
    var controller = try Controller.init(0);
    var io = TestIo{};
    try expectEvent(.{ .stopped = true }, try controller.stop(&io));
    try expectEvent(.{ .stopped = true }, try controller.stop(&io));
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
    try std.testing.expect(controller.currentPollToken() == null);
    try std.testing.expect(controller.currentCancelToken() == null);
}

test "wake controller rearm failure preserves processed state" {
    var controller = try Controller.init(0);
    var io = TestIo{};
    try controller.arm(test_source, &io);
    const first = controller.currentPollToken().?;
    _ = try completeOperation(&io, &controller, first, .{ .success = .{ .wake = {} } });
    io.injectSubmitFailure();
    try std.testing.expectError(error.SubmitFailed, controller.rearm(test_source, &io));
    try std.testing.expectEqual(Phase.ready, controller.phase());
    try std.testing.expect(controller.currentPollToken() == null);
    try controller.rearm(test_source, &io);
    try std.testing.expectEqual(
        @as(u16, 2),
        (try controller.currentPollToken().?.fields()).sequence,
    );
    const status = try io.abort();
    try std.testing.expect(status.ownership_proven);
    controller.abortAfterBackend();
}

fn runCanceledStop(cancel_first: bool) !void {
    var controller = try Controller.init(0);
    var io = TestIo{};
    const tokens = try armStopping(&controller, &io);
    if (cancel_first) {
        const first = try completeOperation(
            &io,
            &controller,
            tokens.cancel,
            .{ .success = .{ .cancel = .canceled } },
        );
        try expectEvent(.{}, first);
        const second = try completeOperation(
            &io,
            &controller,
            tokens.poll,
            .{ .failure = .canceled },
        );
        try expectEvent(.{ .stopped = true }, second);
    } else {
        const first = try completeOperation(
            &io,
            &controller,
            tokens.poll,
            .{ .failure = .canceled },
        );
        try expectEvent(.{}, first);
        const second = try completeOperation(
            &io,
            &controller,
            tokens.cancel,
            .{ .success = .{ .cancel = .canceled } },
        );
        try expectEvent(.{ .stopped = true }, second);
    }
    try std.testing.expect(controller.isStopped());
    try std.testing.expect(controller.currentPollToken() == null);
    try std.testing.expect(controller.currentCancelToken() == null);
}

test "wake controller settles canceled stop in both completion orders" {
    try runCanceledStop(true);
    try runCanceledStop(false);
}

fn runReadyStop(cancel_first: bool, cancel_result: reactor.CancelResult) !void {
    var controller = try Controller.init(0);
    var io = TestIo{};
    const tokens = try armStopping(&controller, &io);
    if (cancel_first) {
        const first = try completeOperation(&io, &controller, tokens.cancel, .{ .success = .{
            .cancel = cancel_result,
        } });
        try expectEvent(.{}, first);
        const second = try completeOperation(
            &io,
            &controller,
            tokens.poll,
            .{ .success = .{ .wake = {} } },
        );
        try expectEvent(.{ .ready = true, .stopped = true }, second);
    } else {
        const first = try completeOperation(
            &io,
            &controller,
            tokens.poll,
            .{ .success = .{ .wake = {} } },
        );
        try expectEvent(.{ .ready = true }, first);
        const second = try completeOperation(&io, &controller, tokens.cancel, .{ .success = .{
            .cancel = cancel_result,
        } });
        try expectEvent(.{ .stopped = true }, second);
    }
    try std.testing.expect(controller.isStopped());
}

test "wake controller preserves readiness across every valid cancel race" {
    try runReadyStop(true, .not_found);
    try runReadyStop(false, .not_found);
    try runReadyStop(true, .canceled);
    try runReadyStop(false, .canceled);
}

test "wake controller rejects impossible cancel pair and duplicate terminal" {
    var controller = try Controller.init(0);
    var io = TestIo{};
    const tokens = try armStopping(&controller, &io);
    const cancel_completion = testCompletion(
        tokens.cancel,
        .{ .success = .{ .cancel = .not_found } },
        false,
    );
    const first = try completeOperation(
        &io,
        &controller,
        tokens.cancel,
        .{ .success = .{ .cancel = .not_found } },
    );
    try expectEvent(.{}, first);
    try std.testing.expectError(
        error.InvalidCompletion,
        controller.handle(cancel_completion),
    );
    try std.testing.expectError(
        error.InvalidCompletion,
        completeOperation(&io, &controller, tokens.poll, .{ .failure = .canceled }),
    );
    try std.testing.expectEqual(Phase.failed, controller.phase());
    try std.testing.expect(controller.currentPollToken() == null);
    try std.testing.expect(controller.currentCancelToken() == null);
}

test "wake controller rejects malformed stale and foreign completions" {
    var controller = try Controller.init(3);
    var io = TestIo{};
    try controller.arm(test_source, &io);
    const poll = controller.currentPollToken().?;
    const cases = [_]reactor.Completion{
        testCompletion(poll, .{ .success = .{ .wake = {} } }, true),
        testCompletion(
            try testToken(.wake, 3, reactor.wake_control_slot, 2, 1),
            .{ .success = .{ .wake = {} } },
            false,
        ),
        testCompletion(
            try testToken(.wake, 4, reactor.wake_control_slot, 1, 1),
            .{ .success = .{ .wake = {} } },
            false,
        ),
        testCompletion(
            try testToken(.wake, 3, reactor.wake_control_slot, 1, 99),
            .{ .success = .{ .wake = {} } },
            false,
        ),
        testCompletion(
            try testToken(.cancel, 3, 0, 1, 2),
            .{ .success = .{ .cancel = .canceled } },
            false,
        ),
        testCompletion(
            try testToken(.send, 3, reactor.wake_control_slot, 1, 3),
            .{ .success = .{ .send = 1 } },
            false,
        ),
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidCompletion, controller.handle(case));
        try std.testing.expect(controller.currentPollToken().?.eql(poll));
    }
    _ = try completeOperation(&io, &controller, poll, .{ .success = .{ .wake = {} } });
    try std.testing.expectError(
        error.InvalidCompletion,
        controller.handle(testCompletion(poll, .{ .success = .{ .wake = {} } }, false)),
    );
}

test "wake controller wraps sequence and abort advances generation after backend" {
    var controller = try Controller.init(0);
    controller.generation = std.math.maxInt(u16);
    controller.sequence = reactor.max_sequence;
    var io = TestIo{};
    try controller.arm(test_source, &io);
    const last = controller.currentPollToken().?;
    const last_fields = try last.fields();
    try std.testing.expectEqual(std.math.maxInt(u16), last_fields.slot_generation);
    try std.testing.expectEqual(reactor.max_sequence, last_fields.sequence);
    _ = try completeOperation(&io, &controller, last, .{ .success = .{ .wake = {} } });
    try controller.rearm(test_source, &io);
    const wrapped = controller.currentPollToken().?;
    const wrapped_fields = try wrapped.fields();
    try std.testing.expectEqual(std.math.maxInt(u16), wrapped_fields.slot_generation);
    try std.testing.expectEqual(@as(u16, 1), wrapped_fields.sequence);

    const status = try io.abort();
    try std.testing.expect(status.ownership_proven);
    controller.abortAfterBackend();
    try std.testing.expectEqual(@as(u16, 1), controller.generation);
    try std.testing.expectEqual(@as(u16, 1), controller.sequence);
    try std.testing.expect(controller.isStopped());
    try std.testing.expectError(error.InvalidCompletion, controller.handle(testCompletion(
        wrapped,
        .{ .success = .{ .wake = {} } },
        false,
    )));
}

test "wake controller preserves cleanup tokens after terminal failures" {
    var wake_controller = try Controller.init(0);
    var wake_io = TestIo{};
    try wake_controller.arm(test_source, &wake_io);
    const wake = wake_controller.currentPollToken().?;
    try std.testing.expectError(error.WakeFailed, completeOperation(
        &wake_io,
        &wake_controller,
        wake,
        .{ .failure = .backend_failure },
    ));
    try std.testing.expectEqual(Phase.failed, wake_controller.phase());
    try std.testing.expect(wake_controller.currentPollToken() == null);

    var cancel_controller = try Controller.init(0);
    var cancel_io = TestIo{};
    const tokens = try armStopping(&cancel_controller, &cancel_io);
    try std.testing.expectError(error.CancelFailed, completeOperation(
        &cancel_io,
        &cancel_controller,
        tokens.cancel,
        .{ .failure = .backend_failure },
    ));
    try std.testing.expectEqual(Phase.stopping, cancel_controller.phase());
    try std.testing.expect(cancel_controller.currentPollToken().?.eql(tokens.poll));
    try std.testing.expect(cancel_controller.currentCancelToken() == null);
    const status = try cancel_io.abort();
    try std.testing.expect(status.ownership_proven);
    cancel_controller.abortAfterBackend();
}

test "wake controller target failure during stop preserves backend cleanup" {
    var first_controller = try Controller.init(0);
    var first_io = TestIo{};
    const first_tokens = try armStopping(&first_controller, &first_io);
    try std.testing.expectError(error.WakeFailed, completeOperation(
        &first_io,
        &first_controller,
        first_tokens.poll,
        .{ .failure = .backend_failure },
    ));
    try std.testing.expectEqual(Phase.stopping, first_controller.phase());
    try std.testing.expect(first_controller.currentPollToken() == null);
    try std.testing.expect(first_controller.currentCancelToken().?.eql(first_tokens.cancel));
    const first_status = try first_io.abort();
    try std.testing.expect(first_status.ownership_proven);
    first_controller.abortAfterBackend();
    try std.testing.expect(first_controller.isStopped());
    try std.testing.expect(first_controller.currentCancelToken() == null);

    var second_controller = try Controller.init(0);
    var second_io = TestIo{};
    const second_tokens = try armStopping(&second_controller, &second_io);
    try expectEvent(.{}, try completeOperation(
        &second_io,
        &second_controller,
        second_tokens.cancel,
        .{ .success = .{ .cancel = .canceled } },
    ));
    try std.testing.expectEqual(Phase.stopping, second_controller.phase());
    try std.testing.expect(second_controller.currentPollToken().?.eql(second_tokens.poll));
    try std.testing.expect(second_controller.currentCancelToken() == null);
    try std.testing.expectError(error.WakeFailed, completeOperation(
        &second_io,
        &second_controller,
        second_tokens.poll,
        .{ .failure = .backend_failure },
    ));
    try std.testing.expectEqual(Phase.failed, second_controller.phase());
    try std.testing.expect(second_controller.currentPollToken() == null);
    const second_status = try second_io.abort();
    try std.testing.expect(second_status.ownership_proven);
    second_controller.abortAfterBackend();
    try std.testing.expect(second_controller.isStopped());
}

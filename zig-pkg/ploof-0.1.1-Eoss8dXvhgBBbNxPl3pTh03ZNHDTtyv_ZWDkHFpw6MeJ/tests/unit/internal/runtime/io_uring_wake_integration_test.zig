const std = @import("std");
const linux = std.os.linux;

const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const event_counter = @import("../../../../src/internal/runtime/event_counter.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");

const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 128,
    .submission_entries = 8,
    .completion_entries = 16,
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 64, 31);
const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);

test "wake control token cannot alias a configured connection slot" {
    try std.testing.expect(reactor.wake_control_slot > config.connections_hard_max);
    try std.testing.expect(reactor.stream_wake_control_slot > config.connections_hard_max);
    try std.testing.expect(reactor.stream_wake_control_slot != reactor.wake_control_slot);
    const fields = try (try wakeToken(1)).fields();
    try std.testing.expectEqual(reactor.wake_control_slot, fields.slot_index);
}

test "real event counter wakes once and rearms with a new token" {
    var counter = try openCounter();
    var counter_live = true;
    defer if (counter_live) {
        _ = counter.close();
    };
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    for (1..3) |sequence| {
        const control_slot = if (sequence == 2)
            reactor.stream_wake_control_slot
        else
            reactor.wake_control_slot;
        const wake = try wakeTokenAt(control_slot, @intCast(sequence));
        try submitWake(&backend, wake, counter.descriptor);
        try std.testing.expectEqual(@as(u32, 1), try backend.flush());
        try std.testing.expectEqual(@as(u32, 1), backend.activeCount());
        try std.testing.expectEqual(@as(u32, 1), backend.trackedTokenCount());
        try std.testing.expectEqual(@as(?event_counter.Failure, null), counter.signal());
        try expectWake(try backend.wait(), wake);
        try std.testing.expectEqual(@as(u64, 1), try drainCount(counter.drain()));
        try std.testing.expectEqual(@as(u32, 0), backend.activeCount());
        try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());
    }

    try backend.deinit();
    backend_live = false;
    try expectCounterOwnership(&counter);
    counter_live = false;
}

test "real wake cancellation retires target and cancel in either order" {
    var counter = try openCounter();
    var counter_live = true;
    defer if (counter_live) {
        _ = counter.close();
    };
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const canceled_wake = try wakeTokenAt(reactor.stream_wake_control_slot, 1);
    const canceled_cancel = try operationTokenAt(
        .cancel,
        reactor.stream_wake_control_slot,
        2,
    );
    try armCancelRace(&backend, canceled_wake, canceled_cancel, counter.descriptor);
    const canceled = try reapCancelRace(&backend, canceled_wake, canceled_cancel);
    try std.testing.expectEqual(WakeTerminal.canceled, canceled.wake);
    try std.testing.expectEqual(reactor.CancelResult.canceled, canceled.cancel.?);

    try std.testing.expectEqual(@as(?event_counter.Failure, null), counter.signal());
    const ready_wake = try wakeToken(3);
    const ready_cancel = try operationToken(.cancel, 4);
    try armCancelRace(&backend, ready_wake, ready_cancel, counter.descriptor);
    const ready = try reapCancelRace(&backend, ready_wake, ready_cancel);
    try std.testing.expect(ready.valid());
    try std.testing.expectEqual(@as(u64, 1), try drainCount(counter.drain()));
    try std.testing.expectEqual(@as(u32, 0), backend.activeCount());
    try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());

    try backend.deinit();
    backend_live = false;
    try expectCounterOwnership(&counter);
    counter_live = false;
}

test "wake cancel classifier accepts ready or canceled target in both orders" {
    const wake = try wakeToken(1);
    const cancel = try operationToken(.cancel, 2);
    const ready = testCompletion(wake, .{ .success = .{ .wake = {} } });
    const canceled = testCompletion(wake, .{ .failure = .canceled });
    const cancel_canceled = testCompletion(cancel, .{ .success = .{
        .cancel = .canceled,
    } });
    const cancel_not_found = testCompletion(cancel, .{ .success = .{
        .cancel = .not_found,
    } });
    const schedules = [_][2]reactor.Completion{
        .{ ready, cancel_not_found },
        .{ cancel_not_found, ready },
        .{ canceled, cancel_canceled },
        .{ cancel_canceled, canceled },
    };
    for (schedules) |schedule| {
        var state = CancelRace{};
        try state.accept(schedule[0], wake, cancel);
        try state.accept(schedule[1], wake, cancel);
        try std.testing.expect(state.valid());
    }
}

test "invalid wake source and completion fail closed without descriptor ownership risk" {
    var counter = try openCounter();
    var counter_live = true;
    defer if (counter_live) {
        _ = counter.close();
    };
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const wake = try wakeToken(1);
    try std.testing.expectError(error.InvalidWakeSource, backend.submit(.{
        .token = wake,
        .operation = .{ .wake = .{ .source = .{
            .value = @as(u64, std.math.maxInt(linux.fd_t)) + 1,
        } } },
    }));
    try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());

    try submitWake(&backend, wake, counter.descriptor);
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    injectCompletion(&backend.ring, .{
        .user_data = wake.raw(),
        .res = linux.POLL.OUT,
        .flags = 0,
    });
    try std.testing.expectError(error.InvalidCompletion, backend.poll());
    const status = try backend.abort();
    backend_live = false;
    try std.testing.expect(status.ownership_proven);
    try expectCounterOwnership(&counter);
    counter_live = false;
}

const WakeTerminal = enum(u8) { pending, ready, canceled };

const CancelRace = struct {
    wake: WakeTerminal = .pending,
    cancel: ?reactor.CancelResult = null,

    fn accept(
        state: *CancelRace,
        completion: reactor.Completion,
        wake: reactor.OperationToken,
        cancel: reactor.OperationToken,
    ) !void {
        if (completion.more) return error.InvalidCompletion;
        if (completion.token.eql(wake)) {
            if (state.wake != .pending) return error.InvalidCompletion;
            state.wake = switch (completion.result) {
                .success => |success| switch (success) {
                    .wake => .ready,
                    else => return error.InvalidCompletion,
                },
                .failure => |failure| if (failure == .canceled)
                    .canceled
                else
                    return error.InvalidCompletion,
            };
        } else if (completion.token.eql(cancel)) {
            if (state.cancel != null) return error.InvalidCompletion;
            state.cancel = switch (completion.result) {
                .success => |success| switch (success) {
                    .cancel => |result| result,
                    else => return error.InvalidCompletion,
                },
                .failure => return error.InvalidCompletion,
            };
        } else return error.InvalidCompletion;
    }

    fn valid(state: CancelRace) bool {
        if (state.wake == .pending or state.cancel == null) return false;
        return state.wake != .canceled or state.cancel.? == .canceled;
    }
};

fn armCancelRace(
    backend: *Backend,
    wake: reactor.OperationToken,
    cancel: reactor.OperationToken,
    descriptor: linux.fd_t,
) !void {
    try submitWake(backend, wake, descriptor);
    try backend.submit(.{
        .token = cancel,
        .operation = .{ .cancel = .{ .target = wake } },
    });
    try std.testing.expectEqual(@as(u32, 2), try backend.flush());
}

fn reapCancelRace(
    backend: *Backend,
    wake: reactor.OperationToken,
    cancel: reactor.OperationToken,
) !CancelRace {
    var state = CancelRace{};
    try state.accept(try backend.wait(), wake, cancel);
    try state.accept(try backend.wait(), wake, cancel);
    if (!state.valid()) return error.TestUnexpectedResult;
    return state;
}

fn testCompletion(
    operation_token: reactor.OperationToken,
    result: reactor.CompletionResult,
) reactor.Completion {
    return .{ .token = operation_token, .result = result, .more = false };
}

fn openCounter() !event_counter.Counter {
    return switch (event_counter.Counter.open()) {
        .opened => |counter| counter,
        .failed => error.EventCounterOpenFailed,
    };
}

fn operationToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return operationTokenAt(kind, reactor.wake_control_slot, sequence);
}

fn operationTokenAt(
    kind: reactor.OperationKind,
    control_slot: u16,
    sequence: u16,
) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = control_slot,
        .slot_generation = 1,
        .sequence = sequence,
    });
}

fn wakeToken(sequence: u16) !reactor.OperationToken {
    return wakeTokenAt(reactor.wake_control_slot, sequence);
}

fn wakeTokenAt(control_slot: u16, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = .wake,
        .worker_index = 0,
        .slot_index = control_slot,
        .slot_generation = 1,
        .sequence = sequence,
    });
}

fn submitWake(backend: *Backend, wake: reactor.OperationToken, descriptor: linux.fd_t) !void {
    try backend.submit(.{
        .token = wake,
        .operation = .{ .wake = .{ .source = .{ .value = @intCast(descriptor) } } },
    });
}

fn expectWake(completion: reactor.Completion, expected: reactor.OperationToken) !void {
    try std.testing.expect(completion.token.eql(expected));
    try std.testing.expect(!completion.more);
    switch (completion.result) {
        .success => |success| switch (success) {
            .wake => {},
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

fn drainCount(result: event_counter.DrainResult) !u64 {
    return switch (result) {
        .count => |count| count,
        .empty, .failed => error.TestUnexpectedResult,
    };
}

fn expectCounterOwnership(counter: *event_counter.Counter) !void {
    const descriptor = counter.descriptor;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
    try std.testing.expectEqual(@as(?event_counter.Failure, null), counter.close());
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
}

fn injectCompletion(ring: *linux.IoUring, completion: linux.io_uring_cqe) void {
    const tail = @atomicLoad(u32, ring.cq.tail, .acquire);
    std.debug.assert(tail -% ring.cq.head.* < ring.cq.cqes.len);
    ring.cq.cqes[tail & ring.cq.mask] = completion;
    @atomicStore(u32, ring.cq.tail, tail +% 1, .release);
}

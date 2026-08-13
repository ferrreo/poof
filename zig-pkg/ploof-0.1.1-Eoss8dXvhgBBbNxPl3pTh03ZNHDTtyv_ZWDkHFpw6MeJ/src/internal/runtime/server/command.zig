const std = @import("std");

const deterministic_reactor = @import("../deterministic_reactor.zig");
const event_counter = @import("../event_counter.zig");
const reactor = @import("../reactor.zig");
const wake_controller = @import("../worker/wake_controller.zig");

pub const Command = enum(u8) {
    none,
    serve,
    drain,
    force,
};

pub const Publish = enum(u8) {
    unchanged,
    advanced,
};

pub const Event = struct {
    command: Command = .none,
    stopped: bool = false,
};

pub const Error = wake_controller.Error || error{
    EventCounterOpenFailed,
    EventCounterSignalFailed,
    EventCounterDrainFailed,
    EventCounterCloseFailed,
};

/// One caller-to-worker command lane. Only the worker touches the reactor
/// controller; any thread may monotonically publish a command.
pub const Channel = struct {
    requested: std.atomic.Value(Command) = .init(.none),
    counter: event_counter.Counter,
    wake: wake_controller.Controller,

    pub fn init(worker_index: u16) Error!Channel {
        const counter = switch (event_counter.Counter.open()) {
            .opened => |value| value,
            .failed => return error.EventCounterOpenFailed,
        };
        errdefer {
            var owned = counter;
            _ = owned.close();
        }
        return .{
            .counter = counter,
            .wake = try wake_controller.Controller.initAt(
                worker_index,
                reactor.lifecycle_wake_control_slot,
            ),
        };
    }

    pub fn start(channel: *Channel, backend: anytype) Error!void {
        try channel.wake.arm(channel.source(), backend);
    }

    pub fn publish(channel: *Channel, command: Command) Error!Publish {
        if (command == .none) return .unchanged;
        var current = channel.requested.load(.acquire);
        var publication: Publish = .unchanged;
        while (@intFromEnum(command) > @intFromEnum(current)) {
            if (channel.requested.cmpxchgWeak(
                current,
                command,
                .acq_rel,
                .acquire,
            )) |actual| {
                current = actual;
                continue;
            }
            publication = .advanced;
            break;
        }
        if (channel.counter.signal() != null) return error.EventCounterSignalFailed;
        return publication;
    }

    pub fn requestedCommand(channel: *const Channel) Command {
        return channel.requested.load(.acquire);
    }

    pub fn handle(
        channel: *Channel,
        backend: anytype,
        completion: reactor.Completion,
    ) Error!Event {
        const wake_event = try channel.wake.handle(completion);
        var event = Event{ .stopped = wake_event.stopped };
        if (wake_event.ready) {
            try channel.drainCounter();
            event.command = channel.requested.load(.acquire);
            if (!wake_event.stopped and event.command != .force) {
                try channel.wake.rearm(channel.source(), backend);
            }
        }
        return event;
    }

    pub fn beginStop(channel: *Channel, backend: anytype) Error!bool {
        return (try channel.wake.stop(backend)).stopped;
    }

    pub fn finish(channel: *Channel) Error!void {
        if (!channel.wake.isStopped()) return error.InvalidPhase;
        if (channel.counter.close() != null) return error.EventCounterCloseFailed;
    }

    pub fn abortAfterBackend(channel: *Channel) void {
        channel.wake.abortAfterBackend();
        _ = channel.counter.close();
    }

    pub fn operationCount(channel: *const Channel) u8 {
        return @as(u8, @intFromBool(channel.wake.currentPollToken() != null)) +
            @as(u8, @intFromBool(channel.wake.currentCancelToken() != null));
    }

    pub fn operationTokens(channel: *const Channel) [2]?reactor.OperationToken {
        return .{
            channel.wake.currentPollToken(),
            channel.wake.currentCancelToken(),
        };
    }

    pub fn isCompletion(channel: *const Channel, token: reactor.OperationToken) bool {
        const fields = token.fields() catch return false;
        return fields.worker_index == channel.wake.worker_index and
            fields.slot_index == reactor.lifecycle_wake_control_slot;
    }

    fn source(channel: *const Channel) reactor.WakeSource {
        std.debug.assert(channel.counter.descriptor >= 0);
        return .{ .value = @intCast(channel.counter.descriptor) };
    }

    fn drainCounter(channel: *const Channel) Error!void {
        switch (channel.counter.drain()) {
            .count => {},
            .empty, .failed => return error.EventCounterDrainFailed,
        }
    }
};

const TestIo = deterministic_reactor.DeterministicReactor(16);

test "commands coalesce monotonically and force remains terminal" {
    var channel = try Channel.init(3);
    defer if (channel.counter.live) {
        _ = channel.counter.close();
    };
    var io = TestIo{};
    try channel.start(&io);

    try std.testing.expectEqual(Publish.advanced, try channel.publish(.serve));
    try std.testing.expectEqual(Publish.advanced, try channel.publish(.drain));
    try std.testing.expectEqual(Publish.unchanged, try channel.publish(.drain));
    try completeWake(&channel, &io);
    const drain = try channel.handle(&io, io.nextCompletion().?);
    try std.testing.expectEqual(Command.drain, drain.command);
    try std.testing.expectEqual(@as(u8, 1), channel.operationCount());

    try std.testing.expectEqual(Publish.advanced, try channel.publish(.force));
    try std.testing.expectEqual(Publish.unchanged, try channel.publish(.drain));
    try completeWake(&channel, &io);
    const force = try channel.handle(&io, io.nextCompletion().?);
    try std.testing.expectEqual(Command.force, force.command);
    try std.testing.expectEqual(@as(u8, 0), channel.operationCount());
    try std.testing.expect(try channel.beginStop(&io));
    try channel.finish();
}

test "stop reaps cancel before target without closing wake source early" {
    var channel = try Channel.init(0);
    defer if (channel.counter.live) {
        _ = channel.counter.close();
    };
    var io = TestIo{};
    try channel.start(&io);
    try std.testing.expect(!(try channel.beginStop(&io)));
    const poll = channel.wake.currentPollToken().?;
    const cancel = channel.wake.currentCancelToken().?;

    try io.complete(cancel, .{ .success = .{ .cancel = .canceled } }, false);
    try std.testing.expect(!(try channel.handle(&io, io.nextCompletion().?)).stopped);
    try io.complete(poll, .{ .failure = .canceled }, false);
    try std.testing.expect((try channel.handle(&io, io.nextCompletion().?)).stopped);
    try channel.finish();
}

test "concurrent drain and force publishers only advance toward force" {
    const Race = struct {
        channel: *Channel,
        command: Command,
        failures: *std.atomic.Value(u8),
        advances: *std.atomic.Value(u8),

        fn run(race: @This()) void {
            const result = race.channel.publish(race.command) catch {
                _ = race.failures.fetchAdd(1, .monotonic);
                return;
            };
            if (result == .advanced) _ = race.advances.fetchAdd(1, .monotonic);
        }
    };
    var channel = try Channel.init(0);
    defer if (channel.counter.live) {
        _ = channel.counter.close();
    };
    var failures = std.atomic.Value(u8).init(0);
    var advances = std.atomic.Value(u8).init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        const command: Command = if (index & 1 == 0) .drain else .force;
        thread.* = try std.Thread.spawn(.{}, Race.run, .{Race{
            .channel = &channel,
            .command = command,
            .failures = &failures,
            .advances = &advances,
        }});
    }
    for (&threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u8, 0), failures.load(.acquire));
    try std.testing.expect(channel.requested.load(.acquire) == .force);
    try std.testing.expect(advances.load(.acquire) >= 1);
    try std.testing.expect(advances.load(.acquire) <= 2);
    switch (channel.counter.drain()) {
        .count => |count| try std.testing.expectEqual(@as(u64, threads.len), count),
        .empty, .failed => return error.TestUnexpectedResult,
    }
    var io = TestIo{};
    try std.testing.expect(try channel.beginStop(&io));
    try channel.finish();
}

test "failed command signal is retryable after requested state advances" {
    var channel = try Channel.init(0);
    defer if (channel.counter.live) {
        _ = channel.counter.close();
    };
    event_counter.TestAccess.failNextSignal();
    try std.testing.expectError(error.EventCounterSignalFailed, channel.publish(.drain));
    try std.testing.expectEqual(Command.drain, channel.requested.load(.acquire));
    try std.testing.expectEqual(Publish.unchanged, try channel.publish(.drain));
    switch (channel.counter.drain()) {
        .count => |count| try std.testing.expectEqual(@as(u64, 1), count),
        .empty, .failed => return error.TestUnexpectedResult,
    }
}

fn completeWake(channel: *Channel, io: *TestIo) !void {
    const poll = channel.wake.currentPollToken().?;
    try io.complete(poll, .{ .success = .{ .wake = {} } }, false);
}

const std = @import("std");

const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const stream_lifecycle = @import("../../../../src/internal/runtime/worker/stream_lifecycle.zig");

const TestIo = deterministic_reactor.DeterministicReactor(8);
const Disabled = stream_lifecycle.Lifecycle(false, 4);
const Enabled = stream_lifecycle.Lifecycle(true, 4);

fn started(lifecycle: *Enabled, io: *TestIo) !void {
    lifecycle.* = try Enabled.init(2);
    try lifecycle.start(io);
    try std.testing.expectEqual(stream_lifecycle.Phase.running, lifecycle.status().phase);
    try std.testing.expectEqual(@as(u8, 1), lifecycle.status().operations);
    try std.testing.expectEqual(@as(u16, 1), io.activeCount());
}

fn completeStop(
    lifecycle: *Enabled,
    io: *TestIo,
    ready: bool,
    cancel_first: bool,
) !void {
    const poll = lifecycle.currentPollToken().?;
    try lifecycle.beginStop(io);
    const cancel = lifecycle.currentCancelToken().?;
    const order = if (cancel_first) [_]u1{ 1, 0 } else [_]u1{ 0, 1 };
    var ready_seen = false;
    for (order) |which| {
        const token = if (which == 0) poll else cancel;
        const result: reactor.CompletionResult = if (which == 0)
            if (ready) .{ .success = .{ .wake = {} } } else .{ .failure = .canceled }
        else if (ready)
            .{ .success = .{ .cancel = .not_found } }
        else
            .{ .success = .{ .cancel = .canceled } };
        try io.complete(token, result, false);
        const event = try lifecycle.handle(io, io.nextCompletion().?);
        if (which == 0 and ready) ready_seen = event.ready.contains(0);
    }
    try std.testing.expectEqual(ready, ready_seen);
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(@as(u8, 0), lifecycle.status().operations);
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

test "disabled stream lifecycle has no storage source or operation" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Disabled));
    try std.testing.expectError(
        error.InvalidWorkerIndex,
        Disabled.init(reactor.max_worker_index + 1),
    );
    var lifecycle = try Disabled.init(0);
    var io = TestIo{};
    try lifecycle.start(&io);
    try std.testing.expectEqual(stream_lifecycle.Status{
        .phase = .disabled,
        .operations = 0,
        .active_publishers = 0,
        .stale_notifications = 0,
    }, lifecycle.status());
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
    try std.testing.expect(lifecycle.currentPollToken() == null);
    try std.testing.expect(lifecycle.currentCancelToken() == null);
    try std.testing.expectError(error.InvalidPhase, lifecycle.activate(0));
    try lifecycle.confirmPublishersJoined();
    try lifecycle.beginStop(&io);
    try lifecycle.beginFatalAfterPublishersJoined();
    try lifecycle.finishFatalAfterBackend();
}

test "enabled stream lifecycle gates stop on invalidation and producer join" {
    var lifecycle: Enabled = undefined;
    var io = TestIo{};
    lifecycle = try Enabled.init(2);
    try std.testing.expectError(error.InvalidPhase, lifecycle.activate(0));
    try lifecycle.start(&io);
    const first = try lifecycle.activate(0);
    const second = try lifecycle.activate(3);
    try std.testing.expectError(error.SlotActive, lifecycle.activate(0));
    try std.testing.expectError(error.PublishersNotJoined, lifecycle.beginStop(&io));
    try std.testing.expectError(
        error.PublishersNotJoined,
        lifecycle.beginFatalAfterPublishersJoined(),
    );
    try std.testing.expectError(error.PublishersActive, lifecycle.confirmPublishersJoined());
    try std.testing.expectEqual(stream_lifecycle.NotifyResult.published, first.notify());
    try std.testing.expectEqual(.invalidated, lifecycle.invalidateBeforeAbort(first));
    try std.testing.expectEqual(.stale, lifecycle.invalidateBeforeAbort(first));
    try std.testing.expectEqual(.invalidated, lifecycle.invalidateBeforeAbort(second));
    try std.testing.expectError(error.PublishersNotJoined, lifecycle.beginStop(&io));
    try lifecycle.confirmPublishersJoined();
    try std.testing.expectError(error.InvalidPhase, lifecycle.activate(1));
    try completeStop(&lifecycle, &io, true, false);
    try std.testing.expectEqual(stream_lifecycle.NotifyResult.stale, first.notify());
    try std.testing.expectEqual(@as(u64, 1), lifecycle.status().stale_notifications);
}

test "enabled stream lifecycle rolls back start and closes after fatal ownership proof" {
    var retry = try Enabled.init(0);
    var retry_io = TestIo{};
    retry_io.injectSubmitFailure();
    try std.testing.expectError(error.WakeControlFailed, retry.start(&retry_io));
    try std.testing.expectEqual(stream_lifecycle.Phase.initialized, retry.status().phase);
    try retry.start(&retry_io);
    try retry.confirmPublishersJoined();
    try completeStop(&retry, &retry_io, false, true);

    var fatal: Enabled = undefined;
    var fatal_io = TestIo{};
    try started(&fatal, &fatal_io);
    const wake = try fatal.activate(1);
    try std.testing.expectError(error.InvalidPhase, fatal.finishFatalAfterBackend());
    try std.testing.expectError(
        error.PublishersNotJoined,
        fatal.beginFatalAfterPublishersJoined(),
    );
    try std.testing.expectEqual(.invalidated, fatal.invalidateBeforeAbort(wake));
    try fatal.confirmPublishersJoined();
    try fatal.beginFatalAfterPublishersJoined();
    try std.testing.expectEqual(stream_lifecycle.Phase.fatal, fatal.status().phase);
    const status = try fatal_io.abort();
    try std.testing.expect(status.ownership_proven);
    try fatal.finishFatalAfterBackend();
    try std.testing.expect(fatal.isStopped());
    try std.testing.expectEqual(@as(u8, 0), fatal.status().operations);
}

const Race = struct {
    wake: stream_lifecycle.StreamWake,
    go: *std.atomic.Value(bool),
    result: stream_lifecycle.NotifyResult = .stale,

    fn run(self: *Race) void {
        while (!self.go.load(.acquire)) std.Thread.yield() catch {};
        self.result = self.wake.notify();
    }
};

test "stream lifecycle invalidation race is ThreadSanitizer clean" {
    var lifecycle: Enabled = undefined;
    var io = TestIo{};
    try started(&lifecycle, &io);
    const wake = try lifecycle.activate(0);
    var go = std.atomic.Value(bool).init(false);
    var race = Race{ .wake = wake, .go = &go };
    const thread = try std.Thread.spawn(.{}, Race.run, .{&race});
    go.store(true, .release);
    try std.testing.expectEqual(.invalidated, lifecycle.invalidateBeforeAbort(wake));
    thread.join();
    try std.testing.expect(race.result == .published or race.result == .stale);
    try lifecycle.confirmPublishersJoined();
    try lifecycle.beginFatalAfterPublishersJoined();
    const status = try io.abort();
    try std.testing.expect(status.ownership_proven);
    try lifecycle.finishFatalAfterBackend();
}

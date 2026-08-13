const std = @import("std");

const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const stream_wake = @import("../../../../src/internal/runtime/worker/stream_wake.zig");

const TestIo = deterministic_reactor.DeterministicReactor(16);
const Wakes = stream_wake.Fixed(65);

fn started(wakes: *Wakes, io: *TestIo) !void {
    try wakes.init(3);
    try wakes.start(io);
    const fields = try wakes.currentPollToken().?.fields();
    try std.testing.expectEqual(reactor.stream_wake_control_slot, fields.slot_index);
}

fn completeWake(wakes: *Wakes, io: *TestIo) !Wakes.HandleEvent {
    const token = wakes.currentPollToken().?;
    try io.complete(token, .{ .success = .{ .wake = {} } }, false);
    return wakes.handle(io, io.nextCompletion().?);
}

fn completeCanceledStop(wakes: *Wakes, io: *TestIo, cancel_first: bool) !void {
    const poll = wakes.currentPollToken().?;
    try wakes.beginStop(io);
    const cancel = wakes.currentCancelToken().?;
    const first = if (cancel_first) cancel else poll;
    const second = if (cancel_first) poll else cancel;
    const first_result: reactor.CompletionResult = if (cancel_first)
        .{ .success = .{ .cancel = .canceled } }
    else
        .{ .failure = .canceled };
    const second_result: reactor.CompletionResult = if (cancel_first)
        .{ .failure = .canceled }
    else
        .{ .success = .{ .cancel = .canceled } };
    try io.complete(first, first_result, false);
    const first_event = try wakes.handle(io, io.nextCompletion().?);
    try std.testing.expect(!first_event.stopped);
    try io.complete(second, second_result, false);
    const second_event = try wakes.handle(io, io.nextCompletion().?);
    try std.testing.expect(second_event.stopped);
    try std.testing.expectEqual(stream_wake.Phase.stopped, wakes.phase());
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

fn completeReadyStop(cancel_first: bool) !void {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);
    const wake = try wakes.activate(0);
    try std.testing.expectEqual(stream_wake.NotifyResult.published, wake.notify());
    try std.testing.expectEqual(.invalidated, wakes.invalidateBeforeAbort(wake));
    try wakes.confirmPublishersJoined();
    const poll = wakes.currentPollToken().?;
    try wakes.beginStop(&io);
    const cancel = wakes.currentCancelToken().?;
    const order = if (cancel_first) [_]u1{ 1, 0 } else [_]u1{ 0, 1 };
    var ready_seen = false;
    for (order) |which| {
        const token = if (which == 0) poll else cancel;
        const result: reactor.CompletionResult = if (which == 0)
            .{ .success = .{ .wake = {} } }
        else
            .{ .success = .{ .cancel = .not_found } };
        try io.complete(token, result, false);
        const event = try wakes.handle(&io, io.nextCompletion().?);
        if (which == 0) {
            ready_seen = event.ready.contains(0);
        }
    }
    try std.testing.expect(ready_seen);
    try std.testing.expectEqual(stream_wake.Phase.stopped, wakes.phase());
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

test "stream wake retains readiness before pending and throughout send" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);

    const wake = try wakes.activate(64);
    try std.testing.expectEqual(stream_wake.PendingResult.pending, wake.markPending());
    try std.testing.expectEqual(stream_wake.NotifyResult.published, wake.notify());
    try std.testing.expectEqual(stream_wake.NotifyResult.coalesced, wake.notify());

    const event = try completeWake(&wakes, &io);
    try std.testing.expect(event.ready.contains(64));
    try std.testing.expectEqual(@as(u16, 1), event.ready.count());
    try std.testing.expectEqual(@as(u64, 1), event.ready.counter_count);

    // Inventory consumption does not clear readiness while SEND owns bytes.
    try std.testing.expectEqual(stream_wake.NotifyResult.coalesced, wake.notify());
    try std.testing.expectEqual(stream_wake.ClaimResult.claimed, wake.claimReady());
    try std.testing.expectEqual(stream_wake.ClaimResult.not_ready, wake.claimReady());

    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateBeforeAbort(wake),
    );
    try std.testing.expectEqual(stream_wake.NotifyResult.stale, wake.notify());
    try std.testing.expectEqual(stream_wake.PendingResult.stale, wake.markPending());
    try std.testing.expectEqual(stream_wake.ClaimResult.stale, wake.claimReady());
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, true);
}

test "stream wake captures both summary words at the maximum slot count" {
    const WideWakes = stream_wake.Fixed(8192);
    var wakes: WideWakes = undefined;
    var io = TestIo{};
    try wakes.init(0);
    try wakes.start(&io);

    const left = try wakes.activate(4095);
    const right = try wakes.activate(4096);
    const last = try wakes.activate(8191);
    try std.testing.expectEqual(.published, left.notify());
    try std.testing.expectEqual(.published, right.notify());
    try std.testing.expectEqual(.published, last.notify());
    const poll = wakes.currentPollToken().?;
    try io.complete(poll, .{ .success = .{ .wake = {} } }, false);
    const event = try wakes.handle(&io, io.nextCompletion().?);
    try std.testing.expect(event.ready.contains(4095));
    try std.testing.expect(event.ready.contains(4096));
    try std.testing.expect(event.ready.contains(8191));
    try std.testing.expect(!event.ready.contains(4094));
    try std.testing.expectEqual(@as(u16, 3), event.ready.count());

    for ([_]stream_wake.StreamWake{ left, right, last }) |wake| {
        try std.testing.expectEqual(.claimed, wake.claimReady());
        try std.testing.expectEqual(.invalidated, wakes.invalidateBeforeAbort(wake));
    }
    try wakes.confirmPublishersJoined();
    try wakes.beginFatalAfterPublishersJoined();
    try std.testing.expect((try io.abort()).ownership_proven);
    try wakes.finishFatalAfterBackend();
}

test "stream wake invalidate abort join permits generation-safe slot reuse" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);

    const old = try wakes.activate(0);
    try std.testing.expectEqual(@as(u64, 1), old.generation());
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateBeforeAbort(old),
    );
    // Application runtime aborts and joins the old producer before this reuse.
    const current = try wakes.activate(0);
    try std.testing.expectEqual(@as(u64, 2), current.generation());
    try std.testing.expectEqual(stream_wake.NotifyResult.stale, old.notify());
    try std.testing.expectEqual(@as(u64, 1), wakes.staleNotificationCount());
    try std.testing.expectEqual(stream_wake.NotifyResult.published, current.notify());
    try std.testing.expectEqual(stream_wake.ClaimResult.claimed, current.claimReady());
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateBeforeAbort(current),
    );

    Wakes.TestAccess.setGeneration(&wakes, 1, stream_wake.generation_max);
    try std.testing.expectError(error.GenerationExhausted, wakes.activate(1));
    Wakes.TestAccess.setStaleCount(&wakes, std.math.maxInt(u64));
    try std.testing.expectEqual(stream_wake.NotifyResult.stale, old.notify());
    try std.testing.expectEqual(std.math.maxInt(u64), wakes.staleNotificationCount());
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, false);
}

test "stream wake immutable identity publishes only its live generation" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);
    const wake = try wakes.activate(1);
    try std.testing.expectEqual(
        stream_wake.PendingResult.pending,
        wakes.markPendingIdentity(wake.index(), wake.generation()),
    );
    try std.testing.expectEqual(
        stream_wake.NotifyResult.published,
        wakes.notifyIdentity(wake.index(), wake.generation()),
    );
    try std.testing.expectEqual(
        stream_wake.NotifyResult.stale,
        wakes.notifyIdentity(wake.index(), wake.generation() + 1),
    );
    try std.testing.expectEqual(
        stream_wake.ClaimResult.claimed,
        wakes.claimReadyIdentity(wake.index(), wake.generation()),
    );
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateIdentityBeforeAbort(wake.index(), wake.generation()),
    );
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, true);
}

test "stream wake cannot start after publisher shutdown is confirmed" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try wakes.init(0);
    try wakes.confirmPublishersJoined();
    try std.testing.expectError(error.InvalidPhase, wakes.start(&io));
    try wakes.beginStop(&io);
    try std.testing.expectEqual(stream_wake.Phase.stopped, wakes.phase());
    try std.testing.expectEqual(@as(u16, 0), io.activeCount());
}

test "stream wake close requires invalidation and explicit publisher join" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);
    const wake = try wakes.activate(1);

    try std.testing.expectError(error.PublishersNotJoined, wakes.beginStop(&io));
    try std.testing.expectError(error.PublishersActive, wakes.confirmPublishersJoined());
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateBeforeAbort(wake),
    );
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, true);
    try std.testing.expectEqual(stream_wake.NotifyResult.stale, wake.notify());
}

test "stream wake start rollback and fatal cleanup preserve ownership order" {
    var failed_start: Wakes = undefined;
    var retry_io = TestIo{};
    try failed_start.init(0);
    retry_io.injectSubmitFailure();
    try std.testing.expectError(error.WakeControlFailed, failed_start.start(&retry_io));
    try failed_start.start(&retry_io);
    try failed_start.confirmPublishersJoined();
    try completeCanceledStop(&failed_start, &retry_io, true);

    var fatal: Wakes = undefined;
    var fatal_io = TestIo{};
    try started(&fatal, &fatal_io);
    const wake = try fatal.activate(0);
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        fatal.invalidateBeforeAbort(wake),
    );
    try fatal.confirmPublishersJoined();
    try fatal.beginFatalAfterPublishersJoined();
    try std.testing.expectEqual(stream_wake.Phase.fatal, fatal.phase());
    const status = try fatal_io.abort();
    try std.testing.expect(status.ownership_proven);
    try fatal.finishFatalAfterBackend();
    try std.testing.expectEqual(stream_wake.Phase.stopped, fatal.phase());
}

test "stream wake normal stop drains ready target in either completion order" {
    try completeReadyStop(false);
    try completeReadyStop(true);
}

const RaceContext = struct {
    wake: stream_wake.StreamWake,
    requested: *std.atomic.Value(u32),
    completed: *std.atomic.Value(u32),
    iterations: u32,

    fn run(context: *RaceContext) void {
        var iteration: u32 = 1;
        while (iteration <= context.iterations) : (iteration += 1) {
            while (context.requested.load(.acquire) < iteration) {
                std.Thread.yield() catch {};
            }
            const result = context.wake.notify();
            std.debug.assert(result == .published or result == .coalesced);
            context.completed.store(iteration, .release);
        }
    }
};

const ConsumeContext = struct {
    wakes: *Wakes,
    io: *TestIo,
    event: Wakes.HandleEvent = undefined,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(context: *ConsumeContext) void {
        const poll = context.wakes.currentPollToken().?;
        context.io.complete(poll, .{ .success = .{ .wake = {} } }, false) catch {
            context.failed.store(true, .release);
            return;
        };
        context.event = context.wakes.handle(
            context.io,
            context.io.nextCompletion().?,
        ) catch {
            context.failed.store(true, .release);
            return;
        };
    }
};

fn runInventoryPublicationRace(point: stream_wake.ConsumePause) !void {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);
    const first = try wakes.activate(0);
    const second = try wakes.activate(64);
    try std.testing.expectEqual(stream_wake.NotifyResult.published, first.notify());

    Wakes.TestAccess.pauseConsume(point);
    defer Wakes.TestAccess.pauseConsume(.none);
    var context = ConsumeContext{ .wakes = &wakes, .io = &io };
    const thread = try std.Thread.spawn(.{}, ConsumeContext.run, .{&context});
    var attempts: u32 = 0;
    while (!Wakes.TestAccess.consumePaused() and !context.failed.load(.acquire)) {
        if (attempts == 1_000_000) {
            Wakes.TestAccess.pauseConsume(.none);
            thread.join();
            return error.ConsumePauseTimedOut;
        }
        attempts += 1;
        std.Thread.yield() catch {};
    }
    if (context.failed.load(.acquire)) {
        Wakes.TestAccess.pauseConsume(.none);
        thread.join();
        return error.ConsumeFailedBeforePause;
    }
    try std.testing.expectEqual(stream_wake.NotifyResult.published, second.notify());
    Wakes.TestAccess.pauseConsume(.none);
    thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expect(context.event.ready.contains(0));
    try std.testing.expect(!context.event.ready.contains(64));
    const retained = try completeWake(&wakes, &io);
    try std.testing.expect(!retained.ready.contains(0));
    try std.testing.expect(retained.ready.contains(64));
    try std.testing.expectEqual(stream_wake.ClaimResult.claimed, first.claimReady());
    try std.testing.expectEqual(stream_wake.ClaimResult.claimed, second.claimReady());
    try std.testing.expectEqual(.invalidated, wakes.invalidateBeforeAbort(first));
    try std.testing.expectEqual(.invalidated, wakes.invalidateBeforeAbort(second));
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, true);
}

test "stream wake cannot lose publication across inventory drain boundaries" {
    try runInventoryPublicationRace(.after_words);
    try runInventoryPublicationRace(.after_clear);
}

test "stream wake pending publication race is ThreadSanitizer clean" {
    var wakes: Wakes = undefined;
    var io = TestIo{};
    try started(&wakes, &io);
    const wake = try wakes.activate(0);
    var requested = std.atomic.Value(u32).init(0);
    var completed = std.atomic.Value(u32).init(0);
    var context = RaceContext{
        .wake = wake,
        .requested = &requested,
        .completed = &completed,
        .iterations = 2_000,
    };
    const thread = try std.Thread.spawn(.{}, RaceContext.run, .{&context});

    for (1..context.iterations + 1) |iteration| {
        requested.store(@intCast(iteration), .release);
        const pending = wake.markPending();
        try std.testing.expect(pending == .pending or pending == .ready);
        while (completed.load(.acquire) < iteration) std.Thread.yield() catch {};
        try std.testing.expectEqual(stream_wake.ClaimResult.claimed, wake.claimReady());
    }
    thread.join();

    const event = try completeWake(&wakes, &io);
    try std.testing.expect(event.ready.contains(0));
    try std.testing.expectEqual(
        stream_wake.InvalidateResult.invalidated,
        wakes.invalidateBeforeAbort(wake),
    );
    try wakes.confirmPublishersJoined();
    try completeCanceledStop(&wakes, &io, true);
}

test "stream wake pending model covers all three-operation schedules" {
    const Operation = enum { pending, notify, claim };
    const schedules = [_][3]Operation{
        .{ .pending, .notify, .claim },
        .{ .pending, .claim, .notify },
        .{ .notify, .pending, .claim },
        .{ .notify, .claim, .pending },
        .{ .claim, .pending, .notify },
        .{ .claim, .notify, .pending },
    };
    for (schedules) |schedule| {
        var wakes: Wakes = undefined;
        var io = TestIo{};
        try started(&wakes, &io);
        const wake = try wakes.activate(0);
        for (schedule) |operation| switch (operation) {
            .pending => _ = wake.markPending(),
            .notify => _ = wake.notify(),
            .claim => _ = wake.claimReady(),
        };
        if (wake.claimReady() == .not_ready) {
            try std.testing.expectEqual(stream_wake.NotifyResult.published, wake.notify());
            try std.testing.expectEqual(stream_wake.ClaimResult.claimed, wake.claimReady());
        }
        try std.testing.expectEqual(
            stream_wake.InvalidateResult.invalidated,
            wakes.invalidateBeforeAbort(wake),
        );
        try wakes.confirmPublishersJoined();
        try completeCanceledStop(&wakes, &io, true);
    }
}

const std = @import("std");

const deterministic_reactor = @import("../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../src/internal/runtime/reactor.zig");
const stream_lifecycle = @import("../../../src/internal/runtime/worker/stream_lifecycle.zig");

const TestIo = deterministic_reactor.DeterministicReactor(8);
const Lifecycle = stream_lifecycle.Lifecycle(true, 4);

fn completeStop(
    lifecycle: *Lifecycle,
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
}

fn invalidateAll(
    lifecycle: *Lifecycle,
    handles: *const [4]?stream_lifecycle.StreamWake,
    count: u16,
    reverse: bool,
    repeat: bool,
) !void {
    for (0..count) |offset| {
        const index = if (reverse) count - 1 - @as(u16, @intCast(offset)) else offset;
        const wake = handles[index].?;
        try std.testing.expectEqual(.invalidated, lifecycle.invalidateBeforeAbort(wake));
        if (repeat) {
            try std.testing.expectEqual(.stale, lifecycle.invalidateBeforeAbort(wake));
        }
    }
}

fn fuzzLifecycle(_: void, smith: *std.testing.Smith) !void {
    var io = TestIo{};
    var lifecycle = try Lifecycle.init(smith.valueRangeAtMost(u16, 0, 3));
    if (smith.value(bool)) {
        io.injectSubmitFailure();
        try std.testing.expectError(error.WakeControlFailed, lifecycle.start(&io));
    }
    try lifecycle.start(&io);

    const count = smith.valueRangeAtMost(u16, 1, 4);
    var handles: [4]?stream_lifecycle.StreamWake = .{ null, null, null, null };
    for (0..count) |index| handles[index] = try lifecycle.activate(@intCast(index));
    if (smith.value(bool)) {
        try std.testing.expectError(error.SlotActive, lifecycle.activate(0));
    }
    try std.testing.expectError(error.PublishersActive, lifecycle.confirmPublishersJoined());
    try std.testing.expectError(error.PublishersNotJoined, lifecycle.beginStop(&io));

    const ready = smith.value(bool);
    if (ready) {
        try std.testing.expectEqual(.published, handles[0].?.notify());
    }
    try invalidateAll(
        &lifecycle,
        &handles,
        count,
        smith.value(bool),
        smith.value(bool),
    );
    try lifecycle.confirmPublishersJoined();
    if (smith.value(bool)) {
        try std.testing.expectEqual(.stale, handles[0].?.notify());
    }

    if (smith.value(bool)) {
        try lifecycle.beginFatalAfterPublishersJoined();
        const status = try io.abort();
        try std.testing.expect(status.ownership_proven);
        try lifecycle.finishFatalAfterBackend();
    } else {
        try completeStop(&lifecycle, &io, ready, smith.value(bool));
    }
    try std.testing.expect(lifecycle.isStopped());
    try std.testing.expectEqual(@as(u8, 0), lifecycle.status().operations);
    try std.testing.expectEqual(@as(u16, 0), lifecycle.status().active_publishers);
}

test "stream lifecycle bounded ownership schedule fuzz" {
    try std.testing.fuzz({}, fuzzLifecycle, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = [_][]const u8{
    &([_]u8{0x00} ** 32),
    &([_]u8{0xff} ** 32),
    &([_]u8{ 0x01, 0x00, 0x01, 0x00 } ** 8),
    &([_]u8{ 0x00, 0x01, 0x00, 0x01 } ** 8),
};

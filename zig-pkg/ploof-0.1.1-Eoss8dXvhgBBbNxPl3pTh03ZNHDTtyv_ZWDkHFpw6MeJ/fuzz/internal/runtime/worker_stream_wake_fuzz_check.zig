const std = @import("std");

const deterministic_reactor = @import("../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../src/internal/runtime/reactor.zig");
const stream_wake = @import("../../../src/internal/runtime/worker/stream_wake.zig");

const SlotModel = struct {
    active: bool = false,
    ready: bool = false,
    pending: bool = false,
    inventoried: bool = false,
};

const TestIo = deterministic_reactor.DeterministicReactor(16);
const Wakes = stream_wake.Fixed(65);

const Harness = struct {
    wakes: Wakes = undefined,
    io: TestIo = .{},
    handles: [2]?stream_wake.StreamWake = .{ null, null },
    stale: [2]?stream_wake.StreamWake = .{ null, null },
    model: [2]SlotModel = .{ .{}, .{} },
    stale_count: u64 = 0,

    fn init(self: *Harness) !void {
        self.* = .{};
        try self.wakes.init(0);
        try self.wakes.start(&self.io);
    }

    fn prepare(self: *Harness) !void {
        try self.cleanupIteration();
        for (0..2) |index| {
            self.handles[index] = try self.wakes.activate(slotIndex(@intCast(index)));
            self.model[index] = .{ .active = true };
        }
    }

    fn step(self: *Harness, encoded: u8) !void {
        const index: u1 = @truncate(encoded);
        switch ((encoded >> 1) % 8) {
            0 => try self.notify(index, false),
            1 => try self.pending(index),
            2 => try self.claim(index),
            3 => try self.consume(),
            4 => try self.invalidate(index),
            5 => try self.reactivate(index),
            6 => try self.notify(index, true),
            7 => {
                try self.notify(index, false);
                try self.pending(index);
                try self.claim(index);
            },
            else => unreachable,
        }
    }

    fn notify(self: *Harness, index: u1, use_stale: bool) !void {
        const candidate = if (use_stale) self.stale[index] else self.handles[index];
        const wake = candidate orelse return;
        const current = !use_stale and self.model[index].active;
        const expected: stream_wake.NotifyResult = if (!current)
            .stale
        else if (self.model[index].ready)
            .coalesced
        else
            .published;
        try std.testing.expectEqual(expected, wake.notify());
        if (expected == .stale) self.stale_count +|= 1;
        try std.testing.expectEqual(
            self.stale_count,
            self.wakes.staleNotificationCount(),
        );
        if (expected == .published) {
            self.model[index].ready = true;
            self.model[index].inventoried = true;
        }
    }

    fn pending(self: *Harness, index: u1) !void {
        const wake = self.handles[index] orelse return;
        const expected: stream_wake.PendingResult = if (!self.model[index].active)
            .stale
        else if (self.model[index].ready)
            .ready
        else
            .pending;
        try std.testing.expectEqual(expected, wake.markPending());
        if (expected == .pending) self.model[index].pending = true;
    }

    fn claim(self: *Harness, index: u1) !void {
        const wake = self.handles[index] orelse return;
        const expected: stream_wake.ClaimResult = if (!self.model[index].active)
            .stale
        else if (self.model[index].ready)
            .claimed
        else
            .not_ready;
        try std.testing.expectEqual(expected, wake.claimReady());
        if (expected == .claimed) {
            self.model[index].ready = false;
            self.model[index].pending = false;
        }
    }

    fn consume(self: *Harness) !void {
        if (!self.inventoryPending()) return;
        const poll = self.wakes.currentPollToken().?;
        try self.io.complete(poll, .{ .success = .{ .wake = {} } }, false);
        const event = try self.wakes.handle(&self.io, self.io.nextCompletion().?);
        try std.testing.expect(!event.stopped);
        for (0..2) |index| {
            try std.testing.expectEqual(
                self.model[index].inventoried,
                event.ready.contains(slotIndex(@intCast(index))),
            );
            self.model[index].inventoried = false;
        }
    }

    fn invalidate(self: *Harness, index: u1) !void {
        const wake = self.handles[index] orelse return;
        const expected: stream_wake.InvalidateResult = if (self.model[index].active)
            .invalidated
        else
            .stale;
        try std.testing.expectEqual(expected, self.wakes.invalidateBeforeAbort(wake));
        if (expected == .invalidated) {
            self.stale[index] = wake;
            self.model[index].active = false;
            self.model[index].ready = false;
            self.model[index].pending = false;
        }
    }

    fn reactivate(self: *Harness, index: u1) !void {
        if (self.model[index].active) {
            try std.testing.expectError(
                error.SlotActive,
                self.wakes.activate(slotIndex(index)),
            );
            return;
        }
        self.handles[index] = try self.wakes.activate(slotIndex(index));
        self.model[index].active = true;
        self.model[index].ready = false;
        self.model[index].pending = false;
    }

    fn cleanupIteration(self: *Harness) !void {
        try self.consume();
        for (0..2) |index| {
            if (!self.model[index].active) continue;
            const wake = self.handles[index].?;
            try std.testing.expectEqual(
                stream_wake.InvalidateResult.invalidated,
                self.wakes.invalidateBeforeAbort(wake),
            );
            self.stale[index] = wake;
            self.model[index] = .{};
        }
        try std.testing.expectEqual(@as(u16, 0), self.wakes.activeCount());
    }

    fn deinit(self: *Harness, cancel_first: bool) !void {
        try self.cleanupIteration();
        try self.wakes.confirmPublishersJoined();
        const poll = self.wakes.currentPollToken().?;
        try self.wakes.beginStop(&self.io);
        const cancel = self.wakes.currentCancelToken().?;
        if (cancel_first) {
            try self.completeStop(cancel, .{ .success = .{ .cancel = .canceled } });
            try self.completeStop(poll, .{ .failure = .canceled });
        } else {
            try self.completeStop(poll, .{ .failure = .canceled });
            try self.completeStop(cancel, .{ .success = .{ .cancel = .canceled } });
        }
        try std.testing.expectEqual(stream_wake.Phase.stopped, self.wakes.phase());
    }

    fn completeStop(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
    ) !void {
        try self.io.complete(token, result, false);
        _ = try self.wakes.handle(&self.io, self.io.nextCompletion().?);
    }

    fn inventoryPending(self: *const Harness) bool {
        for (self.model) |slot| if (slot.inventoried) return true;
        return false;
    }
};

fn slotIndex(logical: u1) u16 {
    return if (logical == 0) 0 else 64;
}

fn fuzzSchedule(harness: *Harness, smith: *std.testing.Smith) !void {
    var storage: [128]u8 = undefined;
    const actions = storage[0..smith.slice(&storage)];
    try harness.prepare();
    for (actions) |action| try harness.step(action);
    try harness.cleanupIteration();
}

test "stream wake bounded publication schedule fuzz" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit(true) catch @panic("stream wake fuzz cleanup failed");
    try std.testing.fuzz(&harness, fuzzSchedule, .{ .corpus = &fuzz_corpus });
}

fn corpus(comptime actions: []const u8) [actions.len + 4]u8 {
    var input: [actions.len + 4]u8 = undefined;
    const length: u32 = @intCast(actions.len);
    std.mem.writeInt(u32, input[0..4], length, .little);
    @memcpy(input[4..], actions);
    return input;
}

const fuzz_corpus = struct {
    const pending_race = corpus(&.{ 2, 0, 4, 6, 4 });
    const send_retained = corpus(&.{ 0, 6, 6, 4, 6, 4 });
    const reuse_stale = corpus(&.{ 8, 12, 10, 0, 4, 6 });
    const cross_word = corpus(&.{ 0, 1, 6, 7, 4, 5 });

    const values = [_][]const u8{
        &pending_race,
        &send_retained,
        &reuse_stale,
        &cross_word,
    };
}.values;

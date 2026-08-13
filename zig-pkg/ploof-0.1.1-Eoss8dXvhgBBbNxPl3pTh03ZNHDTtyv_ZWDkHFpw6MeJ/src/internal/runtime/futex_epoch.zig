const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const waiting_bit: u32 = 1 << 31;
const epoch_mask: u32 = waiting_bit - 1;
var test_pause_notify = std.atomic.Value(bool).init(false);
var test_notify_paused = std.atomic.Value(bool).init(false);
var test_spurious_wake = std.atomic.Value(bool).init(false);
var test_spurious_consumed = std.atomic.Value(bool).init(false);

pub const TimedWait = enum(u8) {
    notified,
    timed_out,
    interrupted,
};

/// One-waiter futex generation. Packing the waiter bit with the epoch prevents
/// an old notifier from clearing a waiter armed for a later generation.
pub const Event = struct {
    word: std.atomic.Value(u32) = .init(0),

    pub fn observe(self: *const Event) u32 {
        const current = self.word.load(.acquire);
        if (current & waiting_bit != 0) @panic("futex epoch already has a waiter");
        return current;
    }

    /// Arms only if no notification followed the caller's condition check.
    pub fn arm(self: *Event, observed: u32) bool {
        if (observed & waiting_bit != 0) @panic("futex epoch observation invalid");
        return self.word.cmpxchgStrong(
            observed,
            observed | waiting_bit,
            .seq_cst,
            .acquire,
        ) == null;
    }

    pub fn wait(self: *Event, observed: u32) void {
        const expected = observed | waiting_bit;
        while (true) {
            if (comptime builtin.is_test) {
                if (test_spurious_wake.swap(false, .acq_rel)) {
                    test_spurious_consumed.store(true, .release);
                    if (self.word.load(.acquire) == expected) continue else return;
                }
            }
            switch (linux.errno(linux.futex_4arg(
                &self.word.raw,
                .{ .cmd = .WAIT, .private = true },
                expected,
                null,
            ))) {
                .SUCCESS => if (self.word.load(.acquire) == expected) continue else return,
                .AGAIN => return,
                .INTR => continue,
                else => @panic("futex epoch wait failed"),
            }
        }
    }

    /// Bounded one-waiter sleep. Timeout and interruption disarm their waiter
    /// bit unless a notification won the same atomic race.
    pub fn waitFor(self: *Event, observed: u32, remaining_ns: u64) TimedWait {
        const expected = observed | waiting_bit;
        const timeout = linux.timespec{
            .sec = @intCast(remaining_ns / std.time.ns_per_s),
            .nsec = @intCast(remaining_ns % std.time.ns_per_s),
        };
        const result = linux.futex_4arg(
            &self.word.raw,
            .{ .cmd = .WAIT, .private = true },
            expected,
            &timeout,
        );
        return switch (linux.errno(result)) {
            .SUCCESS, .AGAIN => if (self.disarm(observed, expected))
                .interrupted
            else
                .notified,
            .INTR => if (self.disarm(observed, expected)) .interrupted else .notified,
            .TIMEDOUT => if (self.disarm(observed, expected)) .timed_out else .notified,
            else => @panic("futex epoch timed wait failed"),
        };
    }

    /// Publishes prior condition writes, advances the epoch, and consumes only
    /// the waiter that was part of the same atomic observation.
    pub fn notify(self: *Event) void {
        var current = self.word.load(.monotonic);
        while (true) {
            const next = ((current & epoch_mask) +% 1) & epoch_mask;
            if (self.word.cmpxchgWeak(current, next, .release, .monotonic)) |actual| {
                current = actual;
                continue;
            }
            pauseNotifyForTest();
            if (current & waiting_bit != 0) wake(&self.word);
            return;
        }
    }

    /// Quiescent-only reset after the waiter has stopped.
    pub fn reset(self: *Event) void {
        if (self.waiting()) @panic("cannot reset futex epoch with waiter");
        self.word.store(0, .monotonic);
    }

    pub fn waiting(self: *const Event) bool {
        return self.word.load(.acquire) & waiting_bit != 0;
    }

    pub fn epoch(self: *const Event) u32 {
        return self.word.load(.acquire) & epoch_mask;
    }

    fn disarm(self: *Event, observed: u32, expected: u32) bool {
        return self.word.cmpxchgStrong(
            expected,
            observed,
            .acq_rel,
            .acquire,
        ) == null;
    }
};

pub const TestAccess = if (builtin.is_test) struct {
    pub fn pauseNotify(enabled: bool) void {
        test_pause_notify.store(enabled, .release);
    }

    pub fn notifyPaused() bool {
        return test_notify_paused.load(.acquire);
    }

    pub fn injectSpuriousWake() void {
        test_spurious_consumed.store(false, .release);
        test_spurious_wake.store(true, .release);
    }

    pub fn spuriousConsumed() bool {
        return test_spurious_consumed.load(.acquire);
    }
} else struct {};

fn pauseNotifyForTest() void {
    if (!builtin.is_test or !test_pause_notify.load(.acquire)) return;
    test_notify_paused.store(true, .release);
    while (test_pause_notify.load(.acquire)) std.Thread.yield() catch {};
    test_notify_paused.store(false, .release);
}

fn wake(word: *const std.atomic.Value(u32)) void {
    switch (linux.errno(linux.futex_3arg(
        &word.raw,
        .{ .cmd = .WAKE, .private = true },
        1,
    ))) {
        .SUCCESS => {},
        else => @panic("futex epoch wake failed"),
    }
}

test "futex epoch closes notification races and wraps" {
    var event = Event{};
    const stale = event.observe();
    event.notify();
    try std.testing.expect(!event.arm(stale));

    const before_wait = event.observe();
    try std.testing.expect(event.arm(before_wait));
    event.notify();
    event.wait(before_wait);
    try std.testing.expectEqual(@as(u32, 2), event.observe());

    event.word.store(epoch_mask, .monotonic);
    const before_wrap = event.observe();
    try std.testing.expect(event.arm(before_wrap));
    event.notify();
    try std.testing.expectEqual(@as(u32, 0), event.observe());
    event.reset();
    try std.testing.expectEqual(@as(u32, 0), event.observe());
}

test "futex epoch old wake cannot consume a later waiter" {
    var event = Event{};
    const first = event.observe();
    try std.testing.expect(event.arm(first));
    TestAccess.pauseNotify(false);
    defer TestAccess.pauseNotify(false);
    TestAccess.pauseNotify(true);

    const thread = try std.Thread.spawn(.{}, Event.notify, .{&event});
    try waitForBoolTest(TestAccess.notifyPaused);
    const second = event.observe();
    try std.testing.expect(event.arm(second));
    TestAccess.pauseNotify(false);
    thread.join();

    try std.testing.expect(event.waiting());
    try std.testing.expectEqual(@as(u32, 1), event.epoch());
    event.notify();
    try std.testing.expectEqual(@as(u32, 2), event.observe());
}

test "futex epoch ignores wake without generation change" {
    const Harness = struct {
        event: *Event,
        observed: u32,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.event.wait(self.observed);
            self.done.store(true, .release);
        }
    };
    var event = Event{};
    const observed = event.observe();
    try std.testing.expect(event.arm(observed));
    TestAccess.injectSpuriousWake();
    var harness = Harness{ .event = &event, .observed = observed };
    const thread = try std.Thread.spawn(.{}, Harness.run, .{&harness});
    try waitForBoolTest(TestAccess.spuriousConsumed);
    try std.testing.expect(!harness.done.load(.acquire));
    event.notify();
    thread.join();
    try std.testing.expect(harness.done.load(.acquire));
}

test "timed futex wait clears waiter ownership on timeout" {
    var event = Event{};
    const observed = event.observe();
    try std.testing.expect(event.arm(observed));
    try std.testing.expectEqual(TimedWait.timed_out, event.waitFor(observed, 1));
    try std.testing.expect(!event.waiting());
    try std.testing.expectEqual(observed, event.observe());
}

fn waitForBoolTest(comptime value: fn () bool) !void {
    for (0..1_000_000) |_| {
        if (value()) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

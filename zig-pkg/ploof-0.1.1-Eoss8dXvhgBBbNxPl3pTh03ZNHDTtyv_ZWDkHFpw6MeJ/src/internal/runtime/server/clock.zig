const std = @import("std");
const linux = std.os.linux;

const worker = @import("../worker.zig");

pub const Error = error{
    MonotonicClockUnavailable,
    RealtimeClockUnavailable,
    ClockOutOfRange,
};

pub const Clock = struct {
    const refresh_interval_ns = std.time.ns_per_s;

    base_monotonic_ns: u64 = 0,
    base_epoch_second: i64 = 0,
    refresh_deadline_ns: u64 = 0,
    base_realtime_nanosecond: u32 = 0,
    initialized: bool = false,

    pub fn sample(self: *Clock) Error!worker.ClockSample {
        return self.sampleFrom(SystemSource{});
    }

    fn sampleFrom(self: *Clock, source: anytype) Error!worker.ClockSample {
        const monotonic_ns = try source.monotonic();
        if (!self.initialized or monotonic_ns >= self.refresh_deadline_ns) {
            return self.resync(source, monotonic_ns);
        }
        if (monotonic_ns < self.base_monotonic_ns) return error.ClockOutOfRange;
        return .{
            .monotonic_ns = monotonic_ns,
            .epoch_second = try self.derivedEpochSecond(monotonic_ns),
        };
    }

    fn resync(
        self: *Clock,
        source: anytype,
        monotonic_ns: u64,
    ) Error!worker.ClockSample {
        if (self.initialized and monotonic_ns < self.base_monotonic_ns) {
            return error.ClockOutOfRange;
        }
        const realtime = try source.realtime();
        self.base_monotonic_ns = monotonic_ns;
        self.base_epoch_second = realtime.epoch_second;
        self.base_realtime_nanosecond = realtime.nanosecond;
        self.refresh_deadline_ns = std.math.add(
            u64,
            monotonic_ns,
            refresh_interval_ns,
        ) catch std.math.maxInt(u64);
        self.initialized = true;
        return .{
            .monotonic_ns = monotonic_ns,
            .epoch_second = realtime.epoch_second,
        };
    }

    fn derivedEpochSecond(self: *const Clock, monotonic_ns: u64) Error!i64 {
        const elapsed_ns = monotonic_ns - self.base_monotonic_ns;
        const elapsed_seconds = elapsed_ns / std.time.ns_per_s;
        const elapsed_remainder = elapsed_ns % std.time.ns_per_s;
        const nanoseconds = elapsed_remainder + self.base_realtime_nanosecond;
        const carry = nanoseconds / std.time.ns_per_s;
        const delta_u64 = std.math.add(u64, elapsed_seconds, carry) catch {
            return error.ClockOutOfRange;
        };
        const delta = std.math.cast(i64, delta_u64) orelse return error.ClockOutOfRange;
        return std.math.add(i64, self.base_epoch_second, delta) catch {
            return error.ClockOutOfRange;
        };
    }
};

const Realtime = struct {
    epoch_second: i64,
    nanosecond: u32,
};

const SystemSource = struct {
    fn monotonic(_: SystemSource) Error!u64 {
        return monotonicNow();
    }

    fn realtime(_: SystemSource) Error!Realtime {
        return realtimeNow();
    }
};

pub fn monotonicNow() Error!u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.MonotonicClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0 or value.nsec >= std.time.ns_per_s) {
        return error.ClockOutOfRange;
    }
    const seconds = std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s) catch {
        return error.ClockOutOfRange;
    };
    return std.math.add(u64, seconds, @intCast(value.nsec)) catch {
        return error.ClockOutOfRange;
    };
}

pub fn epochSecond() Error!i64 {
    return (try realtimeNow()).epoch_second;
}

fn realtimeNow() Error!Realtime {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &value)) != .SUCCESS) {
        return error.RealtimeClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0 or value.nsec >= std.time.ns_per_s) {
        return error.ClockOutOfRange;
    }
    return .{
        .epoch_second = value.sec,
        .nanosecond = @intCast(value.nsec),
    };
}

const FakeSource = struct {
    monotonic_ns: u64,
    realtime_value: Realtime,
    monotonic_reads: u16 = 0,
    realtime_reads: u16 = 0,

    fn monotonic(self: *FakeSource) Error!u64 {
        self.monotonic_reads += 1;
        return self.monotonic_ns;
    }

    fn realtime(self: *FakeSource) Error!Realtime {
        self.realtime_reads += 1;
        return self.realtime_value;
    }
};

test "clock derives epoch seconds without repeated realtime reads" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Clock));
    var source = FakeSource{
        .monotonic_ns = 100,
        .realtime_value = .{ .epoch_second = 10, .nanosecond = 800_000_000 },
    };
    var clock = Clock{};
    const first = try clock.sampleFrom(&source);
    try std.testing.expectEqual(@as(i64, 10), first.epoch_second);

    source.monotonic_ns += 300_000_000;
    const second = try clock.sampleFrom(&source);
    try std.testing.expectEqual(@as(i64, 11), second.epoch_second);
    try std.testing.expectEqual(@as(u16, 2), source.monotonic_reads);
    try std.testing.expectEqual(@as(u16, 1), source.realtime_reads);
}

test "clock resyncs once per second and adopts realtime clock steps" {
    var source = FakeSource{
        .monotonic_ns = 7,
        .realtime_value = .{ .epoch_second = 100, .nanosecond = 250_000_000 },
    };
    var clock = Clock{};
    _ = try clock.sampleFrom(&source);

    source.monotonic_ns += std.time.ns_per_s - 1;
    source.realtime_value.epoch_second = 5;
    try std.testing.expectEqual(@as(i64, 101), (try clock.sampleFrom(&source)).epoch_second);
    try std.testing.expectEqual(@as(u16, 1), source.realtime_reads);

    source.monotonic_ns += 1;
    try std.testing.expectEqual(@as(i64, 5), (try clock.sampleFrom(&source)).epoch_second);
    try std.testing.expectEqual(@as(u16, 2), source.realtime_reads);
}

test "clock rejects monotonic regression before reading realtime" {
    var source = FakeSource{
        .monotonic_ns = 20,
        .realtime_value = .{ .epoch_second = 10, .nanosecond = 0 },
    };
    var clock = Clock{};
    _ = try clock.sampleFrom(&source);
    source.monotonic_ns = 19;
    try std.testing.expectError(error.ClockOutOfRange, clock.sampleFrom(&source));
    try std.testing.expectEqual(@as(u16, 1), source.realtime_reads);
}

test "clock saturates refresh deadline at the monotonic range limit" {
    var source = FakeSource{
        .monotonic_ns = std.math.maxInt(u64) - 1,
        .realtime_value = .{ .epoch_second = 10, .nanosecond = 0 },
    };
    var clock = Clock{};
    _ = try clock.sampleFrom(&source);
    try std.testing.expectEqual(std.math.maxInt(u64), clock.refresh_deadline_ns);
    try std.testing.expectEqual(@as(i64, 10), (try clock.sampleFrom(&source)).epoch_second);
    try std.testing.expectEqual(@as(u16, 1), source.realtime_reads);
}

test "production clock returns ordered valid worker samples" {
    var clock = Clock{};
    const first = try clock.sample();
    const second = try clock.sample();
    try std.testing.expect(second.monotonic_ns >= first.monotonic_ns);
    try std.testing.expect(first.epoch_second > 0);
    try std.testing.expect(second.epoch_second >= first.epoch_second);
}

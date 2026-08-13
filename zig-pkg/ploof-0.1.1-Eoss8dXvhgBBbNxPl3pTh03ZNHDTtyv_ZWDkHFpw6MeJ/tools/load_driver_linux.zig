const std = @import("std");
const linux = std.os.linux;

pub fn pollWait(polls: []linux.pollfd, wait_ns: u64) !void {
    var timeout = timeoutSpec(wait_ns);
    const raw = linux.ppoll(polls.ptr, polls.len, &timeout, null);
    switch (linux.errno(raw)) {
        .SUCCESS, .INTR => return,
        else => return error.PollFailed,
    }
}

pub fn timeoutSpec(wait_ns: u64) linux.timespec {
    return .{
        .sec = @intCast(wait_ns / std.time.ns_per_s),
        .nsec = @intCast(wait_ns % std.time.ns_per_s),
    };
}

pub fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS or
        value.sec < 0 or value.nsec < 0 or value.nsec >= std.time.ns_per_s)
    {
        return error.ClockUnavailable;
    }
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    return std.math.add(u64, seconds, @intCast(value.nsec));
}

pub fn addTime(base: u64, delta: u64) !u64 {
    return std.math.add(u64, base, delta);
}

pub fn rate(count: u64, duration_ns: u64) u64 {
    if (duration_ns == 0) return 0;
    const scaled = @as(u128, count) * std.time.ns_per_s / duration_ns;
    return @intCast(@min(scaled, std.math.maxInt(u64)));
}

test "nanosecond timeout and saturating rate are exact" {
    try std.testing.expectEqual(
        linux.timespec{ .sec = 2, .nsec = 3 },
        timeoutSpec(2 * std.time.ns_per_s + 3),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), rate(std.math.maxInt(u64), 1));
}

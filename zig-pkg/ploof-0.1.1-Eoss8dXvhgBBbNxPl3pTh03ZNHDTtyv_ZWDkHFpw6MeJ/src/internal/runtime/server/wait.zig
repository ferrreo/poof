const std = @import("std");
const linux = std.os.linux;

const event_counter = @import("../event_counter.zig");
const server_clock = @import("clock.zig");

pub const Event = enum(u8) {
    completion,
    signal,
    deadline,
};

pub const Error = server_clock.Error || error{
    PollFailed,
    InvalidDescriptorEvent,
};

/// Waits for worker completion and, when supplied, a blocked process signal.
/// Signal wins a simultaneous observation so a second signal forces promptly.
pub fn until(
    completion_fd: linux.fd_t,
    signal_fd: ?linux.fd_t,
    deadline_ns: u64,
) Error!Event {
    while (true) {
        const now_ns = try server_clock.monotonicNow();
        if (now_ns >= deadline_ns) return .deadline;
        var timeout = relativeTimeout(deadline_ns - now_ns);
        var descriptors = [2]linux.pollfd{
            pollDescriptor(completion_fd),
            pollDescriptor(signal_fd orelse -1),
        };
        const count: linux.nfds_t = if (signal_fd == null) 1 else 2;
        const result = linux.ppoll(&descriptors, count, &timeout, null);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (result == 0) return .deadline;
        if (signal_fd != null and readable(descriptors[1])) return .signal;
        if (readable(descriptors[0])) return .completion;
        if (invalid(descriptors[0]) or
            (signal_fd != null and invalid(descriptors[1])))
        {
            return error.InvalidDescriptorEvent;
        }
    }
}

fn relativeTimeout(remaining_ns: u64) linux.timespec {
    return .{
        .sec = @intCast(remaining_ns / std.time.ns_per_s),
        .nsec = @intCast(remaining_ns % std.time.ns_per_s),
    };
}

fn pollDescriptor(descriptor: linux.fd_t) linux.pollfd {
    return .{ .fd = descriptor, .events = linux.POLL.IN, .revents = 0 };
}

fn readable(descriptor: linux.pollfd) bool {
    return descriptor.revents & linux.POLL.IN != 0;
}

fn invalid(descriptor: linux.pollfd) bool {
    return descriptor.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0;
}

test "signal wins simultaneous readiness and completion remains readable" {
    var completion = try openCounter();
    defer _ = completion.close();
    var signal = try openCounter();
    defer _ = signal.close();
    try std.testing.expect(completion.signal() == null);
    try std.testing.expect(signal.signal() == null);
    const deadline = try std.math.add(u64, try server_clock.monotonicNow(), std.time.ns_per_s);
    try std.testing.expectEqual(
        Event.signal,
        try until(completion.descriptor, signal.descriptor, deadline),
    );
    try std.testing.expectEqual(@as(u64, 1), try drainCount(signal.drain()));
    try std.testing.expectEqual(
        Event.completion,
        try until(completion.descriptor, null, deadline),
    );
}

test "expired deadline never enters poll" {
    var completion = try openCounter();
    defer _ = completion.close();
    try std.testing.expectEqual(
        Event.deadline,
        try until(completion.descriptor, null, try server_clock.monotonicNow()),
    );
}

fn openCounter() !event_counter.Counter {
    return switch (event_counter.Counter.open()) {
        .opened => |counter| counter,
        .failed => error.TestUnexpectedResult,
    };
}

fn drainCount(result: event_counter.DrainResult) !u64 {
    return switch (result) {
        .count => |count| count,
        .empty, .failed => error.TestUnexpectedResult,
    };
}

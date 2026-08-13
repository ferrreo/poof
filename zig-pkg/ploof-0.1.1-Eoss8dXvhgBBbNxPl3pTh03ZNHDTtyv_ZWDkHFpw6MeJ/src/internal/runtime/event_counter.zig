const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

var test_fail_next_signal = std.atomic.Value(bool).init(false);

pub const Stage = enum(u8) {
    open,
    signal,
    drain,
    close,
};

pub const Failure = struct {
    stage: Stage,
    errno: linux.E,
};

pub const OpenResult = union(enum) {
    opened: Counter,
    failed: Failure,
};

pub const DrainResult = union(enum) {
    count: u64,
    empty,
    failed: Failure,
};

/// One nonblocking Linux event counter with explicit descriptor ownership.
pub const Counter = struct {
    descriptor: linux.fd_t,
    live: bool = true,

    pub fn open() OpenResult {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        const errno_value = linux.errno(result);
        if (errno_value != .SUCCESS) return failedOpen(errno_value);
        return .{ .opened = .{ .descriptor = @intCast(result) } };
    }

    pub fn signal(counter: *const Counter) ?Failure {
        if (!counter.live) return failure(.signal, .BADF);
        if (comptime builtin.is_test) {
            if (test_fail_next_signal.swap(false, .acq_rel)) return failure(.signal, .IO);
        }
        const value: u64 = 1;
        while (true) {
            const result = linux.write(
                counter.descriptor,
                std.mem.asBytes(&value).ptr,
                @sizeOf(u64),
            );
            switch (linux.errno(result)) {
                .SUCCESS => return if (result == @sizeOf(u64))
                    null
                else
                    failure(.signal, .IO),
                .INTR => continue,
                // A full counter is already readable, so this signal is coalesced.
                .AGAIN => return null,
                else => |errno_value| return failure(.signal, errno_value),
            }
        }
    }

    pub fn drain(counter: *const Counter) DrainResult {
        if (!counter.live) return .{ .failed = failure(.drain, .BADF) };
        var value: u64 = 0;
        while (true) {
            const result = linux.read(
                counter.descriptor,
                std.mem.asBytes(&value).ptr,
                @sizeOf(u64),
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != @sizeOf(u64) or value == 0) {
                        return .{ .failed = failure(.drain, .IO) };
                    }
                    return .{ .count = value };
                },
                .INTR => continue,
                .AGAIN => return .empty,
                else => |errno_value| return .{ .failed = failure(.drain, errno_value) },
            }
        }
    }

    pub fn close(counter: *Counter) ?Failure {
        if (!counter.live) return null;
        counter.live = false;
        const errno_value = linux.errno(linux.close(counter.descriptor));
        return if (errno_value == .SUCCESS) null else failure(.close, errno_value);
    }
};

pub const TestAccess = if (builtin.is_test) struct {
    pub fn failNextSignal() void {
        test_fail_next_signal.store(true, .release);
    }
} else struct {};

fn failedOpen(errno_value: linux.E) OpenResult {
    return .{ .failed = failure(.open, errno_value) };
}

fn failure(stage: Stage, errno_value: linux.E) Failure {
    return .{ .stage = stage, .errno = errno_value };
}

test "event counter is nonblocking close-on-exec and coalesces signals" {
    var counter = switch (Counter.open()) {
        .opened => |opened| opened,
        .failed => return error.EventCounterOpenFailed,
    };
    defer _ = counter.close();

    const status_flags = linux.fcntl(counter.descriptor, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_flags));
    try std.testing.expect(status_flags & linux.EFD.NONBLOCK != 0);
    const descriptor_flags = linux.fcntl(counter.descriptor, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_flags));
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);

    try expectEmpty(counter.drain());
    try std.testing.expectEqual(@as(?Failure, null), counter.signal());
    try std.testing.expectEqual(@as(?Failure, null), counter.signal());
    try std.testing.expectEqual(@as(u64, 2), try drainedCount(counter.drain()));
    try expectEmpty(counter.drain());
}

test "event counter close is idempotent and rejects later access" {
    var counter = switch (Counter.open()) {
        .opened => |opened| opened,
        .failed => return error.EventCounterOpenFailed,
    };
    try std.testing.expectEqual(@as(?Failure, null), counter.close());
    try std.testing.expectEqual(@as(?Failure, null), counter.close());
    try std.testing.expectEqual(linux.E.BADF, counter.signal().?.errno);
    switch (counter.drain()) {
        .failed => |problem| try std.testing.expectEqual(linux.E.BADF, problem.errno),
        else => return error.TestUnexpectedResult,
    }
}

fn drainedCount(result: DrainResult) !u64 {
    return switch (result) {
        .count => |count| count,
        .empty, .failed => error.TestUnexpectedResult,
    };
}

fn expectEmpty(result: DrainResult) !void {
    switch (result) {
        .empty => {},
        .count, .failed => return error.TestUnexpectedResult,
    }
}

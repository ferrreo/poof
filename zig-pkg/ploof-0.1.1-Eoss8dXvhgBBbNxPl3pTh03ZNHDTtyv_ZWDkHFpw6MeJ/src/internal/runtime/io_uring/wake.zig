const std = @import("std");
const linux = std.os.linux;

const reactor = @import("../reactor.zig");
const runtime_socket = @import("../socket.zig");

pub const SubmitError = error{ InvalidWakeSource, SubmissionQueueFull };

pub fn submit(
    ring: anytype,
    token: u64,
    source: reactor.WakeSource,
) SubmitError!void {
    const descriptor = runtime_socket.descriptor(.{ .value = source.value }) catch {
        return error.InvalidWakeSource;
    };
    _ = ring.poll_add(token, descriptor, linux.POLL.IN) catch {
        return error.SubmissionQueueFull;
    };
}

pub fn isExactPositive(completion: linux.io_uring_cqe) bool {
    return completion.res == @as(i32, @intCast(linux.POLL.IN)) and completion.flags == 0;
}

test "wake completion accepts only exact readable event" {
    const valid = linux.io_uring_cqe{ .user_data = 1, .res = linux.POLL.IN, .flags = 0 };
    try std.testing.expect(isExactPositive(valid));

    var invalid = valid;
    invalid.res = linux.POLL.IN | linux.POLL.OUT;
    try std.testing.expect(!isExactPositive(invalid));
    invalid = valid;
    invalid.res = 0;
    try std.testing.expect(!isExactPositive(invalid));
    invalid = valid;
    invalid.flags = linux.IORING_CQE_F_MORE;
    try std.testing.expect(!isExactPositive(invalid));
}

const std = @import("std");
const linux = std.os.linux;
const reactor = @import("../reactor.zig");
const runtime_socket = @import("../socket.zig");

pub const Result = union(enum) {
    sent: usize,
    would_block,
    failed: reactor.CompletionError,
};

pub fn write(socket: reactor.Socket, bytes: []const u8, more: bool) Result {
    const descriptor = runtime_socket.descriptor(socket) catch {
        return .{ .failed = .invalid_resource };
    };
    const flags: u32 = linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT |
        (if (more) @as(u32, linux.MSG.MORE) else 0);
    const result = linux.sendto(descriptor, bytes.ptr, bytes.len, flags, null, 0);
    return classify(result);
}

fn classify(result: usize) Result {
    return switch (linux.errno(result)) {
        .SUCCESS => if (result == 0) .{ .failed = .connection_reset } else .{ .sent = result },
        .AGAIN, .INTR => .would_block,
        .CONNABORTED => .{ .failed = .connection_aborted },
        .CONNRESET => .{ .failed = .connection_reset },
        .PIPE => .{ .failed = .broken_pipe },
        .NOTCONN => .{ .failed = .not_connected },
        else => .{ .failed = .backend_failure },
    };
}

test "direct send classifies bounded syscall results" {
    try std.testing.expectEqual(Result{ .sent = 7 }, classify(7));
    try std.testing.expectEqual(
        Result{ .failed = .connection_reset },
        classify(0),
    );
    const again: usize = @bitCast(-@as(isize, @intFromEnum(linux.E.AGAIN)));
    try std.testing.expectEqual(Result.would_block, classify(again));
}

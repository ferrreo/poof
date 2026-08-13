const std = @import("std");
const linux = std.os.linux;

const reactor = @import("reactor.zig");

pub const DiscardError = error{ InvalidSocket, CloseInterrupted, CloseFailed };

pub fn descriptor(socket: reactor.Socket) error{InvalidSocket}!linux.fd_t {
    if (socket.value > std.math.maxInt(linux.fd_t)) return error.InvalidSocket;
    return @intCast(socket.value);
}

pub fn discard(socket: reactor.Socket) DiscardError!void {
    const fd = descriptor(socket) catch return error.InvalidSocket;
    return switch (linux.errno(linux.close(fd))) {
        .SUCCESS => {},
        .INTR => error.CloseInterrupted,
        else => error.CloseFailed,
    };
}

test "socket descriptor conversion is bounded and exact" {
    try std.testing.expectEqual(@as(linux.fd_t, 7), try descriptor(.{ .value = 7 }));
    try std.testing.expectError(error.InvalidSocket, descriptor(.{
        .value = @as(u64, std.math.maxInt(linux.fd_t)) + 1,
    }));
}

const std = @import("std");

const server_metrics_request = @import("../server/metrics_request.zig");

pub const Phase = enum(u8) { idle, waiting, canceling, responding };

pub fn Lease(comptime enabled: bool) type {
    if (!enabled) return struct {};
    return struct {
        const Self = @This();

        ticket_generation: u64 = 0,
        stream_generation: u64 = 0,
        route_id: u16 = 0,
        phase: Phase = .idle,

        pub fn start(
            self: *Self,
            accepted_ticket: server_metrics_request.Ticket,
            stream_generation: u64,
            route_id: u16,
        ) void {
            std.debug.assert(self.phase == .idle);
            std.debug.assert(accepted_ticket.generation != 0 and stream_generation != 0);
            self.* = .{
                .ticket_generation = accepted_ticket.generation,
                .stream_generation = stream_generation,
                .route_id = route_id,
                .phase = .waiting,
            };
        }

        pub fn beginCancel(self: *Self) void {
            std.debug.assert(self.phase == .waiting);
            self.phase = .canceling;
        }

        pub fn beginResponse(self: *Self) void {
            std.debug.assert(self.phase == .waiting);
            self.phase = .responding;
            self.stream_generation = 0;
        }

        pub fn ticket(self: *const Self) server_metrics_request.Ticket {
            std.debug.assert(self.phase != .idle and self.ticket_generation != 0);
            return .{ .generation = self.ticket_generation };
        }

        pub fn clear(self: *Self) void {
            std.debug.assert(self.phase != .idle);
            self.* = .{};
        }
    };
}

test "metrics lease is zero-sized when route support is absent" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Lease(false)));
}

test "metrics lease keeps ticket through response terminal" {
    const Enabled = Lease(true);
    var lease = Enabled{};
    lease.start(.{ .generation = 5 }, 7, 11);
    lease.beginResponse();
    try std.testing.expectEqual(@as(u64, 5), lease.ticket().generation);
    try std.testing.expectEqual(@as(u64, 0), lease.stream_generation);
    lease.clear();
    try std.testing.expectEqual(Phase.idle, lease.phase);
    try std.testing.expect(@sizeOf(Enabled) <= 24);
}

const std = @import("std");

const server_metrics_service = @import("metrics_service.zig");

pub const Ticket = server_metrics_service.Ticket;
pub const WakeIdentity = server_metrics_service.WakeIdentity;
pub const Poll = server_metrics_service.Poll;
pub const Cancel = server_metrics_service.Cancel;

pub const Claim = union(enum) {
    accepted: Ticket,
    busy,
    stopping,
    deadline_overflow,
};

/// Fixed-size worker binding. Service calls stay statically specialized to App;
/// only the server-owned wake destination requires type erasure.
pub fn Runtime(comptime App: type) type {
    if (!App.open_metrics_enabled) return Disabled;
    const Service = server_metrics_service.Service(App);
    return struct {
        const Self = @This();

        service: *Service,
        wake_context: *anyopaque,
        wake_notify: server_metrics_service.WakeNotify,
        timeout_ns: u64,

        pub fn init(
            service: *Service,
            wake_context: *anyopaque,
            wake_notify: server_metrics_service.WakeNotify,
            timeout_ns: u64,
        ) Self {
            std.debug.assert(timeout_ns != 0);
            return .{
                .service = service,
                .wake_context = wake_context,
                .wake_notify = wake_notify,
                .timeout_ns = timeout_ns,
            };
        }

        pub fn claimAt(self: Self, now_ns: u64, identity: WakeIdentity) Claim {
            const deadline_ns = std.math.add(u64, now_ns, self.timeout_ns) catch {
                return .deadline_overflow;
            };
            return switch (self.service.claim(deadline_ns, .{
                .context = self.wake_context,
                .identity = identity,
                .notify = self.wake_notify,
            })) {
                .accepted => |ticket| .{ .accepted = ticket },
                .busy => .busy,
                .stopping => .stopping,
            };
        }

        pub fn poll(self: Self, ticket: Ticket) Poll {
            return self.service.poll(ticket);
        }

        pub fn cancel(self: Self, ticket: Ticket) Cancel {
            return self.service.cancel(ticket);
        }

        pub fn release(self: Self, ticket: Ticket) bool {
            return self.service.release(ticket);
        }
    };
}

pub const Disabled = struct {
    pub fn init() Disabled {
        return .{};
    }
};

test "disabled request runtime has no storage" {
    const App = struct {
        pub const open_metrics_enabled = false;
    };
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Runtime(App)));
}

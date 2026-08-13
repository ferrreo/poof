const application = @import("../../../application.zig");

pub const Disabled = struct {
    pub const enabled = false;

    pub fn init() Disabled {
        return .{};
    }

    pub fn sample(_: *Disabled, _: u64) void {}
    pub fn admit(_: *Disabled, _: u16, _: []const u8, _: ?u16, _: u64) !void {}
    pub fn addRequestWire(_: *Disabled, _: u16, _: u64) !void {}
    pub fn addRequestDecoded(_: *Disabled, _: u16, _: u64) !void {}
    pub fn addResponseWire(_: *Disabled, _: u16, _: u64) !void {}
    pub fn finish(_: *Disabled, _: u16, _: application.Outcome) !void {}
    pub fn latch(_: *Disabled, _: u16, _: application.Outcome) !void {}
    pub fn finishLatched(_: *Disabled, _: u16) !void {}
    pub fn latched(_: *const Disabled, _: u16) bool {
        return false;
    }
    pub fn releaseReady(_: *const Disabled, _: u16) bool {
        return true;
    }
};

pub fn Binding(comptime Controller: type) type {
    return struct {
        const Self = @This();
        pub const enabled = true;

        controller: *Controller,
        now_ns: u64 = 0,

        pub fn init(controller: *Controller) Self {
            return .{ .controller = controller };
        }

        pub fn sample(self: *Self, now_ns: u64) void {
            self.now_ns = now_ns;
        }

        pub fn admit(
            self: *Self,
            request_index: u16,
            method: []const u8,
            route_id: ?u16,
            head_wire_bytes: u64,
        ) !void {
            try self.controller.admit(
                request_index,
                method,
                route_id,
                self.now_ns,
                head_wire_bytes,
            );
        }

        pub fn addRequestWire(self: *Self, request_index: u16, count: u64) !void {
            try self.controller.addRequestWire(request_index, count);
        }

        pub fn addRequestDecoded(self: *Self, request_index: u16, count: u64) !void {
            try self.controller.addRequestDecoded(request_index, count);
        }

        pub fn addResponseWire(self: *Self, request_index: u16, count: u64) !void {
            try self.controller.addResponseWire(request_index, count);
        }

        pub fn finish(
            self: *Self,
            request_index: u16,
            outcome: application.Outcome,
        ) !void {
            _ = try self.controller.finish(request_index, outcome, self.now_ns);
        }

        pub fn latch(
            self: *Self,
            request_index: u16,
            outcome: application.Outcome,
        ) !void {
            try self.controller.latch(request_index, outcome);
        }

        pub fn finishLatched(self: *Self, request_index: u16) !void {
            _ = try self.controller.finishLatched(request_index, self.now_ns);
        }

        pub fn latched(self: *const Self, request_index: u16) bool {
            return self.controller.requestLatched(request_index);
        }

        pub fn releaseReady(self: *const Self, request_index: u16) bool {
            return self.controller.requestReleaseReady(request_index);
        }
    };
}

test "disabled observation binding has no runtime storage" {
    try @import("std").testing.expectEqual(@as(usize, 0), @sizeOf(Disabled));
}

test "enabled binding holds request ownership through a latched fallback" {
    const std = @import("std");
    const worker_observability = @import("../worker/observability.zig");
    const TestApp = struct {
        pub const route_definitions = [_]u8{0};
    };
    const Controller = worker_observability.Controller(
        TestApp,
        1,
        worker_observability.LoggingDisabled,
    );
    const Observed = Binding(Controller);
    var controller = Controller.init(.{});
    var observed = Observed.init(&controller);
    observed.sample(10);
    try observed.admit(0, "GET", 0, 9);
    try std.testing.expect(!observed.releaseReady(0));
    try std.testing.expect(!observed.releaseReady(1));
    const outcome = application.Outcome{
        .status = null,
        .mapped_error = false,
        .transport = .aborted,
    };
    try observed.latch(0, outcome);
    try observed.addResponseWire(0, 17);
    try std.testing.expect(observed.latched(0));
    try std.testing.expect(!observed.releaseReady(0));
    observed.sample(15);
    try observed.finishLatched(0);
    try std.testing.expect(!observed.latched(0));
    try std.testing.expect(observed.releaseReady(0));
    try std.testing.expectEqual(@as(u64, 1), controller.metrics.routes[0].completed);
    try std.testing.expectEqual(@as(u64, 17), controller.metrics.routes[0].response_wire_bytes);
    try std.testing.expectEqual(@as(u64, 1), controller.metrics.routes[0].latency[0]);
}

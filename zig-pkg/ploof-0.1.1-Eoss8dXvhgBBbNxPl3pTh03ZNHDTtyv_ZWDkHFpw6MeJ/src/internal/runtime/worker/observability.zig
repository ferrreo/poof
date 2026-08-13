const std = @import("std");

const access_log = @import("../../../access_log.zig");
const application = @import("../../../application.zig");
const metrics = @import("../../../metrics.zig");
const futex_epoch = @import("../futex_epoch.zig");
const request_observation = @import("../request_observation.zig");

pub const Error = request_observation.Error || error{
    InvalidRequest,
    InvalidRoute,
};

pub const LoggingDisabled = struct {
    pub const enabled = false;
    pub const Binding = struct {};
};

pub fn Logging(comptime capacity: u16) type {
    const EventRing = access_log.Ring(capacity);
    return struct {
        pub const enabled = true;
        pub const Ring = EventRing;
        pub const Binding = struct {
            ring: *EventRing,
            wake: *futex_epoch.Event,
        };
    };
}

pub fn Controller(
    comptime App: type,
    comptime request_slots: u16,
    comptime Log: type,
) type {
    if (request_slots == 0) {
        @compileError("PLOOF-E6500 observability request slot count is zero");
    }
    if (!@hasDecl(App, "route_definitions")) {
        @compileError("PLOOF-E6501 observability requires a Ploof Application type");
    }
    if (App.route_definitions.len > std.math.maxInt(u16)) {
        @compileError("PLOOF-E6502 observability route count exceeds u16");
    }
    if (!@hasDecl(Log, "enabled") or !@hasDecl(Log, "Binding")) {
        @compileError("PLOOF-E6503 observability logging configuration is invalid");
    }
    const route_count: u16 = @intCast(App.route_definitions.len);
    const WorkerMetrics = metrics.Worker(route_count);

    return struct {
        const Self = @This();

        metrics: WorkerMetrics = .{},
        requests: [request_slots]request_observation.Tracker =
            [_]request_observation.Tracker{.{}} ** request_slots,
        logging: Log.Binding,

        pub fn init(logging: Log.Binding) Self {
            return .{ .logging = logging };
        }

        pub fn admit(
            controller: *Self,
            request_index: u16,
            method: []const u8,
            route_id: ?u16,
            started_ns: u64,
            head_wire_bytes: u64,
        ) Error!void {
            const selected_tracker = try controller.tracker(request_index);
            if (route_id) |selected| {
                if (selected >= route_count) return error.InvalidRoute;
            }
            try selected_tracker.begin(method, route_id, started_ns, head_wire_bytes);
            controller.metrics.admit(route_id, selected_tracker.method);
        }

        pub fn addRequestWire(
            controller: *Self,
            request_index: u16,
            count: u64,
        ) Error!void {
            try (try controller.tracker(request_index)).addRequestWire(count);
        }

        pub fn addRequestDecoded(
            controller: *Self,
            request_index: u16,
            count: u64,
        ) Error!void {
            try (try controller.tracker(request_index)).addRequestDecoded(count);
        }

        pub fn addResponseWire(
            controller: *Self,
            request_index: u16,
            count: u64,
        ) Error!void {
            try (try controller.tracker(request_index)).addResponseWire(count);
        }

        pub fn finish(
            controller: *Self,
            request_index: u16,
            outcome: application.Outcome,
            finished_ns: u64,
        ) Error!request_observation.Observation {
            const observation = try (try controller.tracker(request_index)).finish(
                outcome,
                finished_ns,
            );
            controller.record(observation);
            return observation;
        }

        pub fn latch(
            controller: *Self,
            request_index: u16,
            outcome: application.Outcome,
        ) Error!void {
            try (try controller.tracker(request_index)).latch(outcome);
        }

        pub fn finishLatched(
            controller: *Self,
            request_index: u16,
            finished_ns: u64,
        ) Error!request_observation.Observation {
            const observation = try (try controller.tracker(request_index)).finishLatched(
                finished_ns,
            );
            controller.record(observation);
            return observation;
        }

        pub fn requestLive(controller: *const Self, request_index: u16) bool {
            if (request_index >= request_slots) return false;
            return controller.requests[request_index].live;
        }

        pub fn requestLatched(controller: *const Self, request_index: u16) bool {
            if (request_index >= request_slots) return false;
            return controller.requests[request_index].latched_outcome != null;
        }

        pub fn requestReleaseReady(controller: *const Self, request_index: u16) bool {
            if (request_index >= request_slots) return false;
            return !controller.requests[request_index].live;
        }

        fn record(controller: *Self, observation: request_observation.Observation) void {
            controller.metrics.complete(
                observation.route_id,
                observation.metricCompletion(),
            );
            if (comptime Log.enabled) controller.log(observation.accessEvent());
        }

        fn log(controller: *Self, event: access_log.AccessEvent) void {
            if (controller.logging.ring.push(event)) {
                controller.logging.wake.notify();
            } else {
                controller.metrics.runtime.record(.access_events_dropped);
            }
        }

        fn tracker(
            controller: *Self,
            request_index: u16,
        ) error{InvalidRequest}!*request_observation.Tracker {
            if (request_index >= request_slots) return error.InvalidRequest;
            return &controller.requests[request_index];
        }
    };
}

const TestApp = struct {
    pub const route_definitions = [_]u8{ 0, 1 };
};

test "disabled logging records a complete request with no logging storage" {
    const Observability = Controller(TestApp, 2, LoggingDisabled);
    var controller = Observability.init(.{});
    try controller.admit(0, "GET", 1, 100, 48);
    try controller.addRequestDecoded(0, 7);
    try controller.addResponseWire(0, 32);
    const observation = try controller.finish(
        0,
        .{ .status = .ok, .mapped_error = false, .transport = .completed },
        125,
    );
    try std.testing.expectEqual(@as(u64, 25), observation.duration_ns);
    try std.testing.expectEqual(@as(u64, 1), controller.metrics.routes[1].completed);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(LoggingDisabled.Binding));
}

test "enabled logging wakes on enqueue and counts saturation without blocking" {
    const Log = Logging(1);
    const Observability = Controller(TestApp, 2, Log);
    var ring = Log.Ring{};
    var wake = futex_epoch.Event{};
    var controller = Observability.init(.{ .ring = &ring, .wake = &wake });
    try controller.admit(0, "OPTIONS", null, 1, 1);
    _ = try controller.finish(
        0,
        .{ .status = .no_content, .mapped_error = false, .transport = .completed },
        2,
    );
    try std.testing.expectEqual(@as(u16, 1), ring.count());
    try std.testing.expectEqual(@as(u32, 1), wake.epoch());
    try controller.admit(1, "TRACE", null, 3, 1);
    _ = try controller.finish(
        1,
        .{ .status = null, .mapped_error = false, .transport = .peer_aborted },
        4,
    );
    try std.testing.expectEqual(@as(u64, 1), ring.dropped());
    try std.testing.expectEqual(
        @as(u64, 1),
        controller.metrics.runtime.counters[
            @intFromEnum(metrics.RuntimeCounter.access_events_dropped)
        ],
    );
}

test "admission validates indices and routes before mutating metrics" {
    const Observability = Controller(TestApp, 1, LoggingDisabled);
    var controller = Observability.init(.{});
    try std.testing.expectError(error.InvalidRequest, controller.admit(1, "GET", 0, 0, 0));
    try std.testing.expectError(error.InvalidRoute, controller.admit(0, "GET", 2, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), controller.metrics.routes[0].admitted);
}

test "latched fallback completes metrics and access logging exactly once" {
    const Log = Logging(2);
    const Observability = Controller(TestApp, 1, Log);
    var ring = Log.Ring{};
    var wake = futex_epoch.Event{};
    var controller = Observability.init(.{ .ring = &ring, .wake = &wake });
    const outcome = application.Outcome{
        .status = null,
        .mapped_error = true,
        .transport = .aborted,
    };
    try controller.admit(0, "POST", 1, 100, 20);
    try controller.addRequestWire(0, 4);
    try controller.addRequestDecoded(0, 3);
    try controller.latch(0, outcome);
    try controller.addResponseWire(0, 11);
    try std.testing.expect(controller.requestLive(0));
    try std.testing.expect(controller.requestLatched(0));
    try std.testing.expectEqual(@as(u64, 0), controller.metrics.routes[1].completed);
    try std.testing.expectEqual(@as(u16, 0), ring.count());
    const observation = try controller.finishLatched(0, 125);
    try std.testing.expectEqualDeep(outcome, observation.outcome);
    try std.testing.expectEqual(@as(u64, 11), observation.bytes.response_wire);
    try std.testing.expect(!controller.requestLive(0));
    try std.testing.expect(!controller.requestLatched(0));
    try std.testing.expectEqual(@as(u64, 1), controller.metrics.routes[1].completed);
    try std.testing.expectEqual(@as(u32, 0), controller.metrics.routes[1].active);
    try std.testing.expectEqual(@as(u16, 1), ring.count());
    try std.testing.expectError(error.NotLive, controller.finishLatched(0, 126));
    try std.testing.expectEqual(@as(u64, 1), controller.metrics.routes[1].completed);
    try std.testing.expectEqual(@as(u16, 1), ring.count());
}

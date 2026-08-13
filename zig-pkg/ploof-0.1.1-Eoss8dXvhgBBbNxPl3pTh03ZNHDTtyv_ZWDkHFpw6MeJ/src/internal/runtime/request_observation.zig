const std = @import("std");

const access_log = @import("../../access_log.zig");
const application = @import("../../application.zig");
const metrics = @import("../../metrics.zig");

pub const Error = error{
    AlreadyLive,
    AlreadyLatched,
    NotLive,
    NotLatched,
    ClockRegressed,
};

pub const Observation = struct {
    method: metrics.MethodClass,
    route_id: ?u16,
    outcome: application.Outcome,
    duration_ns: u64,
    bytes: access_log.ByteCounts,

    pub fn metricCompletion(observation: Observation) metrics.RequestCompletion {
        return .{
            .status = observation.outcome.status,
            .mapped_error = observation.outcome.mapped_error,
            .transport = observation.outcome.transport,
            .duration_ns = observation.duration_ns,
            .request_wire_bytes = observation.bytes.request_wire,
            .request_decoded_bytes = observation.bytes.request_decoded,
            .response_wire_bytes = observation.bytes.response_wire,
        };
    }

    pub fn accessEvent(observation: Observation) access_log.AccessEvent {
        return access_log.AccessEvent.init(
            observation.method,
            observation.route_id,
            observation.outcome,
            observation.duration_ns,
            observation.bytes,
        );
    }
};

/// Worker-local request accounting. Runtime call sites supply bytes they have
/// already counted and monotonic samples they already obtained for deadlines.
pub const Tracker = struct {
    live: bool = false,
    method: metrics.MethodClass = .other,
    route_id: ?u16 = null,
    started_ns: u64 = 0,
    bytes: access_log.ByteCounts = .{},
    latched_outcome: ?application.Outcome = null,

    pub fn begin(
        tracker: *Tracker,
        method: []const u8,
        route_id: ?u16,
        started_ns: u64,
        head_wire_bytes: u64,
    ) Error!void {
        if (tracker.live) return error.AlreadyLive;
        tracker.* = .{
            .live = true,
            .method = metrics.methodClass(method),
            .route_id = route_id,
            .started_ns = started_ns,
            .bytes = .{ .request_wire = head_wire_bytes },
        };
    }

    pub fn addRequestWire(tracker: *Tracker, count: u64) Error!void {
        if (!tracker.live) return error.NotLive;
        if (tracker.latched_outcome != null) return error.AlreadyLatched;
        tracker.bytes.request_wire +|= count;
    }

    pub fn addRequestDecoded(tracker: *Tracker, count: u64) Error!void {
        if (!tracker.live) return error.NotLive;
        if (tracker.latched_outcome != null) return error.AlreadyLatched;
        tracker.bytes.request_decoded +|= count;
    }

    pub fn addResponseWire(tracker: *Tracker, count: u64) Error!void {
        if (!tracker.live) return error.NotLive;
        tracker.bytes.response_wire +|= count;
    }

    pub fn finish(
        tracker: *Tracker,
        outcome: application.Outcome,
        finished_ns: u64,
    ) Error!Observation {
        if (!tracker.live) return error.NotLive;
        if (tracker.latched_outcome != null) return error.AlreadyLatched;
        return tracker.finishOutcome(outcome, finished_ns);
    }

    pub fn latch(tracker: *Tracker, outcome: application.Outcome) Error!void {
        if (!tracker.live) return error.NotLive;
        if (tracker.latched_outcome != null) return error.AlreadyLatched;
        tracker.latched_outcome = outcome;
    }

    pub fn finishLatched(tracker: *Tracker, finished_ns: u64) Error!Observation {
        if (!tracker.live) return error.NotLive;
        const outcome = tracker.latched_outcome orelse return error.NotLatched;
        return tracker.finishOutcome(outcome, finished_ns);
    }

    fn finishOutcome(
        tracker: *Tracker,
        outcome: application.Outcome,
        finished_ns: u64,
    ) Error!Observation {
        if (finished_ns < tracker.started_ns) return error.ClockRegressed;
        const observation = Observation{
            .method = tracker.method,
            .route_id = tracker.route_id,
            .outcome = outcome,
            .duration_ns = finished_ns - tracker.started_ns,
            .bytes = tracker.bytes,
        };
        tracker.* = .{};
        return observation;
    }
};

test "tracker produces matching metric and access observations without allocation" {
    var tracker = Tracker{};
    try tracker.begin("OPTIONS", 7, 100, 80);
    try tracker.addRequestWire(20);
    try tracker.addRequestDecoded(12);
    try tracker.addResponseWire(256);
    const observation = try tracker.finish(
        .{ .status = .created, .mapped_error = false, .transport = .completed },
        145,
    );
    try std.testing.expectEqual(metrics.MethodClass.options, observation.method);
    try std.testing.expectEqual(@as(u64, 45), observation.duration_ns);
    try std.testing.expectEqual(@as(u64, 100), observation.bytes.request_wire);
    try std.testing.expectEqual(@as(u64, 12), observation.bytes.request_decoded);
    try std.testing.expectEqual(@as(u64, 256), observation.bytes.response_wire);
    try std.testing.expectEqualDeep(
        observation.metricCompletion(),
        metrics.RequestCompletion{
            .status = .created,
            .mapped_error = false,
            .transport = .completed,
            .duration_ns = 45,
            .request_wire_bytes = 100,
            .request_decoded_bytes = 12,
            .response_wire_bytes = 256,
        },
    );
    const event = observation.accessEvent();
    try std.testing.expectEqual(metrics.MethodClass.options, event.method);
    try std.testing.expectEqual(@as(u16, 7), event.route_id);
    try std.testing.expect(!tracker.live);
}

test "tracker rejects invalid lifecycle transactionally and saturates byte counts" {
    var tracker = Tracker{};
    try std.testing.expectError(error.NotLive, tracker.addResponseWire(1));
    try tracker.begin("TRACE", null, 10, std.math.maxInt(u64));
    try std.testing.expectError(error.AlreadyLive, tracker.begin("GET", 0, 11, 0));
    try tracker.addRequestWire(1);
    try std.testing.expectError(
        error.ClockRegressed,
        tracker.finish(
            .{ .status = null, .mapped_error = false, .transport = .peer_aborted },
            9,
        ),
    );
    try std.testing.expect(tracker.live);
    const observation = try tracker.finish(
        .{ .status = null, .mapped_error = false, .transport = .peer_aborted },
        10,
    );
    try std.testing.expectEqual(metrics.MethodClass.other, observation.method);
    try std.testing.expectEqual(std.math.maxInt(u64), observation.bytes.request_wire);
    try std.testing.expectError(error.NotLive, tracker.finish(observation.outcome, 10));
}

test "tracker retains first latched outcome through fallback response writes" {
    var tracker = Tracker{};
    const outcome = application.Outcome{
        .status = null,
        .mapped_error = true,
        .transport = .aborted,
    };
    try tracker.begin("POST", 1, 20, 12);
    try tracker.addRequestWire(8);
    try tracker.addRequestDecoded(5);
    try tracker.latch(outcome);
    try std.testing.expectError(error.AlreadyLatched, tracker.latch(.{
        .status = .ok,
        .mapped_error = false,
        .transport = .completed,
    }));
    try std.testing.expectError(error.AlreadyLatched, tracker.addRequestWire(1));
    try std.testing.expectError(error.AlreadyLatched, tracker.addRequestDecoded(1));
    try std.testing.expectError(error.AlreadyLatched, tracker.finish(outcome, 21));
    try tracker.addResponseWire(7);
    try std.testing.expectError(error.ClockRegressed, tracker.finishLatched(19));
    const observation = try tracker.finishLatched(25);
    try std.testing.expectEqualDeep(outcome, observation.outcome);
    try std.testing.expectEqual(@as(u64, 20), observation.bytes.request_wire);
    try std.testing.expectEqual(@as(u64, 5), observation.bytes.request_decoded);
    try std.testing.expectEqual(@as(u64, 7), observation.bytes.response_wire);
    try std.testing.expectError(error.NotLive, tracker.finishLatched(25));
    try tracker.begin("GET", null, 30, 4);
    try std.testing.expect(tracker.latched_outcome == null);
}

test "tracker rejects latch operations outside the latched phase" {
    var tracker = Tracker{};
    const outcome = application.Outcome{
        .status = null,
        .mapped_error = false,
        .transport = .framework_canceled,
    };
    try std.testing.expectError(error.NotLive, tracker.latch(outcome));
    try std.testing.expectError(error.NotLive, tracker.finishLatched(0));
    try tracker.begin("GET", null, 0, 0);
    try std.testing.expectError(error.NotLatched, tracker.finishLatched(0));
    _ = try tracker.finish(outcome, 0);
}

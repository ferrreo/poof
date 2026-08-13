const std = @import("std");

const access_logger = @import("../access_logger.zig");
const access_log = @import("../../../access_log.zig");
const futex_epoch = @import("../futex_epoch.zig");
const metrics = @import("../../../metrics.zig");
const server_types = @import("../../../server/types.zig");
const worker_observability = @import("../worker/observability.zig");

pub const StartError = access_logger.StartError || error{
    DescriptorRequired,
    DescriptorUnexpected,
};

pub const LoggerReport = struct {
    queued_events: u32 = 0,
    in_flight_events: u32 = 0,
    dropped_events: u64 = 0,
};

pub fn Runtime(
    comptime App: type,
    comptime worker_count_max: u16,
    comptime request_slots: u16,
    comptime log_options: server_types.AccessLogOptions,
) type {
    const route_count: u16 = @intCast(App.route_definitions.len);
    const Log = if (log_options.enabled)
        worker_observability.Logging(log_options.ring_capacity)
    else
        worker_observability.LoggingDisabled;
    const EventRing = if (log_options.enabled) Log.Ring else struct {};
    const Logger = if (log_options.enabled)
        access_logger.Logger(
            worker_count_max,
            log_options.ring_capacity,
            log_options.drain_batch_per_ring,
        )
    else
        DisabledLogger;
    const Observation = worker_observability.Controller(App, request_slots, Log);
    const Coordinator = metrics.Coordinator(worker_count_max, route_count);
    const MetricsSnapshot = metrics.Snapshot(route_count);

    return struct {
        const Self = @This();

        pub const ObservationController = Observation;
        pub const Snapshot = MetricsSnapshot;

        rings: [worker_count_max]EventRing = [_]EventRing{.{}} ** worker_count_max,
        logger: Logger = undefined,
        coordinator: Coordinator = .{},
        snapshot_event: futex_epoch.Event = .{},
        snapshot_busy: std.atomic.Value(u64) = .init(0),
        snapshot_deadline: std.atomic.Value(u64) = .init(0),
        logger_live: std.atomic.Value(bool) = .init(false),

        pub fn startLogger(self: *Self, descriptor: ?std.os.linux.fd_t) StartError!void {
            if (comptime !log_options.enabled) {
                if (descriptor != null) return error.DescriptorUnexpected;
                self.logger = .{};
                return;
            }
            const selected = descriptor orelse return error.DescriptorRequired;
            self.logger = Logger.init(&self.rings, selected);
            try self.logger.startWithStack(log_options.thread_stack_bytes);
            self.logger_live.store(true, .release);
        }

        pub fn initObservation(self: *Self, worker_index: u16) Observation {
            if (comptime !log_options.enabled) return Observation.init(.{});
            const binding = self.logger.binding(worker_index);
            return Observation.init(.{ .ring = binding.ring, .wake = binding.wake });
        }

        pub fn publish(
            self: *Self,
            worker_index: u16,
            observation: *const Observation,
        ) void {
            const published = self.coordinator.publish(
                worker_index,
                &observation.metrics,
            ) catch return;
            if (published) self.snapshot_event.notify();
        }

        pub fn beginSnapshot(self: *Self, worker_count: u16) metrics.SnapshotError!u64 {
            return self.coordinator.beginFor(worker_count) catch |problem| {
                if (problem == error.SnapshotActive) saturatingIncrement(&self.snapshot_busy);
                return problem;
            };
        }

        pub fn completeSnapshot(
            self: *Self,
            epoch: u64,
            output: *MetricsSnapshot,
        ) metrics.SnapshotError!void {
            try self.coordinator.complete(epoch, output);
            addCounter(output, .metrics_snapshot_busy, self.snapshot_busy.load(.acquire));
            addCounter(
                output,
                .metrics_snapshot_deadline,
                self.snapshot_deadline.load(.acquire),
            );
            if (comptime log_options.enabled) {
                const logger_snapshot = self.logger.snapshot();
                addCounter(output, .access_sink_failures, logger_snapshot.sink_failures);
                addCounter(
                    output,
                    .access_events_dropped,
                    logger_snapshot.events_dropped_by_sink,
                );
            }
        }

        pub fn cancelSnapshot(self: *Self, epoch: u64, deadline: bool) void {
            self.coordinator.cancel(epoch) catch return;
            if (deadline) saturatingIncrement(&self.snapshot_deadline);
        }

        pub fn requestLoggerStop(self: *Self) void {
            if (comptime !log_options.enabled) return;
            if (!self.logger_live.load(.acquire)) return;
            self.logger.requestStop();
        }

        pub fn loggerTerminal(self: *Self) bool {
            if (comptime !log_options.enabled) return true;
            return switch (self.logger.state()) {
                .stopped, .failed => true,
                .idle, .running, .stopping => false,
            };
        }

        pub fn loggerTerminalEvent(self: *Self) *futex_epoch.Event {
            if (comptime !log_options.enabled) return &self.snapshot_event;
            return self.logger.terminalEvent();
        }

        pub fn joinLogger(self: *Self) void {
            if (comptime !log_options.enabled) return;
            if (!self.logger_live.swap(false, .acq_rel)) return;
            self.logger.join() catch {};
        }

        pub fn loggerReport(self: *const Self) LoggerReport {
            if (comptime !log_options.enabled) return .{};
            const snapshot = self.logger.snapshot();
            return .{
                .queued_events = snapshot.queued_events,
                .in_flight_events = snapshot.in_flight_events,
                .dropped_events = snapshot.producer_drops +| snapshot.events_dropped_by_sink,
            };
        }
    };
}

const DisabledLogger = struct {};

fn addCounter(snapshot: anytype, counter: metrics.RuntimeCounter, count: u64) void {
    snapshot.runtime.counters[@intFromEnum(counter)] +|= count;
}

fn saturatingIncrement(value: *std.atomic.Value(u64)) void {
    var current = value.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| {
            current = actual;
            continue;
        }
        return;
    }
}

test "disabled runtime retains metrics and rejects a stray log descriptor" {
    const App = struct {
        pub const route_definitions = [_]u8{0};
    };
    const TestRuntime = Runtime(App, 1, 1, .{});
    var runtime = TestRuntime{};
    try runtime.startLogger(null);
    try std.testing.expectError(error.DescriptorUnexpected, runtime.startLogger(2));
    var observation = runtime.initObservation(0);
    try observation.admit(0, "GET", 0, 1, 4);
    _ = try observation.finish(
        0,
        .{ .status = .ok, .mapped_error = false, .transport = .completed },
        2,
    );
    const epoch = try runtime.beginSnapshot(1);
    runtime.publish(0, &observation);
    var snapshot = TestRuntime.Snapshot{};
    try runtime.completeSnapshot(epoch, &snapshot);
    try std.testing.expectEqual(@as(u64, 1), snapshot.routes[0].completed);
}

test "enabled runtime owns one logger ring per worker" {
    const linux = std.os.linux;
    const App = struct {
        pub const route_definitions = [_]u8{};
    };
    const TestRuntime = Runtime(App, 2, 1, .{
        .enabled = true,
        .ring_capacity = 2,
        .drain_batch_per_ring = 1,
    });
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    var runtime = TestRuntime{};
    try runtime.startLogger(descriptors[1]);
    runtime.requestLoggerStop();
    for (0..1_000_000) |_| {
        if (runtime.loggerTerminal()) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(runtime.loggerTerminal());
    runtime.joinLogger();
}

test "logger mask failure leaves no live startup helper" {
    const linux = std.os.linux;
    const App = struct {
        pub const route_definitions = [_]u8{};
    };
    const TestRuntime = Runtime(App, 1, 1, .{
        .enabled = true,
        .ring_capacity = 1,
        .drain_batch_per_ring = 1,
    });
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    var runtime = TestRuntime{};
    access_logger.TestAccess.failNextSigpipeMask();

    try std.testing.expectError(
        error.AccessLogSigpipeMaskFailed,
        runtime.startLogger(descriptors[1]),
    );
    try std.testing.expect(!runtime.logger_live.load(.acquire));
    try std.testing.expectEqual(access_logger.State.failed, runtime.logger.state());
    try std.testing.expect(runtime.logger.thread == null);
}

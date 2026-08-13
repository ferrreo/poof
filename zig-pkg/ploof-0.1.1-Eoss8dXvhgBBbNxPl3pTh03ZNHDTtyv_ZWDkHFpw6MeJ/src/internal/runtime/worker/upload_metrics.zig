const std = @import("std");

const finalization = @import("../../application/multipart_finalization.zig");
const upload_finalizer = @import("../../upload/finalizer.zig");
const upload_io = @import("../../../upload_io.zig");

pub const cache_line_bytes = 64;
pub const latency_bucket_count = 24;
pub const event_capacity = 32;

pub const SinkOperation = upload_io.IoKind;
pub const RecoverableFailureClass = upload_io.IoError;

pub const CancellationOutcome = enum(u8) {
    /// Cancellation found no submitted target.
    not_required,
    /// Submitted target completed with `IoError.canceled`.
    target_canceled,
    /// Submitted target completed normally before its cancel pair settled.
    target_completed,
    /// Cancel submission or completion ownership failed.
    failed,
};

/// Closed controller failure categories. Callers choose recoverable or fatal
/// based on latched ownership and transaction state, never the Zig error name.
pub const FatalFailureClass = enum(u8) {
    application,
    backend,
    invalid_request,
    invalid_worker_index,
    state_invariant,
    transport,
};

pub const PrimaryFailureClass = enum(u8) {
    body,
    upload,
    verification,
    application,
    response_preparation,
    peer_disconnect,
    framework_canceled,
    sink,
};

pub const Identity = finalization.Identity;
pub const CleanupFailureClass = finalization.CleanupFailureClass;
pub const FinalizationOutcome = finalization.Outcome;

pub const FinalizationEvent = struct {
    outcome: FinalizationOutcome,
    primary: ?PrimaryFailureClass = null,
    identity: ?Identity = null,
    cleanup_failure_count: u32 = 0,
};

pub const FailureEvent = struct {
    class: RecoverableFailureClass,
    identity: ?Identity = null,
};

pub const FatalEvent = struct {
    class: FatalFailureClass,
    identity: ?Identity = null,
};

pub const CleanupEvent = struct {
    class: CleanupFailureClass,
    identity: Identity,
};

pub const EventDetail = union(enum(u8)) {
    finalization: FinalizationEvent,
    cleanup_failure: CleanupEvent,
    recoverable_failure: FailureEvent,
    fatal_failure: FatalEvent,
};

pub const Event = struct {
    /// Events contain only closed enums, bounded counts, and numeric sink indices.
    sequence: u64 = 0,
    route_id: ?u16 = null,
    detail: EventDetail = .{
        .finalization = .{ .outcome = .aborted },
    },
};

const sink_operation_count = std.enums.values(SinkOperation).len;
const recoverable_failure_count = std.enums.values(RecoverableFailureClass).len;
const fatal_failure_count = std.enums.values(FatalFailureClass).len;
const cancellation_outcome_count = std.enums.values(CancellationOutcome).len;
const primary_failure_count = std.enums.values(PrimaryFailureClass).len;
const cleanup_failure_count = std.enums.values(CleanupFailureClass).len;
const finalization_outcome_count = std.enums.values(FinalizationOutcome).len;

const LatencyHistogram = [latency_bucket_count]u64;
const SinkHistograms = [sink_operation_count]LatencyHistogram;

pub const Snapshot = struct {
    window_full_count: u64,
    window_full_duration_ns_total: u64,
    window_full_duration_ns_max: u64,
    window_full_duration: LatencyHistogram,
    sink_operation_count: [sink_operation_count]u64,
    sink_operation_latency_ns_total: [sink_operation_count]u64,
    sink_operation_latency_ns_max: [sink_operation_count]u64,
    sink_operation_latency: SinkHistograms,
    cancellations: [cancellation_outcome_count]u64,
    recoverable_failures: [recoverable_failure_count]u64,
    fatal_failures: [fatal_failure_count]u64,
    finalization_outcomes: [finalization_outcome_count]u64,
    primary_failures: [primary_failure_count]u64,
    cleanup_failures: [cleanup_failure_count]u64,
    commit_attempted: u64,
    commit_completed: u64,
    abort_attempted: u64,
    abort_completed: u64,
    events_recorded: u64,
    events_overwritten: u64,
    event_count: u8,
    events: [event_capacity]Event,
};

/// Worker-owned upload metrics live separately from the base hot cache line.
/// Cache-line alignment and a cache-line-multiple size prevent adjacent workers
/// from sharing a line. No field is atomic because only its worker mutates it.
pub const Metrics = struct {
    window_full_count: u64 align(cache_line_bytes) = 0,
    window_full_duration_ns_total: u64 = 0,
    window_full_duration_ns_max: u64 = 0,
    window_full_duration: LatencyHistogram = @splat(0),
    sink_operation_count: [sink_operation_count]u64 = @splat(0),
    sink_operation_latency_ns_total: [sink_operation_count]u64 = @splat(0),
    sink_operation_latency_ns_max: [sink_operation_count]u64 = @splat(0),
    sink_operation_latency: SinkHistograms = @splat(@splat(0)),
    cancellations: [cancellation_outcome_count]u64 = @splat(0),
    recoverable_failures: [recoverable_failure_count]u64 = @splat(0),
    fatal_failures: [fatal_failure_count]u64 = @splat(0),
    finalization_outcomes: [finalization_outcome_count]u64 = @splat(0),
    primary_failures: [primary_failure_count]u64 = @splat(0),
    cleanup_failures: [cleanup_failure_count]u64 = @splat(0),
    commit_attempted: u64 = 0,
    commit_completed: u64 = 0,
    abort_attempted: u64 = 0,
    abort_completed: u64 = 0,
    events_recorded: u64 = 0,
    events_overwritten: u64 = 0,
    event_head: u8 = 0,
    event_count: u8 = 0,
    events: [event_capacity]Event = @splat(.{}),

    /// Hook when parser intake resumes after a full upload window. Duration
    /// comes from the worker's existing monotonic sample; this method reads no clock.
    pub fn recordWindowFull(self: *Metrics, duration_ns: u64) void {
        self.window_full_count +|= 1;
        self.window_full_duration_ns_total +|= duration_ns;
        self.window_full_duration_ns_max = @max(
            self.window_full_duration_ns_max,
            duration_ns,
        );
        self.window_full_duration[latencyBucket(duration_ns)] +|= 1;
    }

    /// Hook once when a normalized upload I/O target completes. Measure from
    /// successful submission to target completion using worker monotonic samples.
    pub fn recordSinkOperation(
        self: *Metrics,
        operation: SinkOperation,
        latency_ns: u64,
    ) void {
        const index = @intFromEnum(operation);
        self.sink_operation_count[index] +|= 1;
        self.sink_operation_latency_ns_total[index] +|= latency_ns;
        self.sink_operation_latency_ns_max[index] = @max(
            self.sink_operation_latency_ns_max[index],
            latency_ns,
        );
        self.sink_operation_latency[index][latencyBucket(latency_ns)] +|= 1;
    }

    /// Hook once per application cancellation decision or terminal cancel pair.
    pub fn recordCancellation(self: *Metrics, outcome: CancellationOutcome) void {
        self.cancellations[@intFromEnum(outcome)] +|= 1;
    }

    /// Hook for sink-proven failures that leave ownership recoverable.
    pub fn recordRecoverableFailure(
        self: *Metrics,
        class: RecoverableFailureClass,
        identity: ?Identity,
    ) void {
        self.recordRecoverableFailureForRoute(class, identity, null);
    }

    pub fn recordRecoverableFailureForRoute(
        self: *Metrics,
        class: RecoverableFailureClass,
        identity: ?Identity,
        route_id: ?u16,
    ) void {
        self.recoverable_failures[@intFromEnum(class)] +|= 1;
        self.pushEvent(route_id, .{ .recoverable_failure = .{
            .class = class,
            .identity = identity,
        } });
    }

    /// Hook only after fatal provenance or ownership state has been latched.
    pub fn recordFatalFailure(
        self: *Metrics,
        class: FatalFailureClass,
        identity: ?Identity,
    ) void {
        self.recordFatalFailureForRoute(class, identity, null);
    }

    pub fn recordFatalFailureForRoute(
        self: *Metrics,
        class: FatalFailureClass,
        identity: ?Identity,
        route_id: ?u16,
    ) void {
        self.fatal_failures[@intFromEnum(class)] +|= 1;
        self.pushEvent(route_id, .{ .fatal_failure = .{
            .class = class,
            .identity = identity,
        } });
    }

    /// Hook once after the terminal report is available and before workspace reuse.
    pub fn recordFinalization(self: *Metrics, report: finalization.Report) void {
        self.recordFinalizationForRoute(report, null);
    }

    pub fn recordFinalizationForRoute(
        self: *Metrics,
        report: finalization.Report,
        route_id: ?u16,
    ) void {
        self.finalization_outcomes[@intFromEnum(report.outcome)] +|= 1;
        self.commit_attempted +|= report.commit_attempted_count;
        self.commit_completed +|= report.commit_completed_count;
        self.abort_attempted +|= report.abort_attempted_count;
        self.abort_completed +|= report.abort_completed_count;

        const primary = if (report.primary) |value|
            primaryFailureClass(value.class)
        else
            null;
        if (primary) |class| self.primary_failures[@intFromEnum(class)] +|= 1;
        self.pushEvent(route_id, .{ .finalization = .{
            .outcome = report.outcome,
            .primary = primary,
            .identity = if (report.primary) |value| value.identity else null,
            .cleanup_failure_count = report.cleanup_failure_count,
        } });
    }

    /// Hook once for every indexed cleanup failure exposed after its report.
    pub fn recordFinalizationCleanup(
        self: *Metrics,
        failure: finalization.CleanupFailure,
    ) void {
        self.recordFinalizationCleanupForRoute(failure, null);
    }

    pub fn recordFinalizationCleanupForRoute(
        self: *Metrics,
        failure: finalization.CleanupFailure,
        route_id: ?u16,
    ) void {
        self.cleanup_failures[@intFromEnum(failure.class)] +|= 1;
        self.pushEvent(route_id, .{ .cleanup_failure = .{
            .class = failure.class,
            .identity = failure.identity,
        } });
    }

    /// Copies counters and the newest retained events in oldest-first order.
    /// A full ring overwrites its oldest event and saturates `events_overwritten`.
    pub fn snapshot(self: *const Metrics) Snapshot {
        var result = Snapshot{
            .window_full_count = self.window_full_count,
            .window_full_duration_ns_total = self.window_full_duration_ns_total,
            .window_full_duration_ns_max = self.window_full_duration_ns_max,
            .window_full_duration = self.window_full_duration,
            .sink_operation_count = self.sink_operation_count,
            .sink_operation_latency_ns_total = self.sink_operation_latency_ns_total,
            .sink_operation_latency_ns_max = self.sink_operation_latency_ns_max,
            .sink_operation_latency = self.sink_operation_latency,
            .cancellations = self.cancellations,
            .recoverable_failures = self.recoverable_failures,
            .fatal_failures = self.fatal_failures,
            .finalization_outcomes = self.finalization_outcomes,
            .primary_failures = self.primary_failures,
            .cleanup_failures = self.cleanup_failures,
            .commit_attempted = self.commit_attempted,
            .commit_completed = self.commit_completed,
            .abort_attempted = self.abort_attempted,
            .abort_completed = self.abort_completed,
            .events_recorded = self.events_recorded,
            .events_overwritten = self.events_overwritten,
            .event_count = self.event_count,
            .events = @splat(.{}),
        };
        for (0..self.event_count) |offset| {
            const index = (self.event_head + offset) % event_capacity;
            result.events[offset] = self.events[index];
        }
        return result;
    }

    fn pushEvent(self: *Metrics, route_id: ?u16, detail: EventDetail) void {
        self.events_recorded +|= 1;
        const index = if (self.event_count < event_capacity) blk: {
            const next = (self.event_head + self.event_count) % event_capacity;
            self.event_count += 1;
            break :blk next;
        } else blk: {
            const next = self.event_head;
            self.event_head = (self.event_head + 1) % event_capacity;
            self.events_overwritten +|= 1;
            break :blk next;
        };
        self.events[index] = .{
            .sequence = self.events_recorded,
            .route_id = route_id,
            .detail = detail,
        };
    }
};

pub fn latencyBucket(duration_ns: u64) usize {
    const units = duration_ns >> 10;
    const active = @intFromBool(units != 0);
    const exponent = 63 - @clz(units | 1);
    return @min(active + exponent, latency_bucket_count - 1);
}

pub fn latencyBucketUpperNs(bucket: usize) u64 {
    std.debug.assert(bucket < latency_bucket_count);
    if (bucket == latency_bucket_count - 1) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bucket + 10)) - 1;
}

pub fn primaryFailureClass(class: upload_finalizer.FailureClass) PrimaryFailureClass {
    return switch (class) {
        .upstream => |value| @enumFromInt(@intFromEnum(value)),
        .sink => .sink,
    };
}

test "upload metrics are cache-line isolated with logarithmic latency buckets" {
    try std.testing.expectEqual(cache_line_bytes, @alignOf(Metrics));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Metrics) % cache_line_bytes);
    try std.testing.expectEqual(@as(usize, 0), latencyBucket(0));
    try std.testing.expectEqual(@as(usize, 0), latencyBucket(1023));
    try std.testing.expectEqual(@as(usize, 1), latencyBucket(1024));
    try std.testing.expectEqual(@as(usize, 1), latencyBucket(2047));
    try std.testing.expectEqual(@as(usize, 2), latencyBucket(2048));
    try std.testing.expectEqual(@as(u64, 2047), latencyBucketUpperNs(1));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        latencyBucketUpperNs(latency_bucket_count - 1),
    );
}

test "upload metrics durations and operations saturate without allocation" {
    var metrics = Metrics{};
    metrics.window_full_count = std.math.maxInt(u64);
    metrics.window_full_duration_ns_total = std.math.maxInt(u64) - 10;
    metrics.recordWindowFull(2048);
    metrics.recordSinkOperation(.write, 1024);
    metrics.recordSinkOperation(.write, 4096);

    const value = metrics.snapshot();
    try std.testing.expectEqual(std.math.maxInt(u64), value.window_full_count);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        value.window_full_duration_ns_total,
    );
    try std.testing.expectEqual(@as(u64, 2048), value.window_full_duration_ns_max);
    try std.testing.expectEqual(@as(u64, 1), value.window_full_duration[2]);
    const write = @intFromEnum(SinkOperation.write);
    try std.testing.expectEqual(@as(u64, 2), value.sink_operation_count[write]);
    try std.testing.expectEqual(@as(u64, 5120), value.sink_operation_latency_ns_total[write]);
    try std.testing.expectEqual(@as(u64, 4096), value.sink_operation_latency_ns_max[write]);
    try std.testing.expectEqual(@as(u64, 1), value.sink_operation_latency[write][1]);
    try std.testing.expectEqual(@as(u64, 1), value.sink_operation_latency[write][3]);
}

test "upload metrics cancellation and failure classes retain numeric identities" {
    var metrics = Metrics{};
    const identity = Identity{ .registry_index = 7, .instance_index = 3 };
    inline for (std.enums.values(CancellationOutcome)) |outcome| {
        metrics.recordCancellation(outcome);
    }
    metrics.recordRecoverableFailure(.no_space, identity);
    metrics.recordFatalFailure(.transport, identity);

    const value = metrics.snapshot();
    inline for (std.enums.values(CancellationOutcome)) |outcome| {
        try std.testing.expectEqual(
            @as(u64, 1),
            value.cancellations[@intFromEnum(outcome)],
        );
    }
    try std.testing.expectEqual(
        @as(u64, 1),
        value.recoverable_failures[@intFromEnum(RecoverableFailureClass.no_space)],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        value.fatal_failures[@intFromEnum(FatalFailureClass.transport)],
    );
    try std.testing.expectEqualDeep(
        identity,
        value.events[0].detail.recoverable_failure.identity.?,
    );
    try std.testing.expectEqualDeep(identity, value.events[1].detail.fatal_failure.identity.?);
}

test "upload metrics finalization retains outcome classes and numeric identities" {
    var metrics = Metrics{};
    const identity = Identity{ .registry_index = 7, .instance_index = 3 };
    metrics.recordFinalization(.{
        .outcome = .failed,
        .primary = .{ .class = .sink, .identity = identity },
        .instance_count = 4,
        .commit_attempted_count = 2,
        .commit_completed_count = 1,
        .abort_attempted_count = 4,
        .abort_completed_count = 3,
        .cleanup_failure_count = 1,
    });
    metrics.recordFinalizationCleanup(.{ .class = .sink, .identity = identity });
    metrics.recordFinalization(.{
        .outcome = .committed,
        .primary = null,
        .instance_count = 1,
        .commit_attempted_count = 1,
        .commit_completed_count = 1,
        .abort_attempted_count = 0,
        .abort_completed_count = 0,
        .cleanup_failure_count = 0,
    });
    metrics.recordFinalization(.{
        .outcome = .aborted,
        .primary = .{ .class = .{ .upstream = .peer_disconnect }, .identity = null },
        .instance_count = 1,
        .commit_attempted_count = 0,
        .commit_completed_count = 0,
        .abort_attempted_count = 1,
        .abort_completed_count = 1,
        .cleanup_failure_count = 0,
    });

    const value = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 3), value.commit_attempted);
    try std.testing.expectEqual(@as(u64, 2), value.commit_completed);
    try std.testing.expectEqual(@as(u64, 5), value.abort_attempted);
    try std.testing.expectEqual(@as(u64, 4), value.abort_completed);
    inline for (std.enums.values(FinalizationOutcome)) |outcome| {
        try std.testing.expectEqual(
            @as(u64, 1),
            value.finalization_outcomes[@intFromEnum(outcome)],
        );
    }
    try std.testing.expectEqual(
        @as(u64, 1),
        value.cleanup_failures[@intFromEnum(CleanupFailureClass.sink)],
    );
    try std.testing.expectEqual(@as(u8, 4), value.event_count);
    const terminal = value.events[0].detail.finalization;
    try std.testing.expectEqual(FinalizationOutcome.failed, terminal.outcome);
    try std.testing.expectEqual(PrimaryFailureClass.sink, terminal.primary.?);
    try std.testing.expectEqualDeep(identity, terminal.identity.?);
    const cleanup = value.events[1].detail.cleanup_failure;
    try std.testing.expectEqualDeep(identity, cleanup.identity);
    const aborted = value.events[3].detail.finalization;
    try std.testing.expectEqual(PrimaryFailureClass.peer_disconnect, aborted.primary.?);
    try std.testing.expect(aborted.identity == null);
}

test "upload metrics event ring retains newest bounded events in sequence" {
    var metrics = Metrics{};
    const extra = 3;
    for (0..event_capacity + extra) |index| {
        metrics.recordFatalFailure(.state_invariant, .{
            .registry_index = 9,
            .instance_index = @intCast(index),
        });
    }

    const before = metrics.snapshot();
    metrics.recordCancellation(.failed);
    try std.testing.expectEqual(@as(u8, event_capacity), before.event_count);
    try std.testing.expectEqual(@as(u64, extra), before.events_overwritten);
    try std.testing.expectEqual(@as(u64, extra + 1), before.events[0].sequence);
    try std.testing.expectEqual(
        @as(u16, extra),
        before.events[0].detail.fatal_failure.identity.?.instance_index,
    );
    try std.testing.expectEqual(@as(u64, event_capacity + extra), before.events_recorded);
    try std.testing.expectEqual(
        @as(u64, 0),
        before.cancellations[@intFromEnum(CancellationOutcome.failed)],
    );
}

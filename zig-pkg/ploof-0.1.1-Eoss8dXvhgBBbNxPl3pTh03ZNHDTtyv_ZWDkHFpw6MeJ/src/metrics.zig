const std = @import("std");

const application = @import("application.zig");
const response = @import("response.zig");
const route = @import("route.zig");

pub const latency_bucket_count: usize = 24;
pub const latency_finite_bucket_count: usize = latency_bucket_count - 1;
pub const latency_bucket_base_ns: u64 = std.time.ns_per_us;
pub const unmatched_route_id = std.math.maxInt(u16);

pub const MethodClass = enum(u8) {
    get,
    head,
    post,
    put,
    patch,
    delete,
    options,
    other,

    pub fn wire(method: MethodClass) []const u8 {
        return switch (method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
            .options => "OPTIONS",
            .other => "OTHER",
        };
    }
};

pub const StatusClass = enum(u8) {
    none,
    success,
    redirect,
    client_error,
    server_error,
};

pub const ApplicationOutcome = enum(u8) {
    selected,
    mapped_failure,
    aborted_before_selection,
};

pub const RuntimeCounter = enum(u8) {
    connections_admitted,
    connections_closed,
    parser_failures,
    framing_failures,
    progress_timeouts,
    overload_rejections,
    receive_pool_exhaustions,
    request_pool_exhaustions,
    response_pool_exhaustions,
    gzip_identity,
    gzip_encoded,
    gzip_decode_failures,
    multipart_completed,
    multipart_rejected,
    upload_committed,
    upload_aborted,
    upload_failed,
    static_served,
    static_not_modified,
    static_range,
    static_failed,
    io_uring_failures,
    cancellations_requested,
    cancellations_completed,
    cancellations_failed,
    completion_queue_overflows,
    submission_queue_drops,
    lifecycle_drains,
    lifecycle_forced,
    shutdown_incomplete,
    metrics_snapshot_busy,
    metrics_snapshot_deadline,
    access_events_dropped,
    access_sink_failures,
};

pub const RuntimeGauge = enum(u8) {
    connections,
    requests,
    receive_buffers,
    response_chunks,
    body_workspaces,
    gzip_jobs,
    upload_operations,
    static_file_operations,
    helper_jobs,
    access_events,
};

const method_class_count = @typeInfo(MethodClass).@"enum".fields.len;
const status_class_count = @typeInfo(StatusClass).@"enum".fields.len;
const application_outcome_count = @typeInfo(ApplicationOutcome).@"enum".fields.len;
const transport_outcome_count = @typeInfo(application.TransportOutcome).@"enum".fields.len;
const runtime_counter_count = @typeInfo(RuntimeCounter).@"enum".fields.len;
const runtime_gauge_count = @typeInfo(RuntimeGauge).@"enum".fields.len;
pub const route_series_per_slot: u32 = @intCast(
    9 + method_class_count + status_class_count + application_outcome_count +
        transport_outcome_count + latency_bucket_count,
);

pub const RequestCompletion = struct {
    status: ?response.Status,
    mapped_error: bool,
    transport: application.TransportOutcome,
    duration_ns: u64,
    request_wire_bytes: u64 = 0,
    request_decoded_bytes: u64 = 0,
    response_wire_bytes: u64 = 0,
};

pub const RouteCell = struct {
    admitted: u64 = 0,
    active: u32 = 0,
    active_high_water: u32 = 0,
    completed: u64 = 0,
    request_wire_bytes: u64 = 0,
    request_decoded_bytes: u64 = 0,
    response_wire_bytes: u64 = 0,
    latency_ns_total: u64 = 0,
    methods: [method_class_count]u64 = [_]u64{0} ** method_class_count,
    statuses: [status_class_count]u64 = [_]u64{0} ** status_class_count,
    application_outcomes: [application_outcome_count]u64 =
        [_]u64{0} ** application_outcome_count,
    transport_outcomes: [transport_outcome_count]u64 =
        [_]u64{0} ** transport_outcome_count,
    latency: [latency_bucket_count]u64 = [_]u64{0} ** latency_bucket_count,

    pub fn admit(cell: *RouteCell, method: MethodClass) void {
        cell.admitted +|= 1;
        cell.methods[@intFromEnum(method)] +|= 1;
        std.debug.assert(cell.active != std.math.maxInt(u32));
        cell.active += 1;
        cell.active_high_water = @max(cell.active_high_water, cell.active);
    }

    pub fn complete(cell: *RouteCell, completion: RequestCompletion) void {
        std.debug.assert(cell.active != 0);
        cell.active -= 1;
        cell.completed +|= 1;
        cell.statuses[@intFromEnum(statusClass(completion.status))] +|= 1;
        const app_outcome = applicationOutcome(completion);
        cell.application_outcomes[@intFromEnum(app_outcome)] +|= 1;
        cell.transport_outcomes[@intFromEnum(completion.transport)] +|= 1;
        cell.latency[latencyBucket(completion.duration_ns)] +|= 1;
        cell.latency_ns_total +|= completion.duration_ns;
        cell.request_wire_bytes +|= completion.request_wire_bytes;
        cell.request_decoded_bytes +|= completion.request_decoded_bytes;
        cell.response_wire_bytes +|= completion.response_wire_bytes;
    }

    fn mergeInto(source: RouteCell, target: *RouteCell) void {
        target.admitted +|= source.admitted;
        target.active = addGauge(target.active, source.active);
        target.active_high_water = addGauge(
            target.active_high_water,
            source.active_high_water,
        );
        target.completed +|= source.completed;
        target.request_wire_bytes +|= source.request_wire_bytes;
        target.request_decoded_bytes +|= source.request_decoded_bytes;
        target.response_wire_bytes +|= source.response_wire_bytes;
        target.latency_ns_total +|= source.latency_ns_total;
        mergeCounters(&target.methods, &source.methods);
        mergeCounters(&target.statuses, &source.statuses);
        mergeCounters(&target.application_outcomes, &source.application_outcomes);
        mergeCounters(&target.transport_outcomes, &source.transport_outcomes);
        mergeCounters(&target.latency, &source.latency);
    }
};

pub const Gauge = struct {
    current: u32 = 0,
    high_water: u32 = 0,

    pub fn acquire(gauge: *Gauge, count: u32, capacity: u32) void {
        std.debug.assert(count <= capacity);
        std.debug.assert(gauge.current <= capacity - count);
        gauge.current += count;
        gauge.high_water = @max(gauge.high_water, gauge.current);
    }

    pub fn release(gauge: *Gauge, count: u32) void {
        std.debug.assert(count <= gauge.current);
        gauge.current -= count;
    }
};

pub const RuntimeCells = struct {
    counters: [runtime_counter_count]u64 = [_]u64{0} ** runtime_counter_count,
    gauges: [runtime_gauge_count]Gauge = [_]Gauge{.{}} ** runtime_gauge_count,

    pub fn record(cells: *RuntimeCells, counter: RuntimeCounter) void {
        cells.counters[@intFromEnum(counter)] +|= 1;
    }

    pub fn recordMany(cells: *RuntimeCells, counter: RuntimeCounter, count: u64) void {
        cells.counters[@intFromEnum(counter)] +|= count;
    }

    pub fn acquire(
        cells: *RuntimeCells,
        gauge: RuntimeGauge,
        count: u32,
        capacity: u32,
    ) void {
        cells.gauges[@intFromEnum(gauge)].acquire(count, capacity);
    }

    pub fn release(cells: *RuntimeCells, gauge: RuntimeGauge, count: u32) void {
        cells.gauges[@intFromEnum(gauge)].release(count);
    }

    fn mergeInto(source: RuntimeCells, target: *RuntimeCells) void {
        mergeCounters(&target.counters, &source.counters);
        for (source.gauges, 0..) |gauge, index| {
            target.gauges[index].current = addGauge(
                target.gauges[index].current,
                gauge.current,
            );
            target.gauges[index].high_water = addGauge(
                target.gauges[index].high_water,
                gauge.high_water,
            );
        }
    }
};

pub const Profile = struct {
    route_count: u16,
    route_slots: u16,
    series_count: u32,
    worker_bytes: u64,
    snapshot_bytes: u64,
};

pub fn Worker(comptime declared_route_count: u16) type {
    if (declared_route_count > route.routes_hard_max) {
        @compileError("PLOOF-E6201 metrics route count exceeds 4096");
    }
    const route_slots: usize = @as(usize, declared_route_count) + 1;

    return struct {
        const Self = @This();
        pub const route_count = declared_route_count;
        pub const unmatched_index: u16 = declared_route_count;

        routes: [route_slots]RouteCell align(64) = [_]RouteCell{.{}} ** route_slots,
        runtime: RuntimeCells align(64) = .{},

        pub fn profile() Profile {
            return .{
                .route_count = declared_route_count,
                .route_slots = @intCast(route_slots),
                .series_count = seriesCount(declared_route_count),
                .worker_bytes = @sizeOf(Self),
                .snapshot_bytes = @sizeOf(Snapshot(declared_route_count)),
            };
        }

        pub fn routeIndex(_: *const Self, route_id: ?u16) u16 {
            const index = route_id orelse unmatched_index;
            std.debug.assert(index <= declared_route_count);
            return index;
        }

        pub fn admit(metrics: *Self, route_id: ?u16, method: MethodClass) void {
            metrics.routes[metrics.routeIndex(route_id)].admit(method);
        }

        pub fn complete(
            metrics: *Self,
            route_id: ?u16,
            completion: RequestCompletion,
        ) void {
            metrics.routes[metrics.routeIndex(route_id)].complete(completion);
        }

        pub fn snapshot(metrics: *const Self, epoch: u64) Snapshot(declared_route_count) {
            return .{ .epoch = epoch, .routes = metrics.routes, .runtime = metrics.runtime };
        }
    };
}

pub fn Snapshot(comptime declared_route_count: u16) type {
    const route_slots: usize = @as(usize, declared_route_count) + 1;
    return struct {
        const Self = @This();

        epoch: u64 = 0,
        routes: [route_slots]RouteCell = [_]RouteCell{.{}} ** route_slots,
        runtime: RuntimeCells = .{},

        pub fn clear(snapshot: *Self, epoch: u64) void {
            snapshot.* = .{ .epoch = epoch };
        }

        pub fn merge(snapshot: *Self, source: *const Self) void {
            std.debug.assert(snapshot.epoch == source.epoch);
            for (source.routes, 0..) |cell, index| cell.mergeInto(&snapshot.routes[index]);
            source.runtime.mergeInto(&snapshot.runtime);
        }
    };
}

pub const SnapshotError = error{
    SnapshotActive,
    InvalidEpoch,
    InvalidWorker,
    SnapshotPending,
};

pub fn Coordinator(comptime worker_count: u16, comptime route_count: u16) type {
    if (worker_count == 0) @compileError("PLOOF-E6200 metrics worker count is zero");
    const Metrics = Worker(route_count);
    const MetricsSnapshot = Snapshot(route_count);

    return struct {
        const Self = @This();

        epoch_counter: std.atomic.Value(u64) = .init(0),
        active_epoch: std.atomic.Value(u64) = .init(0),
        active_workers: std.atomic.Value(u16) = .init(worker_count),
        published_epochs: [worker_count]std.atomic.Value(u64) =
            [_]std.atomic.Value(u64){.init(0)} ** worker_count,
        snapshots: [worker_count]MetricsSnapshot = undefined,

        pub fn begin(coordinator: *Self) SnapshotError!u64 {
            return coordinator.beginFor(worker_count);
        }

        pub fn beginFor(coordinator: *Self, workers: u16) SnapshotError!u64 {
            if (workers == 0 or workers > worker_count) return error.InvalidWorker;
            const epoch = coordinator.nextEpoch();
            if (coordinator.active_epoch.cmpxchgStrong(
                0,
                epoch,
                .acq_rel,
                .acquire,
            ) != null) return error.SnapshotActive;
            coordinator.active_workers.store(workers, .release);
            return epoch;
        }

        fn nextEpoch(coordinator: *Self) u64 {
            var current = coordinator.epoch_counter.load(.monotonic);
            while (true) {
                const next = if (current == std.math.maxInt(u64)) 1 else current + 1;
                if (coordinator.epoch_counter.cmpxchgWeak(
                    current,
                    next,
                    .monotonic,
                    .monotonic,
                )) |actual| {
                    current = actual;
                    continue;
                }
                return next;
            }
        }

        /// Called only by the owning worker at a safe event-loop point.
        pub fn publish(
            coordinator: *Self,
            worker_index: u16,
            metrics: *const Metrics,
        ) SnapshotError!bool {
            if (worker_index >= worker_count) return error.InvalidWorker;
            const epoch = coordinator.active_epoch.load(.acquire);
            if (epoch == 0) return false;
            if (coordinator.published_epochs[worker_index].load(.monotonic) == epoch) {
                return false;
            }
            coordinator.snapshots[worker_index] = metrics.snapshot(epoch);
            coordinator.published_epochs[worker_index].store(epoch, .release);
            return true;
        }

        pub fn complete(
            coordinator: *Self,
            epoch: u64,
            output: *MetricsSnapshot,
        ) SnapshotError!void {
            if (epoch == 0 or coordinator.active_epoch.load(.acquire) != epoch) {
                return error.InvalidEpoch;
            }
            const workers = coordinator.active_workers.load(.acquire);
            for (coordinator.published_epochs[0..workers]) |*published| {
                if (published.load(.acquire) != epoch) return error.SnapshotPending;
            }
            output.clear(epoch);
            for (coordinator.snapshots[0..workers]) |*snapshot| output.merge(snapshot);
            coordinator.active_epoch.store(0, .release);
        }

        pub fn cancel(coordinator: *Self, epoch: u64) SnapshotError!void {
            if (epoch == 0 or coordinator.active_epoch.load(.acquire) != epoch) {
                return error.InvalidEpoch;
            }
            coordinator.active_epoch.store(0, .release);
        }
    };
}

pub fn methodClass(method: []const u8) MethodClass {
    inline for (std.enums.values(route.Method)) |candidate| {
        if (std.mem.eql(u8, method, candidate.wire())) return @enumFromInt(@intFromEnum(candidate));
    }
    if (std.mem.eql(u8, method, "OPTIONS")) return .options;
    return .other;
}

pub fn statusClass(status: ?response.Status) StatusClass {
    const selected = status orelse return .none;
    return switch (@intFromEnum(selected) / 100) {
        2 => .success,
        3 => .redirect,
        4 => .client_error,
        else => .server_error,
    };
}

pub fn latencyBucket(duration_ns: u64) usize {
    if (duration_ns <= latency_bucket_base_ns) return 0;
    const microseconds = std.math.divCeil(u64, duration_ns, latency_bucket_base_ns) catch
        unreachable;
    const logarithm: usize = @intCast(64 - @clz(microseconds - 1));
    return @min(logarithm, latency_bucket_count - 1);
}

pub fn latencyBucketUpperNs(bucket: usize) ?u64 {
    std.debug.assert(bucket < latency_bucket_count);
    if (bucket == latency_bucket_count - 1) return null;
    return latency_bucket_base_ns << @intCast(bucket);
}

fn applicationOutcome(completion: RequestCompletion) ApplicationOutcome {
    if (completion.status == null) return .aborted_before_selection;
    return if (completion.mapped_error) .mapped_failure else .selected;
}

fn mergeCounters(target: []u64, source: []const u64) void {
    std.debug.assert(target.len == source.len);
    for (target, source) |*target_value, source_value| target_value.* +|= source_value;
}

fn addGauge(left: u32, right: u32) u32 {
    return std.math.add(u32, left, right) catch std.math.maxInt(u32);
}

fn seriesCount(route_count: u16) u32 {
    const route_series = (@as(u32, route_count) + 1) * route_series_per_slot;
    return route_series + @as(u32, @intCast(runtime_counter_count)) +
        2 * @as(u32, @intCast(runtime_gauge_count));
}

test "route cells retain closed dimensions, bytes, latency, and active gauges" {
    const Metrics = Worker(2);
    var metrics = Metrics{};
    metrics.admit(1, .post);
    metrics.complete(1, .{
        .status = .created,
        .mapped_error = false,
        .transport = .completed,
        .duration_ns = 1024,
        .request_wire_bytes = 20,
        .request_decoded_bytes = 9,
        .response_wire_bytes = 40,
    });
    const cell = metrics.routes[1];
    try std.testing.expectEqual(@as(u64, 1), cell.admitted);
    try std.testing.expectEqual(@as(u32, 0), cell.active);
    try std.testing.expectEqual(@as(u32, 1), cell.active_high_water);
    try std.testing.expectEqual(@as(u64, 1), cell.methods[@intFromEnum(MethodClass.post)]);
    try std.testing.expectEqual(@as(u64, 1), cell.statuses[@intFromEnum(StatusClass.success)]);
    try std.testing.expectEqual(@as(u64, 1), cell.latency[latencyBucket(1024)]);
    try std.testing.expectEqual(@as(u64, 20), cell.request_wire_bytes);
}

test "method normalization covers routed OPTIONS and extension methods" {
    inline for (std.enums.values(route.Method)) |method| {
        try std.testing.expectEqual(
            @as(MethodClass, @enumFromInt(@intFromEnum(method))),
            methodClass(method.wire()),
        );
    }
    try std.testing.expectEqual(MethodClass.options, methodClass("OPTIONS"));
    try std.testing.expectEqual(MethodClass.other, methodClass("TRACE"));
    try std.testing.expectEqualStrings("OPTIONS", MethodClass.options.wire());
    try std.testing.expectEqualStrings("OTHER", MethodClass.other.wire());
}

test "unmatched aborted requests never create request-controlled metric labels" {
    const Metrics = Worker(1);
    var metrics = Metrics{};
    metrics.admit(null, methodClass("TRACE"));
    metrics.complete(null, .{
        .status = null,
        .mapped_error = false,
        .transport = .peer_aborted,
        .duration_ns = 0,
    });
    const cell = metrics.routes[Metrics.unmatched_index];
    try std.testing.expectEqual(@as(u64, 1), cell.methods[@intFromEnum(MethodClass.other)]);
    try std.testing.expectEqual(@as(u64, 1), cell.statuses[@intFromEnum(StatusClass.none)]);
    try std.testing.expectEqual(
        @as(u64, 1),
        cell.application_outcomes[@intFromEnum(ApplicationOutcome.aborted_before_selection)],
    );
}

test "runtime inventories saturate counters and bound gauges" {
    var cells = RuntimeCells{};
    cells.counters[@intFromEnum(RuntimeCounter.parser_failures)] = std.math.maxInt(u64);
    cells.record(.parser_failures);
    cells.acquire(.connections, 2, 3);
    cells.release(.connections, 1);
    cells.acquire(.connections, 2, 3);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        cells.counters[@intFromEnum(RuntimeCounter.parser_failures)],
    );
    try std.testing.expectEqual(@as(u32, 3), cells.gauges[0].current);
    try std.testing.expectEqual(@as(u32, 3), cells.gauges[0].high_water);
}

test "snapshot coordinator publishes only complete epochs" {
    const Metrics = Worker(1);
    const Snapshots = Coordinator(2, 1);
    var coordinator = Snapshots{};
    var workers = [2]Metrics{ .{}, .{} };
    workers[0].admit(0, .get);
    workers[1].admit(null, .other);
    const epoch = try coordinator.begin();
    try std.testing.expectError(error.SnapshotActive, coordinator.begin());
    try std.testing.expect(try coordinator.publish(0, &workers[0]));
    try std.testing.expect(!(try coordinator.publish(0, &workers[0])));
    var output = Snapshot(1){};
    try std.testing.expectError(error.SnapshotPending, coordinator.complete(epoch, &output));
    try std.testing.expect(try coordinator.publish(1, &workers[1]));
    try coordinator.complete(epoch, &output);
    try std.testing.expectEqual(epoch, output.epoch);
    try std.testing.expectEqual(@as(u64, 1), output.routes[0].admitted);
    try std.testing.expectEqual(@as(u64, 1), output.routes[1].admitted);
}

test "snapshot cancellation rejects stale publication and a later epoch completes" {
    const Metrics = Worker(0);
    const Snapshots = Coordinator(1, 0);
    var coordinator = Snapshots{};
    var metrics = Metrics{};
    const first = try coordinator.begin();
    try coordinator.cancel(first);
    try std.testing.expect(!(try coordinator.publish(0, &metrics)));
    const second = try coordinator.begin();
    try std.testing.expect(second != first);
    try std.testing.expect(try coordinator.publish(0, &metrics));
    var output = Snapshot(0){};
    try coordinator.complete(second, &output);
}

test "concurrent snapshot requests admit one complete epoch" {
    const Snapshots = Coordinator(1, 0);
    const Race = struct {
        coordinator: *Snapshots,
        admitted: *std.atomic.Value(u8),

        fn run(race: @This()) void {
            _ = race.coordinator.begin() catch return;
            _ = race.admitted.fetchAdd(1, .monotonic);
        }
    };
    var coordinator = Snapshots{};
    var admitted = std.atomic.Value(u8).init(0);
    const race = Race{ .coordinator = &coordinator, .admitted = &admitted };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Race.run, .{race});
    for (&threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u8, 1), admitted.load(.acquire));
}

test "metrics profile reports fixed memory and series counts" {
    const profile = Worker(3).profile();
    try std.testing.expectEqual(@as(u16, 3), profile.route_count);
    try std.testing.expectEqual(@as(u16, 4), profile.route_slots);
    try std.testing.expect(profile.series_count > 0);
    try std.testing.expect(profile.worker_bytes >= profile.snapshot_bytes);
}

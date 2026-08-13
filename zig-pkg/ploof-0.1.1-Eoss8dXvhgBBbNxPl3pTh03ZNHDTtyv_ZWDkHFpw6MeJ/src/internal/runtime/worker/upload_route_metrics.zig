const std = @import("std");

const finalization = @import("../../application/multipart_finalization.zig");
const upload_metrics = @import("upload_metrics.zig");

const sink_operation_count = std.enums.values(upload_metrics.SinkOperation).len;
const recoverable_failure_count =
    std.enums.values(upload_metrics.RecoverableFailureClass).len;
const fatal_failure_count = std.enums.values(upload_metrics.FatalFailureClass).len;
const cancellation_outcome_count = std.enums.values(upload_metrics.CancellationOutcome).len;
const primary_failure_count = std.enums.values(upload_metrics.PrimaryFailureClass).len;
const cleanup_failure_count = std.enums.values(upload_metrics.CleanupFailureClass).len;
const finalization_outcome_count = std.enums.values(upload_metrics.FinalizationOutcome).len;

pub const cell_bytes_max = 640;
pub const aggregate_only_profile = std.math.maxInt(u32);

const LegacyProfile = struct {
    route_id: u16,
    window: u8,
};

pub const Cell = struct {
    window_full_count: u64 = 0,
    window_full_duration_ns_total: u64 = 0,
    window_full_duration_ns_max: u64 = 0,
    sink_operation_count: [sink_operation_count]u64 = @splat(0),
    sink_operation_latency_ns_total: [sink_operation_count]u64 = @splat(0),
    sink_operation_latency_ns_max: [sink_operation_count]u64 = @splat(0),
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

    fn recordWindowFull(self: *Cell, duration_ns: u64) void {
        self.window_full_count +|= 1;
        self.window_full_duration_ns_total +|= duration_ns;
        self.window_full_duration_ns_max = @max(
            self.window_full_duration_ns_max,
            duration_ns,
        );
    }

    fn recordSinkOperation(
        self: *Cell,
        operation: upload_metrics.SinkOperation,
        latency_ns: u64,
    ) void {
        const index = @intFromEnum(operation);
        self.sink_operation_count[index] +|= 1;
        self.sink_operation_latency_ns_total[index] +|= latency_ns;
        self.sink_operation_latency_ns_max[index] = @max(
            self.sink_operation_latency_ns_max[index],
            latency_ns,
        );
    }

    fn recordFinalization(self: *Cell, report: finalization.Report) void {
        self.finalization_outcomes[@intFromEnum(report.outcome)] +|= 1;
        self.commit_attempted +|= report.commit_attempted_count;
        self.commit_completed +|= report.commit_completed_count;
        self.abort_attempted +|= report.abort_attempted_count;
        self.abort_completed +|= report.abort_completed_count;
        if (report.primary) |primary| {
            const class = upload_metrics.primaryFailureClass(primary.class);
            self.primary_failures[@intFromEnum(class)] +|= 1;
        }
    }
};

comptime {
    validateCellBytes(@sizeOf(Cell));
}

pub const Snapshot = struct {
    worker_index: u16,
    route_id: u16,
    window: u8,
    cell: Cell,
};

pub fn Table(comptime App: type) type {
    const use_app_profiles = hasProfiles(App);
    const profiles = if (use_app_profiles)
        App.upload_route_profiles
    else
        [_]LegacyProfile{.{
            .route_id = 0,
            .window = @intCast(App.upload_window_max),
        }};
    comptime {
        @setEvalBranchQuota(100_000);
        validateProfiles(App, profiles);
    }

    return struct {
        const Self = @This();

        pub const profile_count = profiles.len;

        pub const Recorder = struct {
            aggregate: *upload_metrics.Metrics,
            cell: ?*Cell,
            route_id: u16,

            pub fn recordWindowFull(self: *Recorder, duration_ns: u64) void {
                self.aggregate.recordWindowFull(duration_ns);
                if (self.cell) |cell| cell.recordWindowFull(duration_ns);
            }

            pub fn recordSinkOperation(
                self: *Recorder,
                operation: upload_metrics.SinkOperation,
                latency_ns: u64,
            ) void {
                self.aggregate.recordSinkOperation(operation, latency_ns);
                if (self.cell) |cell| cell.recordSinkOperation(operation, latency_ns);
            }

            pub fn recordCancellation(
                self: *Recorder,
                outcome: upload_metrics.CancellationOutcome,
            ) void {
                self.aggregate.recordCancellation(outcome);
                if (self.cell) |cell| cell.cancellations[@intFromEnum(outcome)] +|= 1;
            }

            pub fn recordRecoverableFailure(
                self: *Recorder,
                class: upload_metrics.RecoverableFailureClass,
                identity: ?upload_metrics.Identity,
            ) void {
                self.aggregate.recordRecoverableFailureForRoute(
                    class,
                    identity,
                    self.route_id,
                );
                if (self.cell) |cell| {
                    cell.recoverable_failures[@intFromEnum(class)] +|= 1;
                }
            }

            pub fn recordFatalFailure(
                self: *Recorder,
                class: upload_metrics.FatalFailureClass,
                identity: ?upload_metrics.Identity,
            ) void {
                self.aggregate.recordFatalFailureForRoute(class, identity, self.route_id);
                if (self.cell) |cell| cell.fatal_failures[@intFromEnum(class)] +|= 1;
            }

            pub fn recordFinalization(
                self: *Recorder,
                report: finalization.Report,
            ) void {
                self.aggregate.recordFinalizationForRoute(report, self.route_id);
                if (self.cell) |cell| cell.recordFinalization(report);
            }

            pub fn recordFinalizationCleanup(
                self: *Recorder,
                failure: finalization.CleanupFailure,
            ) void {
                self.aggregate.recordFinalizationCleanupForRoute(failure, self.route_id);
                if (self.cell) |cell| {
                    cell.cleanup_failures[@intFromEnum(failure.class)] +|= 1;
                }
            }
        };

        cells: [profiles.len]Cell = @splat(.{}),

        pub fn captureRequest(
            self: *Self,
            workspace: anytype,
            state: anytype,
        ) !void {
            _ = self;
            if (state.route_captured) return;
            const route_id = if (comptime use_app_profiles)
                App.__multipartUploadRouteId(workspace) catch return error.StateInvariant
            else
                0;
            state.route_id = route_id;
            const index = profileIndex(route_id) orelse {
                state.route_profile_index = aggregate_only_profile;
                state.route_captured = true;
                return;
            };
            state.route_profile_index = @intCast(index);
            state.route_window = profiles[index].window;
            state.route_captured = true;
        }

        pub fn recorder(
            self: *Self,
            aggregate: *upload_metrics.Metrics,
            profile_index: u32,
        ) !Recorder {
            if (profile_index >= self.cells.len) return error.StateInvariant;
            return .{
                .aggregate = aggregate,
                .cell = &self.cells[profile_index],
                .route_id = profiles[profile_index].route_id,
            };
        }

        pub fn recorderForRoute(
            self: *Self,
            aggregate: *upload_metrics.Metrics,
            profile_index: u32,
            route_id: u16,
        ) !Recorder {
            if (profile_index == aggregate_only_profile) return .{
                .aggregate = aggregate,
                .cell = null,
                .route_id = route_id,
            };
            if (profile_index >= profiles.len or
                profiles[profile_index].route_id != route_id)
            {
                return error.StateInvariant;
            }
            return self.recorder(aggregate, profile_index);
        }

        pub fn snapshot(
            self: *const Self,
            worker_index: u16,
            route_id: u16,
        ) ?Snapshot {
            const index = profileIndex(route_id) orelse return null;
            return .{
                .worker_index = worker_index,
                .route_id = route_id,
                .window = profiles[index].window,
                .cell = self.cells[index],
            };
        }

        fn profileIndex(route_id: u16) ?usize {
            var low: usize = 0;
            var high: usize = profiles.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const candidate = profiles[middle].route_id;
                if (route_id < candidate) {
                    high = middle;
                } else if (route_id > candidate) {
                    low = middle + 1;
                } else {
                    return middle;
                }
            }
            return null;
        }
    };
}

pub fn tableBytes(comptime App: type) usize {
    return @sizeOf(Table(App));
}

pub fn validateCellBytes(comptime bytes: usize) void {
    if (bytes > cell_bytes_max) {
        @compileError("PLOOF-E3532 upload route metric cell exceeds 640 bytes");
    }
}

fn hasProfiles(comptime App: type) bool {
    return @hasDecl(App, "upload_route_profiles") and
        @hasDecl(App, "__multipartUploadRouteId");
}

fn validateProfiles(comptime App: type, comptime profiles: anytype) void {
    if (profiles.len == 0) {
        @compileError("PLOOF-E3533 async upload application has no route profiles");
    }
    for (profiles, 0..) |profile, index| {
        if (profile.window == 0 or profile.window > App.upload_window_max) {
            @compileError("PLOOF-E3534 upload route window is outside application maximum");
        }
        if (index != 0 and profiles[index - 1].route_id >= profile.route_id) {
            @compileError(
                "PLOOF-E3535 upload route profiles must be unique and strictly ascending",
            );
        }
    }
}

test "route metric cells remain compact and tables contain only exact cells" {
    const App = struct {
        pub const upload_window_max: u32 = 4;
    };
    const RouteTable = Table(App);
    try std.testing.expectEqual(@as(usize, 1), RouteTable.profile_count);
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(Cell));
    try std.testing.expect(@sizeOf(Cell) <= cell_bytes_max);
    try std.testing.expectEqual(@sizeOf(Cell), @sizeOf(RouteTable));
    try std.testing.expectEqual(
        @as(usize, 2 * 1024 * 1024),
        @sizeOf(Cell) * 4096,
    );
}

test "aggregate-only sentinel is outside every valid u16 route index" {
    const last_profile_index: u32 = std.math.maxInt(u16);
    try std.testing.expect(aggregate_only_profile > last_profile_index);
}

test "maximum sparse route profile lookup is bounded and exact" {
    const profile_count = 4096;
    const App = struct {
        pub const upload_window_max: u32 = 4;
        pub const upload_route_profiles = profiles: {
            @setEvalBranchQuota(100_000);
            var result: [profile_count]LegacyProfile = undefined;
            for (&result, 0..) |*profile, route_id| {
                profile.* = .{ .route_id = @intCast(route_id), .window = 4 };
            }
            break :profiles result;
        };

        pub fn __multipartUploadRouteId() void {}
    };
    const RouteTable = Table(App);
    try std.testing.expectEqual(@as(?usize, 0), RouteTable.profileIndex(0));
    try std.testing.expectEqual(@as(?usize, 2048), RouteTable.profileIndex(2048));
    try std.testing.expectEqual(@as(?usize, 4095), RouteTable.profileIndex(4095));
    try std.testing.expectEqual(@as(?usize, null), RouteTable.profileIndex(4096));
    try std.testing.expectEqual(@sizeOf(Cell) * profile_count, @sizeOf(RouteTable));
}

test "synchronous multipart route records tagged aggregate without sparse cell" {
    const Workspace = struct { route_id: u16 = 2 };
    const App = struct {
        pub const upload_window_max: u32 = 4;
        pub const upload_route_profiles = [_]LegacyProfile{
            .{ .route_id = 1, .window = 4 },
        };

        pub fn __multipartUploadRouteId(workspace: *Workspace) error{}!u16 {
            return workspace.route_id;
        }
    };
    const RequestState = struct {
        route_id: u16 = 0,
        route_profile_index: u32 = 0,
        route_window: u8 = 0,
        route_captured: bool = false,
    };
    const RouteTable = Table(App);
    var table = RouteTable{};
    var aggregate = upload_metrics.Metrics{};
    var workspace = Workspace{};
    var state = RequestState{};
    try table.captureRequest(&workspace, &state);
    try std.testing.expect(state.route_captured);
    try std.testing.expectEqual(aggregate_only_profile, state.route_profile_index);
    try std.testing.expectEqual(@as(u8, 0), state.route_window);
    var recorder = try table.recorderForRoute(
        &aggregate,
        state.route_profile_index,
        state.route_id,
    );
    recorder.recordFinalization(.{
        .outcome = .aborted,
        .primary = null,
        .instance_count = 0,
        .commit_attempted_count = 0,
        .commit_completed_count = 0,
        .abort_attempted_count = 1,
        .abort_completed_count = 1,
        .cleanup_failure_count = 0,
    });
    try std.testing.expect(table.snapshot(3, 2) == null);
    try std.testing.expectEqual(@as(?u16, 2), aggregate.snapshot().events[0].route_id);
}

test {
    std.testing.refAllDecls(@This());
}

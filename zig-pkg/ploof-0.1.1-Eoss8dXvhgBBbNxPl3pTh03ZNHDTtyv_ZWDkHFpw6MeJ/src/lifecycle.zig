const std = @import("std");

pub const standard_grace_ns: u64 = 30 * std.time.ns_per_s;
pub const standard_force_ns: u64 = 5 * std.time.ns_per_s;

pub const Phase = enum(u8) {
    starting,
    ready,
    draining,
    stopped,
    failed,
};

pub const DrainStage = enum(u8) {
    none,
    grace,
    forced,
};

pub const Transition = enum(u8) {
    unchanged,
    advanced,
};

pub const ProfileIssue = enum(u8) {
    total_duration_overflow,
};

pub const ShutdownProfile = struct {
    grace_ns: u64 = standard_grace_ns,
    force_ns: u64 = standard_force_ns,

    pub fn issue(profile: ShutdownProfile) ?ProfileIssue {
        _ = std.math.add(u64, profile.grace_ns, profile.force_ns) catch {
            return .total_duration_overflow;
        };
        return null;
    }

    pub fn validate(comptime profile: ShutdownProfile) ShutdownProfile {
        if (profile.issue()) |problem| switch (problem) {
            .total_duration_overflow => @compileError(
                "PLOOF-E6000 shutdown grace and forced durations overflow u64",
            ),
        };
        return profile;
    }
};

pub const Deadlines = struct {
    grace_ns: u64,
    force_ns: u64,
};

pub const DeadlineError = error{DeadlineOverflow};

pub fn deadlines(start_ns: u64, profile: ShutdownProfile) DeadlineError!Deadlines {
    if (profile.issue() != null) return error.DeadlineOverflow;
    const grace_ns = std.math.add(u64, start_ns, profile.grace_ns) catch {
        return error.DeadlineOverflow;
    };
    const force_ns = std.math.add(u64, grace_ns, profile.force_ns) catch {
        return error.DeadlineOverflow;
    };
    return .{ .grace_ns = grace_ns, .force_ns = force_ns };
}

const State = enum(u8) {
    starting,
    ready,
    draining_grace,
    draining_forced,
    stopped,
    failed,
};

/// Process-wide lifecycle state. One atomic publishes phase and drain stage
/// together so workers cannot observe `draining` without its stage.
pub const Controller = struct {
    state: std.atomic.Value(State) = .init(.starting),

    pub fn phase(controller: *const Controller) Phase {
        return switch (controller.state.load(.acquire)) {
            .starting => .starting,
            .ready => .ready,
            .draining_grace, .draining_forced => .draining,
            .stopped => .stopped,
            .failed => .failed,
        };
    }

    pub fn drainStage(controller: *const Controller) DrainStage {
        return switch (controller.state.load(.acquire)) {
            .draining_grace => .grace,
            .draining_forced => .forced,
            else => .none,
        };
    }

    pub fn isLive(controller: *const Controller) bool {
        return switch (controller.phase()) {
            .starting, .ready, .draining => true,
            .stopped, .failed => false,
        };
    }

    pub fn isReady(controller: *const Controller) bool {
        return controller.phase() == .ready;
    }

    pub fn markReady(controller: *Controller) Transition {
        return if (controller.state.cmpxchgStrong(
            .starting,
            .ready,
            .release,
            .acquire,
        ) == null) .advanced else .unchanged;
    }

    pub fn markFailed(controller: *Controller) Transition {
        return if (controller.state.cmpxchgStrong(
            .starting,
            .failed,
            .release,
            .acquire,
        ) == null) .advanced else .unchanged;
    }

    pub fn beginDrain(controller: *Controller) Transition {
        var current = controller.state.load(.acquire);
        while (current == .starting or current == .ready) {
            if (controller.state.cmpxchgWeak(
                current,
                .draining_grace,
                .acq_rel,
                .acquire,
            )) |actual| {
                current = actual;
                continue;
            }
            return .advanced;
        }
        return .unchanged;
    }

    pub fn beginForced(controller: *Controller) Transition {
        return if (controller.state.cmpxchgStrong(
            .draining_grace,
            .draining_forced,
            .acq_rel,
            .acquire,
        ) == null) .advanced else .unchanged;
    }

    pub fn markStopped(controller: *Controller) Transition {
        var current = controller.state.load(.acquire);
        while (current == .draining_grace or current == .draining_forced) {
            if (controller.state.cmpxchgWeak(
                current,
                .stopped,
                .release,
                .acquire,
            )) |actual| {
                current = actual;
                continue;
            }
            return .advanced;
        }
        return .unchanged;
    }
};

/// State-owned readiness binding. Server binds it once during `start`; handlers
/// can observe exact server lifecycle without a Server/App type cycle.
pub const Readiness = struct {
    controller_address: std.atomic.Value(usize) = .init(0),

    pub const BindError = error{AlreadyBound};

    pub fn bind(readiness: *Readiness, controller: *const Controller) BindError!void {
        const address = @intFromPtr(controller);
        const previous = readiness.controller_address.cmpxchgStrong(
            0,
            address,
            .release,
            .acquire,
        );
        if (previous != null and previous.? != address) return error.AlreadyBound;
    }

    pub fn isReady(readiness: *const Readiness) bool {
        const address = readiness.controller_address.load(.acquire);
        if (address == 0) return false;
        const controller: *const Controller = @ptrFromInt(address);
        return controller.isReady();
    }
};

pub const Remaining = struct {
    workers: u16 = 0,
    listeners: u16 = 0,
    connections: u32 = 0,
    requests: u32 = 0,
    network_operations: u32 = 0,
    file_operations: u32 = 0,
    cancel_operations: u32 = 0,
    borrowed_buffers: u32 = 0,
    gzip_jobs: u32 = 0,
    stream_publishers: u32 = 0,
    upload_finalizers: u32 = 0,
    middleware_after: u32 = 0,
    helper_jobs: u32 = 0,
    logger_events: u32 = 0,
};

pub const ShutdownIncomplete = struct {
    remaining: Remaining,
    dropped_access_events: u64,

    pub fn empty(report: ShutdownIncomplete) bool {
        return std.meta.eql(report.remaining, Remaining{}) and
            report.dropped_access_events == 0;
    }

    pub fn render(
        report: ShutdownIncomplete,
        output: []u8,
    ) std.fmt.BufPrintError![]const u8 {
        const r = report.remaining;
        return std.fmt.bufPrint(
            output,
            "PLOOF shutdown incomplete: workers={d} listeners={d} " ++
                "connections={d} requests={d} network_ops={d} file_ops={d} " ++
                "cancel_ops={d} borrowed_buffers={d} gzip_jobs={d} " ++
                "stream_publishers={d} upload_finalizers={d} middleware_after={d} " ++
                "helper_jobs={d} logger_events={d} dropped_access_events={d}\n",
            .{
                r.workers,
                r.listeners,
                r.connections,
                r.requests,
                r.network_operations,
                r.file_operations,
                r.cancel_operations,
                r.borrowed_buffers,
                r.gzip_jobs,
                r.stream_publishers,
                r.upload_finalizers,
                r.middleware_after,
                r.helper_jobs,
                r.logger_events,
                report.dropped_access_events,
            },
        );
    }
};

test "lifecycle advances irreversibly and repeated commands are idempotent" {
    var controller = Controller{};
    try std.testing.expectEqual(Phase.starting, controller.phase());
    try std.testing.expectEqual(Transition.advanced, controller.markReady());
    try std.testing.expect(controller.isReady());
    try std.testing.expectEqual(Transition.unchanged, controller.markReady());
    try std.testing.expectEqual(Transition.unchanged, controller.markFailed());

    try std.testing.expectEqual(Transition.advanced, controller.beginDrain());
    try std.testing.expectEqual(Phase.draining, controller.phase());
    try std.testing.expectEqual(DrainStage.grace, controller.drainStage());
    try std.testing.expectEqual(Transition.unchanged, controller.beginDrain());
    try std.testing.expectEqual(Transition.advanced, controller.beginForced());
    try std.testing.expectEqual(Transition.unchanged, controller.beginForced());
    try std.testing.expectEqual(Transition.advanced, controller.markStopped());
    try std.testing.expectEqual(Transition.unchanged, controller.markStopped());
    try std.testing.expectEqual(Phase.stopped, controller.phase());
    try std.testing.expect(!controller.isLive());
}

test "shutdown during startup prevents readiness and startup failure is terminal" {
    var draining = Controller{};
    try std.testing.expectEqual(Transition.advanced, draining.beginDrain());
    try std.testing.expectEqual(Transition.unchanged, draining.markReady());
    try std.testing.expectEqual(Transition.unchanged, draining.markFailed());

    var failed = Controller{};
    try std.testing.expectEqual(Transition.advanced, failed.markFailed());
    try std.testing.expectEqual(Transition.unchanged, failed.markReady());
    try std.testing.expectEqual(Transition.unchanged, failed.beginDrain());
    try std.testing.expectEqual(Phase.failed, failed.phase());
    try std.testing.expect(!failed.isLive());
}

test "shutdown deadlines are checked and zero durations are immediate" {
    try std.testing.expectEqualDeep(
        Deadlines{ .grace_ns = 40, .force_ns = 45 },
        try deadlines(10, .{ .grace_ns = 30, .force_ns = 5 }),
    );
    try std.testing.expectEqualDeep(
        Deadlines{ .grace_ns = 10, .force_ns = 10 },
        try deadlines(10, .{ .grace_ns = 0, .force_ns = 0 }),
    );
    try std.testing.expectError(
        error.DeadlineOverflow,
        deadlines(std.math.maxInt(u64), .{ .grace_ns = 1 }),
    );
    try std.testing.expectEqual(
        ProfileIssue.total_duration_overflow,
        (ShutdownProfile{
            .grace_ns = std.math.maxInt(u64),
            .force_ns = 1,
        }).issue().?,
    );
}

test "concurrent drain and force requests advance exactly once" {
    const Race = struct {
        controller: *Controller,
        drain_wins: *std.atomic.Value(u8),
        force_wins: *std.atomic.Value(u8),

        fn run(race: @This()) void {
            if (race.controller.beginDrain() == .advanced) {
                _ = race.drain_wins.fetchAdd(1, .monotonic);
            }
            if (race.controller.beginForced() == .advanced) {
                _ = race.force_wins.fetchAdd(1, .monotonic);
            }
        }
    };

    var controller = Controller{};
    _ = controller.markReady();
    var drain_wins = std.atomic.Value(u8).init(0);
    var force_wins = std.atomic.Value(u8).init(0);
    const race = Race{
        .controller = &controller,
        .drain_wins = &drain_wins,
        .force_wins = &force_wins,
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Race.run, .{race});
    for (&threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u8, 1), drain_wins.load(.acquire));
    try std.testing.expectEqual(@as(u8, 1), force_wins.load(.acquire));
    try std.testing.expectEqual(DrainStage.forced, controller.drainStage());
}

test "shutdown report contains counts only and detects quiescence" {
    const complete = ShutdownIncomplete{
        .remaining = .{},
        .dropped_access_events = 0,
    };
    try std.testing.expect(complete.empty());
    const logging_loss = ShutdownIncomplete{
        .remaining = .{},
        .dropped_access_events = 3,
    };
    try std.testing.expect(!logging_loss.empty());
    const incomplete = ShutdownIncomplete{
        .remaining = .{ .connections = 1 },
        .dropped_access_events = 0,
    };
    try std.testing.expect(!incomplete.empty());

    var output: [512]u8 = undefined;
    const rendered = try incomplete.render(&output);
    try std.testing.expect(std.mem.startsWith(
        u8,
        rendered,
        "PLOOF shutdown incomplete: workers=0 listeners=0 connections=1",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        rendered,
        "logger_events=0 dropped_access_events=0\n",
    ));
}

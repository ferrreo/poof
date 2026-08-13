const std = @import("std");
const lifecycle = @import("../../../lifecycle.zig");
const server_types = @import("../../../server/types.zig");
const server_clock = @import("clock.zig");
const server_report = @import("report.zig");
const server_wait = @import("wait.zig");

pub const GraceWait = enum(u8) { terminal, forced, signal, deadline };

pub fn shutdown(
    comptime ErrorType: type,
    server: anytype,
    comptime signaled: bool,
    source: anytype,
    comptime assertStable: anytype,
    comptime beginDrainLocked: anytype,
    comptime shutdownDeadlines: anytype,
    comptime waitForStartup: anytype,
    comptime startupIncomplete: anytype,
) ErrorType!server_types.ShutdownResult {
    server.shutdown_call_mutex.lock();
    defer server.shutdown_call_mutex.unlock();
    if (!server.start_attempted.load(.acquire)) return error.ServerNotRunning;
    assertStable(server);
    server.shutdown_mutex.lock();
    switch (server.lifecycle_controller.phase()) {
        .stopped => {
            server.shutdown_mutex.unlock();
            return finalizedResult(server);
        },
        .failed => {
            server.shutdown_mutex.unlock();
            return error.ServerNotRunning;
        },
        .starting, .ready, .draining => {},
    }
    _ = beginDrainLocked(server) catch |problem| {
        server.shutdown_mutex.unlock();
        return problem;
    };
    const bounds = shutdownDeadlines(server);
    server.shutdown_mutex.unlock();

    if (!(try waitForStartup(server, bounds))) return startupIncomplete(server);
    if (server.lifecycle_controller.phase() == .stopped) return .stopped;
    if (server.lifecycle_controller.drainStage() == .grace) {
        const signal_descriptor = if (signaled) source.descriptor else null;
        switch (try waitGrace(server, bounds.grace_ns, signal_descriptor)) {
            .terminal => return finishTerminal(server, bounds.force_ns),
            .signal => if (signaled) {
                _ = (try source.next()) orelse return error.SignalFdReadFailed;
            } else unreachable,
            .forced, .deadline => {},
        }
        _ = try server.beginForced();
    }
    if (try waitForTerminal(server, bounds.force_ns)) {
        return finishTerminal(server, bounds.force_ns);
    }
    return .{ .incomplete = report(server) };
}

pub fn report(server: anytype) lifecycle.ShutdownIncomplete {
    var result = lifecycle.ShutdownIncomplete{
        .remaining = .{},
        .dropped_access_events = 0,
    };
    for (server.nodes[0..server.worker_count]) |*node| {
        const snapshot = node.published.snapshot();
        server_report.add(&result, snapshot);
        if (node.status.load(.acquire) == .runtime_failed and
            snapshot.remaining.workers == 0)
        {
            result.remaining.workers = server_report.count(
                u16,
                result.remaining.workers,
                1,
            );
        }
    }
    const logger = server.observability.loggerReport();
    result.remaining.logger_events = server_report.count(
        u32,
        result.remaining.logger_events,
        logger.queued_events,
    );
    result.remaining.logger_events = server_report.count(
        u32,
        result.remaining.logger_events,
        logger.in_flight_events,
    );
    result.dropped_access_events +|= logger.dropped_events;
    result.remaining.helper_jobs = server_report.count(
        u32,
        result.remaining.helper_jobs,
        server.metrics.helperJobs(),
    );
    return result;
}

pub fn waitForTerminal(server: anytype, deadline_ns: u64) !bool {
    while (!allTerminal(server)) {
        if (!server.completion_live.load(.acquire)) return false;
        switch (try server_wait.until(server.completion.descriptor, null, deadline_ns)) {
            .deadline => return false,
            .completion => switch (server.completion.drain()) {
                .count => {},
                .empty, .failed => return error.CompletionCounterFailed,
            },
            .signal => unreachable,
        }
    }
    return true;
}

pub fn waitGrace(
    server: anytype,
    deadline_ns: u64,
    signal_descriptor: ?std.os.linux.fd_t,
) !GraceWait {
    while (!allTerminal(server)) {
        if (server.lifecycle_controller.drainStage() == .forced) return .forced;
        if (!server.completion_live.load(.acquire)) return .deadline;
        switch (try server_wait.until(
            server.completion.descriptor,
            signal_descriptor,
            deadline_ns,
        )) {
            .deadline => return .deadline,
            .completion => switch (server.completion.drain()) {
                .count, .empty => {},
                .failed => return error.CompletionCounterFailed,
            },
            .signal => return .signal,
        }
    }
    return .terminal;
}

pub fn finishTerminal(server: anytype, deadline_ns: u64) server_types.ShutdownResult {
    joinThreads(server);
    if (!stopMetricsUntil(server, deadline_ns)) return .{ .incomplete = report(server) };
    closeCompletion(server);
    if (!stopLoggerUntil(server, deadline_ns)) return .{ .incomplete = report(server) };
    const final_report = report(server);
    server.shutdown_final_report = final_report;
    server.shutdown_finalized = true;
    _ = server.lifecycle_controller.markStopped();
    return if (final_report.empty()) .stopped else .{ .incomplete = final_report };
}

pub fn stopMetricsUntil(server: anytype, deadline_ns: u64) bool {
    return server.metrics.stopUntil(deadline_ns);
}

pub fn finalizedResult(server: anytype) server_types.ShutdownResult {
    if (!server.shutdown_finalized or server.shutdown_final_report.empty()) return .stopped;
    return .{ .incomplete = server.shutdown_final_report };
}

pub fn joinThreads(server: anytype) void {
    for (server.nodes[0..server.thread_count]) |*node| {
        node.thread.?.join();
        node.thread = null;
    }
    server.thread_count = 0;
    server.commands_ready.store(false, .release);
}

pub fn stopLoggerUntil(server: anytype, deadline_ns: u64) bool {
    server.observability.requestLoggerStop();
    while (!server.observability.loggerTerminal()) {
        const now_ns = server_clock.monotonicNow() catch return false;
        if (now_ns >= deadline_ns) return false;
        const event = server.observability.loggerTerminalEvent();
        const observed = event.observe();
        if (server.observability.loggerTerminal()) break;
        if (!event.arm(observed)) continue;
        switch (event.waitFor(observed, deadline_ns - now_ns)) {
            .notified, .interrupted => {},
            .timed_out => if (!server.observability.loggerTerminal()) return false,
        }
    }
    server.observability.joinLogger();
    return true;
}

fn closeCompletion(server: anytype) void {
    if (!server.completion_live.swap(false, .acq_rel)) return;
    _ = server.completion.close();
}

fn allTerminal(server: anytype) bool {
    for (server.nodes[0..server.thread_count]) |*node| {
        switch (node.status.load(.acquire)) {
            .startup_failed, .stopped, .runtime_failed => {},
            .empty, .initializing, .bootstrapped, .ready => return false,
        }
    }
    return true;
}

test "shutdown report includes event currently owned by logger sink" {
    const Status = enum(u8) { idle, runtime_failed };
    const Published = struct {
        pub fn snapshot(_: *const @This()) lifecycle.ShutdownIncomplete {
            return .{ .remaining = .{}, .dropped_access_events = 0 };
        }
    };
    const Node = struct {
        published: Published = .{},
        status: std.atomic.Value(Status) = .init(.idle),
    };
    const LoggerReport = struct {
        queued_events: u32,
        in_flight_events: u32,
        dropped_events: u64,
    };
    const Observability = struct {
        value: LoggerReport,

        pub fn loggerReport(self: *const @This()) LoggerReport {
            return self.value;
        }
    };
    const Metrics = struct {
        pub fn helperJobs(_: *const @This()) u32 {
            return 0;
        }
    };
    const TestServer = struct {
        nodes: [1]Node = .{.{}},
        worker_count: u16 = 0,
        observability: Observability,
        metrics: Metrics = .{},
    };
    var server = TestServer{ .observability = .{ .value = .{
        .queued_events = 2,
        .in_flight_events = 1,
        .dropped_events = 3,
    } } };

    const actual = report(&server);
    try std.testing.expectEqual(@as(u32, 3), actual.remaining.logger_events);
    try std.testing.expectEqual(@as(u64, 3), actual.dropped_access_events);
}

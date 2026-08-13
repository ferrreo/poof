const std = @import("std");

const metrics = @import("../../../metrics.zig");
const lifecycle = @import("../../../lifecycle.zig");
const futex_epoch = @import("../futex_epoch.zig");
const server_clock = @import("clock.zig");

pub const Error = metrics.SnapshotError || server_clock.Error ||
    @import("command.zig").Error || error{ SnapshotDeadline, ServerNotReady };

pub fn snapshot(
    server: anytype,
    deadline_ns: u64,
    output: anytype,
) Error!void {
    server.shutdown_mutex.lock();
    if (server.lifecycle_controller.phase() != .ready) {
        server.shutdown_mutex.unlock();
        return error.ServerNotReady;
    }
    const epoch = server.observability.beginSnapshot(server.worker_count) catch |problem| {
        server.shutdown_mutex.unlock();
        return problem;
    };
    publishWake(server) catch |problem| {
        server.observability.cancelSnapshot(epoch, false);
        server.shutdown_mutex.unlock();
        return problem;
    };
    server.shutdown_mutex.unlock();
    return await(server, epoch, deadline_ns, output);
}

fn publishWake(server: anytype) @import("command.zig").Error!void {
    for (server.nodes[0..server.configured_count]) |*node| {
        switch (node.status.load(.acquire)) {
            .startup_failed, .stopped, .runtime_failed => continue,
            .empty, .initializing, .bootstrapped, .ready => {},
        }
        _ = try node.command.publish(.serve);
    }
}

fn await(
    server: anytype,
    epoch: u64,
    deadline_ns: u64,
    output: anytype,
) Error!void {
    while (true) {
        const observed = server.observability.snapshot_event.observe();
        if (try tryComplete(server, epoch, output)) return;
        const now_ns = try server_clock.monotonicNow();
        if (now_ns >= deadline_ns) return cancelDeadline(server, epoch);
        if (!server.observability.snapshot_event.arm(observed)) continue;
        switch (server.observability.snapshot_event.waitFor(
            observed,
            deadline_ns - now_ns,
        )) {
            .notified, .interrupted => {},
            .timed_out => return cancelDeadline(server, epoch),
        }
    }
}

fn tryComplete(server: anytype, epoch: u64, output: anytype) Error!bool {
    server.observability.completeSnapshot(epoch, output) catch |problem| switch (problem) {
        error.SnapshotPending => return false,
        else => return problem,
    };
    return true;
}

fn cancelDeadline(server: anytype, epoch: u64) error{SnapshotDeadline} {
    server.observability.cancelSnapshot(epoch, true);
    return error.SnapshotDeadline;
}

test {
    _ = lifecycle.Phase.ready;
}

test "server_metrics_runtime snapshot completion between check and arm cannot be missed" {
    const Observation = struct {
        snapshot_event: futex_epoch.Event = .{},
        ready: bool = false,
        complete_calls: u8 = 0,
        canceled: bool = false,

        fn completeSnapshot(
            self: *@This(),
            _: u64,
            output: *u8,
        ) metrics.SnapshotError!void {
            self.complete_calls += 1;
            if (!self.ready) {
                self.ready = true;
                self.snapshot_event.notify();
                return error.SnapshotPending;
            }
            output.* = 42;
        }

        fn cancelSnapshot(self: *@This(), _: u64, _: bool) void {
            self.canceled = true;
        }
    };
    const Server = struct { observability: Observation = .{} };

    var server = Server{};
    var output: u8 = 0;
    const now_ns = try server_clock.monotonicNow();
    try await(&server, 1, now_ns + std.time.ns_per_s, &output);

    try std.testing.expectEqual(@as(u8, 42), output);
    try std.testing.expectEqual(@as(u8, 2), server.observability.complete_calls);
    try std.testing.expect(!server.observability.canceled);
}

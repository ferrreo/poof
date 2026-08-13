const std = @import("std");
const sigbench = @import("sigbench");

const lifecycle = @import("../src/lifecycle.zig");
const server_status = @import("../src/internal/runtime/server/status.zig");

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof server lifecycle benchmark validity check failed");
}

fn benchTransitions(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var completed: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                var controller = lifecycle.Controller{};
                if (controller.markReady() != .advanced) benchmarkFailure();
                if (controller.beginDrain() != .advanced) benchmarkFailure();
                if (controller.beginForced() != .advanced) benchmarkFailure();
                if (controller.markStopped() != .advanced) benchmarkFailure();
                completed += @intFromBool(controller.phase() == .stopped);
                std.mem.doNotOptimizeAway(&controller);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (completed != iterations) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

const CleanupStatus = struct {
    live_connections: u16 = 2,
    live_requests: u16 = 1,
    listener_operations: u8 = 1,
    connection_operations: u32 = 4,
    borrowed_receives: u16 = 2,
    gzip_active_jobs: u16 = 1,
    stream_active_publishers: u16 = 1,

    pub fn quiescent(_: CleanupStatus) bool {
        return false;
    }
};

fn benchStatusSnapshot(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var published = server_status.Published{};
            var workers: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                published.publish(CleanupStatus{}, .{
                    .listener_live = true,
                    .control_operations = 1,
                });
                const snapshot = published.snapshot();
                workers += snapshot.remaining.workers;
                std.mem.doNotOptimizeAway(&snapshot);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (workers != iterations) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

pub const group = sigbench.groupWithId("m13-lifecycle", "M13 server lifecycle", .{
    sigbench.benchWithThroughput(
        "irreversible-transitions",
        "one ready drain force stopped sequence",
        .{ .elements = 4 },
        benchTransitions,
    ),
    sigbench.benchWithThroughput(
        "cleanup-snapshot",
        "one worker cleanup publication and stable snapshot",
        .{ .elements = 1 },
        benchStatusSnapshot,
    ),
});

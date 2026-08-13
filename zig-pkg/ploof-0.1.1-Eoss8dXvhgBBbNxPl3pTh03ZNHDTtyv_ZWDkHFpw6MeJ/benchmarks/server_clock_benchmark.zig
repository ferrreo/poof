const std = @import("std");
const sigbench = @import("sigbench");

const server_clock = @import("../src/internal/runtime/server/clock.zig");

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof server clock benchmark validity check failed");
}

fn benchCachedSample(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runSamples(iterations, false);
        }
    }.run);
}

fn benchResyncSample(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runSamples(iterations, true);
        }
    }.run);
}

fn runSamples(iterations: u64, comptime resync_each_sample: bool) u64 {
    var clock = server_clock.Clock{};
    const initial = clock.sample() catch benchmarkFailure();
    var previous_ns = initial.monotonic_ns;
    var checksum: u64 = 0;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        if (comptime resync_each_sample) clock = .{};
        const sample = clock.sample() catch benchmarkFailure();
        if (sample.monotonic_ns < previous_ns or sample.epoch_second <= 0) {
            benchmarkFailure();
        }
        previous_ns = sample.monotonic_ns;
        checksum +%= sample.monotonic_ns ^ @as(u64, @intCast(sample.epoch_second));
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return elapsed_ns;
}

pub const group = sigbench.groupWithId("m13-server-clock", "M13 server clock", .{
    sigbench.benchWithThroughput(
        "cached-sample",
        "one steady-state monotonic sample with cached realtime",
        .{ .elements = 1 },
        benchCachedSample,
    ),
    sigbench.benchWithThroughput(
        "resync-sample",
        "one monotonic and realtime resynchronization sample",
        .{ .elements = 1 },
        benchResyncSample,
    ),
});

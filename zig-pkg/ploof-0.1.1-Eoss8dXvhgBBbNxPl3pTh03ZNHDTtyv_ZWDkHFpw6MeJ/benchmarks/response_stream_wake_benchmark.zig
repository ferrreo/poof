const std = @import("std");
const sigbench = @import("sigbench");

const deterministic_reactor = @import("../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../src/internal/runtime/reactor.zig");
const stream_wake = @import("../src/internal/runtime/worker/stream_wake.zig");
const stream_runtime = @import("../src/internal/runtime/worker/stream_runtime.zig");

pub const dense_slots: usize = 64;

const DispatchError = error{
    InvalidCompletion,
    StreamFailure,
    InvalidReadyIndex,
    ClaimFailed,
};

fn Harness(comptime slot_count: usize, comptime dense: bool) type {
    const Wakes = stream_wake.Fixed(slot_count);
    const Io = deterministic_reactor.DeterministicReactor(8);
    const ready_count = if (dense) slot_count else 1;

    return struct {
        const Self = @This();

        stream_wakes: Wakes = undefined,
        io: Io = .{},
        handles: [ready_count]stream_wake.StreamWake = undefined,
        callbacks: u64 = 0,

        fn init(self: *Self) void {
            self.io = .{};
            self.callbacks = 0;
            self.stream_wakes.init(0) catch benchmarkFailure();
            self.stream_wakes.start(&self.io) catch benchmarkFailure();
            for (&self.handles, 0..) |*handle, index| {
                const slot = if (dense) index else slot_count - 1;
                handle.* = self.stream_wakes.activate(@intCast(slot)) catch {
                    benchmarkFailure();
                };
            }
        }

        fn deinit(self: *Self) void {
            for (self.handles) |handle| {
                if (self.stream_wakes.invalidateBeforeAbort(handle) != .invalidated) {
                    benchmarkFailure();
                }
            }
            self.stream_wakes.confirmPublishersJoined() catch benchmarkFailure();
            self.stream_wakes.beginFatalAfterPublishersJoined() catch benchmarkFailure();
            const status = self.io.abort() catch benchmarkFailure();
            if (!status.ownership_proven) benchmarkFailure();
            self.stream_wakes.finishFatalAfterBackend() catch benchmarkFailure();
        }

        fn cycle(self: *Self) void {
            for (self.handles) |handle| {
                if (handle.markPending() != .pending) benchmarkFailure();
                if (handle.notify() != .published) benchmarkFailure();
            }
            const token = self.stream_wakes.currentPollToken() orelse benchmarkFailure();
            self.io.complete(token, .{ .success = .{ .wake = {} } }, false) catch {
                benchmarkFailure();
            };
            const completion = self.io.nextCompletion() orelse benchmarkFailure();
            stream_runtime.handle(
                DispatchError,
                self,
                &self.io,
                completion,
                self,
                onReady,
            ) catch benchmarkFailure();
        }

        fn onReady(self: *Self, index: u16) DispatchError!void {
            const handle_index: usize = if (dense) index else 0;
            if (dense) {
                if (index >= ready_count) return error.InvalidReadyIndex;
            } else if (index != slot_count - 1) {
                return error.InvalidReadyIndex;
            }
            if (self.handles[handle_index].claimReady() != .claimed) {
                return error.ClaimFailed;
            }
            self.callbacks += 1;
        }
    };
}

fn run(comptime slot_count: usize, comptime dense: bool, iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var harness: Harness(slot_count, dense) = undefined;
    harness.init();
    defer harness.deinit();
    harness.cycle();
    harness.callbacks = 0;

    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| harness.cycle();
    const elapsed_ns = sigbench.nowNs() - start_ns;
    const ready_count = if (dense) slot_count else 1;
    if (harness.callbacks != iterations * ready_count) benchmarkFailure();
    std.mem.doNotOptimizeAway(harness.callbacks);
    return elapsed_ns;
}

pub fn benchSparse64(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn call(iterations: u64) u64 {
            return run(64, false, iterations);
        }
    }.call);
}

pub fn benchSparse1024(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn call(iterations: u64) u64 {
            return run(1024, false, iterations);
        }
    }.call);
}

pub fn benchSparse8192(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn call(iterations: u64) u64 {
            return run(8192, false, iterations);
        }
    }.call);
}

pub fn benchDense64(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn call(iterations: u64) u64 {
            return run(dense_slots, true, iterations);
        }
    }.call);
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof response-stream wake dispatch benchmark validity check failed");
}

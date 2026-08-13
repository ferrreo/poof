const std = @import("std");

const reactor = @import("../reactor.zig");
const worker_runtime = @import("../worker.zig");

pub const Outcome = enum(u8) {
    progressed,
    flush_retry,
    interrupted,
    stopped,
};

/// Drives exactly one worker flush or completion through the blocking backend path.
pub fn Loop(
    comptime WorkerType: type,
    comptime BackendType: type,
    comptime ClockType: type,
) type {
    return struct {
        const Self = @This();

        worker: *WorkerType,
        backend: *BackendType,
        clock: *ClockType,

        pub fn init(
            worker: *WorkerType,
            backend: *BackendType,
            clock: *ClockType,
        ) Self {
            return .{
                .worker = worker,
                .backend = backend,
                .clock = clock,
            };
        }

        pub fn step(self: *Self) !Outcome {
            const status = self.worker.loopStatus();
            if (status.flush_pending) {
                return outcome(try self.worker.retryFlush());
            }
            if (status.phase == .stopped) return .stopped;

            const completion = self.backend.wait() catch |problem| switch (problem) {
                error.WaitInterrupted, error.WaitRetry => return .interrupted,
                else => {
                    const cleanup = self.worker.failBackend();
                    std.debug.assert(cleanup == error.BackendFailure);
                    return problem;
                },
            };
            const sample = self.clock.sample() catch |problem| {
                const cleanup = self.worker.failClock(completion);
                std.debug.assert(cleanup == error.InvalidClock);
                return problem;
            };
            return outcome(try self.worker.handle(completion, sample));
        }
    };
}

fn outcome(step: worker_runtime.Step) Outcome {
    return switch (step) {
        .progressed => .progressed,
        .flush_retry => .flush_retry,
        .stopped => .stopped,
    };
}

const FakeStatus = struct {
    phase: worker_runtime.Phase = .running,
    flush_pending: bool = false,
};

const FakeWorker = struct {
    status: FakeStatus = .{},
    retry_step: worker_runtime.Step = .progressed,
    handle_step: worker_runtime.Step = .progressed,
    fail_handle: bool = false,
    retry_calls: u8 = 0,
    handle_calls: u8 = 0,
    backend_failures: u8 = 0,
    clock_failures: u8 = 0,
    loop_status_calls: u8 = 0,
    cleanup_status_calls: u8 = 0,
    handled_completion: ?reactor.Completion = null,
    failed_clock_completion: ?reactor.Completion = null,

    fn loopStatus(self: *FakeWorker) FakeStatus {
        self.loop_status_calls += 1;
        return self.status;
    }

    fn cleanupStatus(self: *FakeWorker) FakeStatus {
        self.cleanup_status_calls += 1;
        return self.status;
    }

    fn retryFlush(self: *FakeWorker) error{FlushFailed}!worker_runtime.Step {
        self.retry_calls += 1;
        self.status.flush_pending = self.retry_step == .flush_retry;
        return self.retry_step;
    }

    fn handle(
        self: *FakeWorker,
        completion: reactor.Completion,
        _: worker_runtime.ClockSample,
    ) error{HandleFailed}!worker_runtime.Step {
        self.handle_calls += 1;
        self.handled_completion = completion;
        if (self.fail_handle) return error.HandleFailed;
        return self.handle_step;
    }

    fn failBackend(self: *FakeWorker) error{BackendFailure} {
        self.backend_failures += 1;
        self.status.phase = .stopped;
        return error.BackendFailure;
    }

    fn failClock(
        self: *FakeWorker,
        completion: reactor.Completion,
    ) error{InvalidClock} {
        self.clock_failures += 1;
        self.failed_clock_completion = completion;
        self.status.phase = .stopped;
        return error.InvalidClock;
    }
};

const WaitResult = union(enum) {
    completion: reactor.Completion,
    interrupted,
    retry,
    failed,
};

const FakeBackend = struct {
    next: WaitResult,
    wait_calls: u8 = 0,

    fn wait(
        self: *FakeBackend,
    ) error{ WaitInterrupted, WaitRetry, WaitFailed }!reactor.Completion {
        self.wait_calls += 1;
        return switch (self.next) {
            .completion => |completion| completion,
            .interrupted => error.WaitInterrupted,
            .retry => error.WaitRetry,
            .failed => error.WaitFailed,
        };
    }
};

const FakeClock = struct {
    fail: bool = false,
    sample_calls: u8 = 0,

    fn sample(self: *FakeClock) error{ClockUnavailable}!worker_runtime.ClockSample {
        self.sample_calls += 1;
        if (self.fail) return error.ClockUnavailable;
        return .{ .monotonic_ns = 7, .epoch_second = 1_784_030_400 };
    }
};

const TestLoop = Loop(FakeWorker, FakeBackend, FakeClock);

test "pending flush is retried before waiting" {
    var worker = FakeWorker{ .status = .{ .flush_pending = true }, .retry_step = .flush_retry };
    var backend = FakeBackend{ .next = .failed };
    var clock = FakeClock{};
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectEqual(Outcome.flush_retry, try loop.step());
    try std.testing.expectEqual(@as(u8, 1), worker.retry_calls);
    try std.testing.expectEqual(@as(u8, 0), backend.wait_calls);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_calls);
}

test "completion transfers to worker exactly once" {
    const completion = try testCompletion(.send, 7);
    var worker = FakeWorker{};
    var backend = FakeBackend{ .next = .{ .completion = completion } };
    var clock = FakeClock{};
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectEqual(Outcome.progressed, try loop.step());
    worker.status.phase = .stopped;
    try std.testing.expectEqual(Outcome.stopped, try loop.step());
    try std.testing.expectEqual(@as(u8, 1), backend.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), clock.sample_calls);
    try std.testing.expectEqual(@as(u8, 1), worker.handle_calls);
    try std.testing.expectEqual(@as(u8, 2), worker.loop_status_calls);
    try std.testing.expectEqual(@as(u8, 0), worker.cleanup_status_calls);
    try std.testing.expectEqualDeep(completion, worker.handled_completion.?);
}

test "accepted completion transfers to fatal cleanup on clock failure" {
    const completion = try testCompletion(.accept, 61);
    var worker = FakeWorker{};
    var backend = FakeBackend{ .next = .{ .completion = completion } };
    var clock = FakeClock{ .fail = true };
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectError(error.ClockUnavailable, loop.step());
    try std.testing.expectEqual(@as(u8, 1), backend.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), clock.sample_calls);
    try std.testing.expectEqual(@as(u8, 0), worker.handle_calls);
    try std.testing.expectEqual(@as(u8, 1), worker.clock_failures);
    try std.testing.expectEqualDeep(completion, worker.failed_clock_completion.?);
}

test "retryable waits return interrupted without sampling clock" {
    var worker = FakeWorker{};
    var backend = FakeBackend{ .next = .interrupted };
    var clock = FakeClock{};
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectEqual(Outcome.interrupted, try loop.step());
    backend.next = .retry;
    try std.testing.expectEqual(Outcome.interrupted, try loop.step());
    try std.testing.expectEqual(@as(u8, 2), backend.wait_calls);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_calls);
    try std.testing.expectEqual(@as(u8, 0), worker.handle_calls);
}

test "backend failure closes worker before preserving backend error" {
    var worker = FakeWorker{};
    var backend = FakeBackend{ .next = .failed };
    var clock = FakeClock{};
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectError(error.WaitFailed, loop.step());
    try std.testing.expectEqual(@as(u8, 1), worker.backend_failures);
    try std.testing.expectEqual(@as(u8, 0), clock.sample_calls);
    try std.testing.expectEqual(@as(u8, 0), worker.handle_calls);
}

test "worker handle error remains typed after ownership transfer" {
    const completion = try testCompletion(.send, 8);
    var worker = FakeWorker{ .fail_handle = true };
    var backend = FakeBackend{ .next = .{ .completion = completion } };
    var clock = FakeClock{};
    var loop = TestLoop.init(&worker, &backend, &clock);

    try std.testing.expectError(error.HandleFailed, loop.step());
    try std.testing.expectEqual(@as(u8, 1), backend.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), clock.sample_calls);
    try std.testing.expectEqual(@as(u8, 1), worker.handle_calls);
}

fn testCompletion(kind: reactor.OperationKind, value: u64) !reactor.Completion {
    const token = try reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 1,
        .sequence = 1,
    });
    const result: reactor.Success = switch (kind) {
        .accept => .{ .accept = reactor.Accepted.loopback(.{ .value = value }) },
        .send => .{ .send = @intCast(value) },
        else => unreachable,
    };
    return .{
        .token = token,
        .result = .{ .success = result },
        .more = false,
    };
}

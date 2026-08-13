const std = @import("std");
const builtin = @import("builtin");

const access_log = @import("../../access_log.zig");
const futex_epoch = @import("futex_epoch.zig");

pub const State = enum(u8) {
    idle,
    running,
    stopping,
    stopped,
    failed,
};

pub const StartError = access_log.SinkContractError || error{
    AccessLogSigpipeMaskFailed,
    InvalidState,
    InvalidStackSize,
    ThreadSpawnFailed,
};

pub const thread_stack_bytes_min: usize = 64 * 1024;
pub const thread_stack_bytes_max: usize = 8 * 1024 * 1024;
pub const standard_thread_stack_bytes: usize = 256 * 1024;

var test_fail_next_sigpipe_mask = std.atomic.Value(bool).init(false);

pub const TestAccess = if (builtin.is_test) struct {
    pub fn failNextSigpipeMask() void {
        test_fail_next_sigpipe_mask.store(true, .release);
    }
} else struct {};

pub const Snapshot = struct {
    state: State,
    events_written: u64,
    events_dropped_by_sink: u64,
    sink_failures: u64,
    queued_events: u32,
    in_flight_events: u32,
    producer_drops: u64,
};

pub fn Logger(
    comptime worker_count: u16,
    comptime ring_capacity: u16,
    comptime drain_batch_per_ring: u16,
) type {
    if (worker_count == 0) @compileError("PLOOF-E6110 access logger worker count is zero");
    if (drain_batch_per_ring == 0) {
        @compileError("PLOOF-E6111 access logger drain batch is zero");
    }
    const EventRing = access_log.Ring(ring_capacity);

    return struct {
        const Self = @This();
        pub const Binding = struct {
            ring: *EventRing,
            wake: *futex_epoch.Event,
        };

        rings: *[worker_count]EventRing,
        sink: access_log.FileDescriptorSink,
        startup: futex_epoch.Event = .{},
        wake: futex_epoch.Event = .{},
        terminal: futex_epoch.Event = .{},
        state_value: std.atomic.Value(State) = .init(.idle),
        sigpipe_masked: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        events_written: std.atomic.Value(u64) = .init(0),
        events_dropped_by_sink: std.atomic.Value(u64) = .init(0),
        sink_failures: std.atomic.Value(u64) = .init(0),
        in_flight_events: std.atomic.Value(u32) = .init(0),
        sink_live: bool = true,

        pub fn init(rings: *[worker_count]EventRing, descriptor: std.os.linux.fd_t) Self {
            return .{
                .rings = rings,
                .sink = .{ .descriptor = descriptor },
            };
        }

        /// Start only after the logger has reached its final address.
        pub fn start(logger: *Self) StartError!void {
            return logger.startWithStack(standard_thread_stack_bytes);
        }

        pub fn startWithStack(logger: *Self, stack_bytes: usize) StartError!void {
            if (stack_bytes < thread_stack_bytes_min or
                stack_bytes > thread_stack_bytes_max)
            {
                return error.InvalidStackSize;
            }
            try logger.sink.validate();
            if (logger.state_value.cmpxchgStrong(
                .idle,
                .running,
                .acq_rel,
                .acquire,
            ) != null) return error.InvalidState;
            logger.thread = std.Thread.spawn(
                .{ .stack_size = spawnStackBytes(stack_bytes) },
                run,
                .{logger},
            ) catch {
                logger.state_value.store(.failed, .release);
                logger.terminal.notify();
                return error.ThreadSpawnFailed;
            };
            if (!logger.awaitSigpipeMask()) {
                logger.thread.?.join();
                logger.thread = null;
                return error.AccessLogSigpipeMaskFailed;
            }
        }

        pub fn binding(logger: *Self, worker_index: u16) Binding {
            std.debug.assert(worker_index < worker_count);
            return .{ .ring = &logger.rings[worker_index], .wake = &logger.wake };
        }

        pub fn terminalEvent(logger: *Self) *futex_epoch.Event {
            return &logger.terminal;
        }

        /// Producers call after a successful push. Wake syscall occurs only
        /// when the logger has armed its single futex waiter.
        pub fn notify(logger: *Self) void {
            logger.wake.notify();
        }

        pub fn requestStop(logger: *Self) void {
            const previous = logger.state_value.cmpxchgStrong(
                .running,
                .stopping,
                .acq_rel,
                .acquire,
            );
            if (previous == null or previous.? == .stopping) logger.wake.notify();
        }

        pub fn state(logger: *const Self) State {
            return logger.state_value.load(.acquire);
        }

        /// Join only after observing `stopped` or `failed`; this never owns a deadline.
        pub fn join(logger: *Self) StartError!void {
            const current = logger.state();
            if (current != .stopped and current != .failed) return error.InvalidState;
            if (logger.thread) |thread| {
                thread.join();
                logger.thread = null;
            }
        }

        pub fn snapshot(logger: *const Self) Snapshot {
            var queued: u32 = 0;
            var producer_drops: u64 = 0;
            for (logger.rings) |*ring| {
                queued += ring.count();
                producer_drops +|= ring.dropped();
            }
            return .{
                .state = logger.state(),
                .events_written = logger.events_written.load(.acquire),
                .events_dropped_by_sink = logger.events_dropped_by_sink.load(.acquire),
                .sink_failures = logger.sink_failures.load(.acquire),
                .queued_events = queued,
                .in_flight_events = logger.in_flight_events.load(.acquire),
                .producer_drops = producer_drops,
            };
        }

        fn run(logger: *Self) void {
            defer logger.terminal.notify();
            if (!blockSigpipe()) {
                logger.state_value.store(.failed, .release);
                logger.startup.notify();
                return;
            }
            logger.sigpipe_masked.store(true, .release);
            logger.startup.notify();
            while (true) {
                const drained = logger.drainPass();
                const current = logger.state();
                if (current == .stopping and logger.queuedCount() == 0) {
                    logger.state_value.store(.stopped, .release);
                    return;
                }
                if (current != .running and current != .stopping) {
                    logger.state_value.store(.failed, .release);
                    return;
                }
                if (drained != 0) continue;
                const observed = logger.wake.observe();
                if (logger.queuedCount() != 0 or logger.state() == .stopping) continue;
                if (!logger.wake.arm(observed)) continue;
                logger.wake.wait(observed);
            }
        }

        fn awaitSigpipeMask(logger: *Self) bool {
            while (true) {
                const observed = logger.startup.observe();
                if (logger.sigpipe_masked.load(.acquire)) return true;
                if (logger.state() == .failed) return false;
                if (!logger.startup.arm(observed)) continue;
                logger.startup.wait(observed);
            }
        }

        fn drainPass(logger: *Self) u32 {
            var drained: u32 = 0;
            for (logger.rings) |*ring| {
                var batch: u16 = 0;
                while (batch < drain_batch_per_ring) : (batch += 1) {
                    const event = ring.popOwned(&logger.in_flight_events) orelse break;
                    drained += 1;
                    logger.consumeOwned(event);
                }
            }
            return drained;
        }

        fn consumeOwned(logger: *Self, event: access_log.AccessEvent) void {
            defer logger.in_flight_events.store(0, .release);
            logger.consume(event);
        }

        fn consume(logger: *Self, event: access_log.AccessEvent) void {
            if (!logger.sink_live) {
                saturatingIncrement(&logger.events_dropped_by_sink);
                return;
            }
            if (logger.sink.write(event)) |failure| {
                if (!failure.recordBoundaryPreserved()) logger.sink_live = false;
                saturatingIncrement(&logger.sink_failures);
                saturatingIncrement(&logger.events_dropped_by_sink);
                return;
            }
            saturatingIncrement(&logger.events_written);
        }

        fn queuedCount(logger: *const Self) u32 {
            var total: u32 = 0;
            for (logger.rings) |*ring| total += ring.count();
            return total;
        }
    };
}

fn saturatingIncrement(value: *std.atomic.Value(u64)) void {
    var current = value.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| {
            current = actual;
            continue;
        }
        return;
    }
}

fn spawnStackBytes(configured: usize) usize {
    // Zig's exact compiler-rt TSan stores tool TLS inside each pthread stack.
    // Smaller valid production stacks make intercepted pthread_create return EINVAL.
    return if (builtin.sanitize_thread) thread_stack_bytes_max else configured;
}

fn blockSigpipe() bool {
    if (comptime builtin.is_test) {
        if (test_fail_next_sigpipe_mask.swap(false, .acq_rel)) return false;
    }
    var mask = std.os.linux.sigemptyset();
    std.os.linux.sigaddset(&mask, .PIPE);
    return std.os.linux.errno(std.os.linux.sigprocmask(
        std.os.linux.SIG.BLOCK,
        &mask,
        null,
    )) == .SUCCESS;
}

test "logger drains every worker ring and stops only after queues are empty" {
    const linux = std.os.linux;
    const EventRing = access_log.Ring(4);
    const TestLogger = Logger(2, 4, 2);
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    var rings = [2]EventRing{ .{}, .{} };
    var logger = TestLogger.init(&rings, descriptors[1]);
    try logger.start();

    try std.testing.expect(rings[0].push(sampleEvent(1)));
    logger.notify();
    try std.testing.expect(rings[1].push(sampleEvent(2)));
    logger.notify();
    try std.testing.expect(rings[0].push(sampleEvent(3)));
    logger.notify();
    logger.requestStop();
    try waitForTerminal(&logger);
    try logger.join();

    const snapshot = logger.snapshot();
    try std.testing.expectEqual(State.stopped, snapshot.state);
    try std.testing.expectEqual(@as(u64, 3), snapshot.events_written);
    try std.testing.expectEqual(@as(u32, 0), snapshot.queued_events);
    try std.testing.expectEqual(@as(u32, 0), snapshot.in_flight_events);
    var output: [3 * access_log.max_record_bytes]u8 = undefined;
    const result = linux.read(descriptors[0], &output, output.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    var lines = std.mem.splitScalar(u8, output[0..result], '\n');
    var line_count: u8 = 0;
    while (lines.next()) |line| line_count += @intFromBool(line.len != 0);
    try std.testing.expectEqual(@as(u8, 3), line_count);
}

test "closed pipe reader becomes EPIPE without terminating the process" {
    const linux = std.os.linux;
    const EventRing = access_log.Ring(4);
    const TestLogger = Logger(1, 4, 4);
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[1]);
    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, descriptors[1]);
    try logger.start();
    _ = linux.close(descriptors[0]);
    try std.testing.expect(rings[0].push(sampleEvent(1)));
    try std.testing.expect(rings[0].push(sampleEvent(2)));
    logger.notify();
    logger.requestStop();
    try waitForTerminal(&logger);
    try logger.join();
    const snapshot = logger.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.sink_failures);
    try std.testing.expectEqual(@as(u64, 2), snapshot.events_dropped_by_sink);
    try std.testing.expectEqual(@as(u64, 0), snapshot.events_written);
}

test "SIGPIPE mask startup failure joins the logger thread" {
    const linux = std.os.linux;
    const EventRing = access_log.Ring(1);
    const TestLogger = Logger(1, 1, 1);
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, descriptors[1]);
    TestAccess.failNextSigpipeMask();

    try std.testing.expectError(error.AccessLogSigpipeMaskFailed, logger.start());
    try std.testing.expectEqual(State.failed, logger.state());
    try std.testing.expect(logger.thread == null);
    try std.testing.expect(!logger.sigpipe_masked.load(.acquire));
}

test "logger rejects a blocking sink before spawning its thread" {
    const linux = std.os.linux;
    const EventRing = access_log.Ring(1);
    const TestLogger = Logger(1, 1, 1);
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{})),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, descriptors[1]);
    try std.testing.expectError(error.AccessLogSinkMustBeNonBlocking, logger.start());
    try std.testing.expectEqual(State.idle, logger.state());
}

test "logger snapshot counts an event owned by the sink write" {
    const EventRing = access_log.Ring(1);
    const TestLogger = Logger(1, 1, 1);
    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, -1);
    try std.testing.expect(rings[0].push(sampleEvent(1)));
    _ = rings[0].popOwned(&logger.in_flight_events).?;

    const snapshot = logger.snapshot();
    try std.testing.expectEqual(@as(u32, 0), snapshot.queued_events);
    try std.testing.expectEqual(@as(u32, 1), snapshot.in_flight_events);
    logger.in_flight_events.store(0, .release);
}

test "full nonblocking sink drops one record then recovers" {
    const linux = std.os.linux;
    const EventRing = access_log.Ring(2);
    const TestLogger = Logger(1, 2, 2);
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{ .NONBLOCK = true })),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    try fillPipe(descriptors[1]);

    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, descriptors[1]);
    try logger.start();
    try std.testing.expect(rings[0].push(sampleEvent(1)));
    logger.notify();
    try waitForSinkDrops(&logger, 1);
    try drainPipe(descriptors[0]);
    try std.testing.expect(rings[0].push(sampleEvent(2)));
    logger.notify();
    logger.requestStop();
    try waitForTerminal(&logger);
    try logger.join();

    const snapshot = logger.snapshot();
    try std.testing.expectEqual(State.stopped, snapshot.state);
    try std.testing.expectEqual(@as(u64, 1), snapshot.events_written);
    try std.testing.expectEqual(@as(u64, 1), snapshot.sink_failures);
    try std.testing.expectEqual(@as(u64, 1), snapshot.events_dropped_by_sink);
    try std.testing.expectEqual(@as(u32, 0), snapshot.queued_events);
    try std.testing.expectEqual(@as(u32, 0), snapshot.in_flight_events);
}

test "logger rejects stacks outside fixed production bounds" {
    const EventRing = access_log.Ring(1);
    const TestLogger = Logger(1, 1, 1);
    var rings = [1]EventRing{.{}};
    var logger = TestLogger.init(&rings, -1);
    try std.testing.expectError(
        error.InvalidStackSize,
        logger.startWithStack(thread_stack_bytes_min - 1),
    );
    try std.testing.expectEqual(State.idle, logger.state());
    try std.testing.expectError(
        error.InvalidStackSize,
        logger.startWithStack(thread_stack_bytes_max + 1),
    );
}

test "logger keeps production stack contract under sanitizer instrumentation" {
    try std.testing.expectEqual(@as(usize, 256 * 1024), standard_thread_stack_bytes);
    const expected = if (builtin.sanitize_thread)
        thread_stack_bytes_max
    else
        standard_thread_stack_bytes;
    try std.testing.expectEqual(expected, spawnStackBytes(standard_thread_stack_bytes));
}

fn sampleEvent(duration_ns: u64) access_log.AccessEvent {
    return access_log.AccessEvent.init(
        .get,
        0,
        .{ .status = .ok, .mapped_error = false, .transport = .completed },
        duration_ns,
        .{},
    );
}

fn waitForTerminal(logger: anytype) !void {
    for (0..1_000_000) |_| {
        const current = logger.state();
        if (current == .stopped or current == .failed) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitForSinkDrops(logger: anytype, expected: u64) !void {
    for (0..1_000_000) |_| {
        if (logger.snapshot().events_dropped_by_sink == expected) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn fillPipe(descriptor: std.os.linux.fd_t) !void {
    const linux = std.os.linux;
    const bytes = [_]u8{0xaa} ** 4096;
    while (true) {
        const result = linux.write(descriptor, &bytes, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => if (result == 0) return error.TestUnexpectedResult,
            .AGAIN => return,
            else => return error.TestUnexpectedResult,
        }
    }
}

fn drainPipe(descriptor: std.os.linux.fd_t) !void {
    const linux = std.os.linux;
    var bytes: [4096]u8 = undefined;
    while (true) {
        const result = linux.read(descriptor, &bytes, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => if (result == 0) return error.TestUnexpectedResult,
            .AGAIN => return,
            else => return error.TestUnexpectedResult,
        }
    }
}

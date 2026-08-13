const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const futex_epoch = @import("../futex_epoch.zig");
const claim_test_barrier = @import("metrics_claim_hook.zig");
const open_metrics = @import("../../../open_metrics.zig");

pub const thread_stack_bytes_min: usize = 64 * 1024;
pub const thread_stack_bytes_max: usize = 8 * 1024 * 1024;
pub const standard_thread_stack_bytes: usize = 256 * 1024;
pub const unavailable_body = open_metrics.unavailable_body;

pub const StartError = std.Thread.SpawnError || error{
    AlreadyStarted,
    ThreadStackTooSmall,
    ThreadStackTooLarge,
    ThreadStackUnaligned,
};

pub const Ticket = struct { generation: u64 };

pub const WakeIdentity = struct {
    service_generation: u64 = 0,
    worker_index: u16 = 0,
    request_index: u16 = 0,
    request_generation: u16 = 0,
    stream_generation: u64 = 0,
};
pub const WakeNotify = *const fn (*anyopaque, Ticket, WakeIdentity) void;

pub const Wake = struct {
    /// Must point to stable server-owned storage. A notification may run after
    /// its ticket was released and the service slot was claimed again.
    context: *anyopaque,
    identity: WakeIdentity = .{},
    notify: WakeNotify,

    pub fn signal(wake: Wake, ticket: Ticket) void {
        wake.notify(wake.context, ticket, wake.identity);
    }
};

pub const Claim = union(enum) {
    accepted: Ticket,
    busy,
    stopping,
};

pub const Poll = union(enum) {
    pending,
    success: []const u8,
    unavailable,
    stale,
};

pub const Cancel = enum(u8) { pending, cancelled, stale };

const Phase = enum(u8) {
    idle,
    claiming,
    queued,
    generating,
    cancel_requested,
    ready,
};

const Outcome = enum(u8) { success, unavailable };
const phase_bits = 3;
const phase_mask = (1 << phase_bits) - 1;
const generation_max = std.math.maxInt(u64) >> phase_bits;

pub fn Service(comptime App: type) type {
    const Formatter = open_metrics.Formatter(App);
    const Snapshot = Formatter.MetricsSnapshot;
    const SnapshotFn = *const fn (*anyopaque, u64, *Snapshot) anyerror!void;
    const NowFn = *const fn (*anyopaque) anyerror!u64;

    return struct {
        const Self = @This();

        pub const bytes_max = Formatter.bytes_max;
        pub const MetricsSnapshot = Snapshot;

        state: std.atomic.Value(u64) = .init(stateValue(0, .idle)),
        stop_requested: std.atomic.Value(bool) = .init(false),
        terminal: std.atomic.Value(bool) = .init(false),
        event: futex_epoch.Event = .{},
        thread: ?std.Thread = null,
        address_identity: usize = 0,
        deadline_ns: u64 = 0,
        snapshot_context: *anyopaque = undefined,
        snapshot_fn: SnapshotFn = undefined,
        clock_context: *anyopaque = undefined,
        now_fn: NowFn = undefined,
        wake: Wake = undefined,
        snapshot: Snapshot = .{},
        output: [Formatter.bytes_max]u8 = undefined,
        used: usize = 0,
        outcome: Outcome = .unavailable,

        pub fn start(
            self: *Self,
            snapshot_context: *anyopaque,
            snapshot_fn: SnapshotFn,
            stack_bytes: usize,
        ) StartError!void {
            return self.startWithClock(
                snapshot_context,
                snapshot_fn,
                self,
                monotonicNow,
                stack_bytes,
            );
        }

        pub fn startWithClock(
            self: *Self,
            snapshot_context: *anyopaque,
            snapshot_fn: SnapshotFn,
            clock_context: *anyopaque,
            now_fn: NowFn,
            stack_bytes: usize,
        ) StartError!void {
            if (stack_bytes < thread_stack_bytes_min) return error.ThreadStackTooSmall;
            if (stack_bytes > thread_stack_bytes_max) return error.ThreadStackTooLarge;
            if (stack_bytes % 4096 != 0) return error.ThreadStackUnaligned;
            try self.configure(snapshot_context, snapshot_fn, clock_context, now_fn);
            self.thread = std.Thread.spawn(
                .{ .stack_size = spawnStackBytes(stack_bytes) },
                run,
                .{self},
            ) catch |problem| {
                self.address_identity = 0;
                return problem;
            };
        }

        /// Deterministic production-state-machine driver for fuzzing. It skips
        /// only thread creation and waiting; claims and transitions are shared.
        pub fn __fuzzStartWithClock(
            self: *Self,
            snapshot_context: *anyopaque,
            snapshot_fn: SnapshotFn,
            clock_context: *anyopaque,
            now_fn: NowFn,
        ) StartError!void {
            try self.configure(snapshot_context, snapshot_fn, clock_context, now_fn);
        }

        pub fn __fuzzStep(self: *Self) bool {
            self.assertStable();
            if (self.terminal.load(.acquire)) return true;
            _ = self.process();
            if (self.stop_requested.load(.acquire) and
                statePhase(self.state.load(.acquire)) == .idle)
            {
                self.terminal.store(true, .release);
                self.event.notify();
            }
            return self.terminal.load(.acquire);
        }

        pub fn claim(self: *Self, deadline_ns: u64, wake: Wake) Claim {
            self.assertStable();
            if (self.stop_requested.load(.acquire)) return .stopping;
            const observed = self.state.load(.acquire);
            if (statePhase(observed) != .idle) return .busy;
            if (self.state.cmpxchgStrong(
                observed,
                stateValue(stateGeneration(observed), .claiming),
                .acq_rel,
                .acquire,
            ) != null) return .busy;
            claim_test_barrier.pause();
            if (self.stop_requested.load(.acquire)) {
                self.resetIdle(stateGeneration(observed));
                return .stopping;
            }
            const generation = nextGeneration(stateGeneration(observed));
            self.deadline_ns = deadline_ns;
            const ticket = Ticket{ .generation = generation };
            var owned_wake = wake;
            owned_wake.identity.service_generation = ticket.generation;
            self.wake = owned_wake;
            self.state.store(stateValue(generation, .queued), .release);
            self.event.notify();
            return .{ .accepted = ticket };
        }

        pub fn poll(self: *const Self, ticket: Ticket) Poll {
            self.assertStable();
            const observed = self.state.load(.acquire);
            if (ticket.generation != stateGeneration(observed)) return .stale;
            return switch (statePhase(observed)) {
                .ready => switch (self.outcome) {
                    .success => .{ .success = self.output[0..self.used] },
                    .unavailable => .unavailable,
                },
                .queued, .generating, .cancel_requested => .pending,
                .idle, .claiming => .stale,
            };
        }

        pub fn cancel(self: *Self, ticket: Ticket) Cancel {
            self.assertStable();
            while (true) {
                const observed = self.state.load(.acquire);
                if (ticket.generation != stateGeneration(observed)) return .stale;
                switch (statePhase(observed)) {
                    .queued, .generating => {
                        if (self.state.cmpxchgWeak(
                            observed,
                            stateValue(ticket.generation, .cancel_requested),
                            .acq_rel,
                            .acquire,
                        ) != null) continue;
                        self.event.notify();
                        return .pending;
                    },
                    .cancel_requested => return .pending,
                    .ready => if (self.releaseReady(ticket)) return .cancelled else continue,
                    .idle, .claiming => return .stale,
                }
            }
        }

        pub fn release(self: *Self, ticket: Ticket) bool {
            self.assertStable();
            return self.releaseReady(ticket);
        }

        pub fn requestStop(self: *Self) void {
            self.assertStable();
            self.stop_requested.store(true, .release);
            self.event.notify();
        }

        pub fn isTerminal(self: *const Self) bool {
            self.assertStable();
            return self.terminal.load(.acquire);
        }

        pub fn terminalEvent(self: *Self) *futex_epoch.Event {
            self.assertStable();
            return &self.event;
        }

        pub fn join(self: *Self) void {
            self.assertStable();
            const thread = self.thread orelse return;
            thread.join();
            self.thread = null;
        }

        fn run(self: *Self) void {
            defer {
                self.terminal.store(true, .release);
                self.event.notify();
            }
            while (true) {
                if (self.process()) continue;
                if (self.stop_requested.load(.acquire) and
                    statePhase(self.state.load(.acquire)) == .idle) return;
                const observed = self.event.observe();
                if (self.process()) continue;
                if (self.stop_requested.load(.acquire) and
                    statePhase(self.state.load(.acquire)) == .idle) return;
                if (self.event.arm(observed)) self.event.wait(observed);
            }
        }

        fn configure(
            self: *Self,
            snapshot_context: *anyopaque,
            snapshot_fn: SnapshotFn,
            clock_context: *anyopaque,
            now_fn: NowFn,
        ) StartError!void {
            if (self.address_identity != 0) return error.AlreadyStarted;
            self.address_identity = @intFromPtr(self);
            self.snapshot_context = snapshot_context;
            self.snapshot_fn = snapshot_fn;
            self.clock_context = clock_context;
            self.now_fn = now_fn;
        }

        fn process(self: *Self) bool {
            const observed = self.state.load(.acquire);
            const current = statePhase(observed);
            const generation = stateGeneration(observed);
            if (current == .cancel_requested) {
                const wake = self.wake;
                self.resetIdle(generation);
                wake.signal(.{ .generation = generation });
                return true;
            }
            if (current != .queued) return false;
            if (self.state.cmpxchgStrong(
                observed,
                stateValue(generation, .generating),
                .acq_rel,
                .acquire,
            ) != null) return true;
            const ticket = Ticket{ .generation = generation };
            const wake = self.wake;
            self.generate();
            if (self.state.cmpxchgStrong(
                stateValue(generation, .generating),
                stateValue(generation, .ready),
                .release,
                .acquire,
            ) == null) {
                wake.signal(ticket);
            } else {
                self.resetIdle(generation);
                wake.signal(ticket);
            }
            return true;
        }

        fn generate(self: *Self) void {
            self.used = 0;
            if (self.deadlineExpired()) {
                self.outcome = .unavailable;
                return;
            }
            self.snapshot_fn(
                self.snapshot_context,
                self.deadline_ns,
                &self.snapshot,
            ) catch {
                self.outcome = .unavailable;
                return;
            };
            if (self.deadlineExpired()) {
                self.outcome = .unavailable;
                return;
            }
            const rendered = Formatter.format(&self.snapshot, &self.output) catch {
                self.outcome = .unavailable;
                return;
            };
            self.used = rendered.len;
            if (self.deadlineExpired()) {
                self.outcome = .unavailable;
                return;
            }
            self.outcome = .success;
        }

        fn deadlineExpired(self: *Self) bool {
            const now = self.now_fn(self.clock_context) catch return true;
            return now >= self.deadline_ns;
        }

        fn releaseReady(self: *Self, ticket: Ticket) bool {
            if (ticket.generation == 0 or ticket.generation > generation_max) return false;
            if (self.state.cmpxchgStrong(
                stateValue(ticket.generation, .ready),
                stateValue(ticket.generation, .claiming),
                .acq_rel,
                .acquire,
            ) != null) return false;
            self.resetIdle(ticket.generation);
            return true;
        }

        fn resetIdle(self: *Self, generation: u64) void {
            @memset(self.output[0..self.used], 0);
            self.used = 0;
            self.outcome = .unavailable;
            self.state.store(stateValue(generation, .idle), .release);
            self.event.notify();
        }

        fn assertStable(self: *const Self) void {
            if (self.address_identity == 0 or self.address_identity != @intFromPtr(self)) {
                @panic("PLOOF metrics service moved after start");
            }
        }
    };
}

fn stateValue(generation: u64, phase: Phase) u64 {
    std.debug.assert(generation <= generation_max);
    return (generation << phase_bits) | @intFromEnum(phase);
}

fn stateGeneration(value: u64) u64 {
    return value >> phase_bits;
}

fn statePhase(value: u64) Phase {
    return @enumFromInt(value & phase_mask);
}

fn nextGeneration(current: u64) u64 {
    return if (current == generation_max) 1 else current + 1;
}

fn monotonicNow(_: *anyopaque) !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0 or value.nsec >= std.time.ns_per_s) {
        return error.ClockOutOfRange;
    }
    const seconds = std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s) catch {
        return error.ClockOutOfRange;
    };
    return std.math.add(u64, seconds, @intCast(value.nsec)) catch {
        return error.ClockOutOfRange;
    };
}

fn spawnStackBytes(configured: usize) usize {
    // Zig's exact compiler-rt TSan stores tool TLS inside each pthread stack.
    // Smaller valid production stacks make intercepted pthread_create return EINVAL.
    return if (builtin.sanitize_thread) thread_stack_bytes_max else configured;
}

test "metrics service keeps production stack contract under sanitizer instrumentation" {
    try std.testing.expectEqual(@as(usize, 256 * 1024), standard_thread_stack_bytes);
    const expected = if (builtin.sanitize_thread)
        thread_stack_bytes_max
    else
        standard_thread_stack_bytes;
    try std.testing.expectEqual(expected, spawnStackBytes(standard_thread_stack_bytes));
}

test "metrics service defers publication, rejects overlap, and releases one slot" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    try fixture.start();
    defer fixture.stop();

    const ticket = switch (fixture.service.claim(std.math.maxInt(u64), fixture.wake())) {
        .accepted => |ticket| ticket,
        .busy, .stopping => return error.UnexpectedClaimFailure,
    };
    try std.testing.expectEqual(Poll.pending, fixture.service.poll(ticket));
    try std.testing.expectEqual(
        Claim.busy,
        fixture.service.claim(std.math.maxInt(u64), fixture.wake()),
    );
    fixture.allowSnapshot();
    try fixture.awaitWake();
    const rendered = switch (fixture.service.poll(ticket)) {
        .success => |bytes| bytes,
        else => return error.UnexpectedPollResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, rendered, "# EOF\n"));
    try std.testing.expect(fixture.service.release(ticket));
    try std.testing.expectEqual(Poll.stale, fixture.service.poll(ticket));
}

test "generating cancellation wakes its owner and permits a later claim" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    try fixture.start();
    defer fixture.stop();
    const first = switch (fixture.service.claim(std.math.maxInt(u64), fixture.wake())) {
        .accepted => |ticket| ticket,
        else => return error.UnexpectedClaimFailure,
    };
    try fixture.awaitSnapshotCalls(1);
    try std.testing.expectEqual(Cancel.pending, fixture.service.cancel(first));
    try std.testing.expectEqual(
        Claim.busy,
        fixture.service.claim(std.math.maxInt(u64), fixture.wake()),
    );
    fixture.allowSnapshot();
    try awaitIdle(&fixture.service);
    try fixture.awaitWakeCount(1);
    try std.testing.expectEqual(first.generation, fixture.last_wake.load(.acquire));
    try std.testing.expectEqual(first.generation, fixture.last_identity.load(.acquire));
    try std.testing.expectEqual(@as(u64, 91), fixture.last_stream_wake.load(.acquire));
    const second = switch (fixture.service.claim(std.math.maxInt(u64), fixture.wake())) {
        .accepted => |ticket| ticket,
        else => return error.UnexpectedClaimFailure,
    };
    try std.testing.expect(second.generation != first.generation);
    try fixture.awaitTicket(second);
    try std.testing.expect(fixture.service.release(second));
}

test "queued cancellation acknowledges without running snapshot work" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    try fixture.startInline();
    const ticket = switch (fixture.service.claim(100, fixture.wake())) {
        .accepted => |accepted| accepted,
        else => return error.UnexpectedClaimFailure,
    };
    try std.testing.expectEqual(Cancel.pending, fixture.service.cancel(ticket));
    try std.testing.expect(!fixture.service.__fuzzStep());
    try std.testing.expectEqual(Poll.stale, fixture.service.poll(ticket));
    try std.testing.expectEqual(@as(u32, 0), fixture.snapshot_calls.load(.acquire));
    try std.testing.expectEqual(ticket.generation, fixture.last_wake.load(.acquire));
    try std.testing.expectEqual(ticket.generation, fixture.last_identity.load(.acquire));
    fixture.service.requestStop();
    try std.testing.expect(fixture.service.__fuzzStep());
}

test "deadline covers snapshot and formatting without publishing partial output" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    fixture.expire_clock_call = 3;
    fixture.expired_now = 100;
    @memset(&fixture.service.output, 0xa5);
    try fixture.start();
    defer fixture.stop();
    fixture.allowSnapshot();
    const ticket = switch (fixture.service.claim(100, fixture.wake())) {
        .accepted => |accepted| accepted,
        else => return error.UnexpectedClaimFailure,
    };
    try fixture.awaitWake();
    try std.testing.expectEqual(Poll.unavailable, fixture.service.poll(ticket));
    try std.testing.expectEqual(@as(u32, 1), fixture.snapshot_calls.load(.acquire));
    const rendered_bytes = fixture.service.used;
    try std.testing.expect(rendered_bytes != 0);
    try std.testing.expect(fixture.service.release(ticket));
    for (fixture.service.output[0..rendered_bytes]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    if (rendered_bytes < fixture.service.output.len) {
        try std.testing.expectEqual(@as(u8, 0xa5), fixture.service.output[rendered_bytes]);
    }
}

test "late wake after release and reclaim cannot act on the new owner" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    fixture.block_wake.store(true, .release);
    try fixture.start();
    defer fixture.stop();
    fixture.allowSnapshot();
    const first = switch (fixture.service.claim(std.math.maxInt(u64), fixture.wake())) {
        .accepted => |accepted| accepted,
        else => return error.UnexpectedClaimFailure,
    };
    try fixture.awaitWakeEntered();
    try std.testing.expect(fixture.service.release(first));
    const second = switch (fixture.service.claim(std.math.maxInt(u64), fixture.wake())) {
        .accepted => |accepted| accepted,
        else => return error.UnexpectedClaimFailure,
    };
    try std.testing.expectEqual(Poll.stale, fixture.service.poll(first));
    try std.testing.expectEqual(Cancel.stale, fixture.service.cancel(first));
    try std.testing.expect(!fixture.service.release(first));
    try std.testing.expectEqual(Poll.pending, fixture.service.poll(second));
    fixture.unblockWake();
    try fixture.awaitWakeCount(2);
    try std.testing.expectEqual(second.generation, fixture.last_wake.load(.acquire));
    try std.testing.expectEqual(second.generation, fixture.last_identity.load(.acquire));
    try std.testing.expect(fixture.service.release(second));
}

test "packed state rejects stale operations through repeated slot reuse" {
    const Fixture = TestFixture();
    var fixture = Fixture{};
    try fixture.start();
    defer fixture.stop();
    fixture.allowSnapshot();
    var stale = Ticket{ .generation = generation_max };
    for (0..128) |_| {
        const current = switch (fixture.service.claim(
            std.math.maxInt(u64),
            fixture.wake(),
        )) {
            .accepted => |accepted| accepted,
            else => return error.UnexpectedClaimFailure,
        };
        try fixture.awaitTicket(current);
        try std.testing.expectEqual(Poll.stale, fixture.service.poll(stale));
        try std.testing.expectEqual(Cancel.stale, fixture.service.cancel(stale));
        try std.testing.expect(!fixture.service.release(stale));
        try std.testing.expect(fixture.service.release(current));
        stale = current;
    }
}

fn TestFixture() type {
    const application = @import("../../../application.zig");
    const response = @import("../../../response.zig");
    const route = @import("../../../route.zig");
    const Context = application.Context(void, response.standard_head_limits);
    const Handler = struct {
        fn get(context: *Context) Context.ResponseType {
            return context.empty(.no_content);
        }
    };
    const App = application.Application(.{
        .State = void,
        .routes = .{route.get("/fixture", Handler.get)},
    });
    const TestService = Service(App);
    return struct {
        const Self = @This();
        service: TestService = .{},
        snapshot_gate: futex_epoch.Event = .{},
        snapshot_allowed: std.atomic.Value(bool) = .init(false),
        wake_event: futex_epoch.Event = .{},
        snapshot_calls: std.atomic.Value(u32) = .init(0),
        clock_calls: std.atomic.Value(u32) = .init(0),
        expire_clock_call: u32 = 0,
        expired_now: u64 = 0,
        block_wake: std.atomic.Value(bool) = .init(false),
        wake_entered: std.atomic.Value(bool) = .init(false),
        wake_release: futex_epoch.Event = .{},
        wake_count: std.atomic.Value(u32) = .init(0),
        last_wake: std.atomic.Value(u64) = .init(0),
        last_identity: std.atomic.Value(u64) = .init(0),
        last_stream_wake: std.atomic.Value(u64) = .init(0),

        fn start(self: *Self) !void {
            try self.service.startWithClock(
                self,
                snapshot,
                self,
                now,
                standard_thread_stack_bytes,
            );
        }

        fn startInline(self: *Self) !void {
            try self.service.__fuzzStartWithClock(self, snapshot, self, now);
        }

        fn stop(self: *Self) void {
            self.unblockWake();
            _ = self.service.cancel(.{
                .generation = stateGeneration(self.service.state.load(.acquire)),
            });
            self.allowSnapshot();
            self.service.requestStop();
            self.service.join();
        }

        fn allowSnapshot(self: *Self) void {
            self.snapshot_allowed.store(true, .release);
            self.snapshot_gate.notify();
        }

        fn wake(self: *Self) Wake {
            return .{
                .context = self,
                .identity = .{ .stream_generation = 91 },
                .notify = notified,
            };
        }

        fn awaitWake(self: *Self) !void {
            for (0..1_000_000) |_| {
                if (statePhase(self.service.state.load(.acquire)) == .ready) return;
                std.Thread.yield() catch {};
            }
            return error.WakeTimeout;
        }

        fn awaitTicket(self: *Self, ticket: Ticket) !void {
            for (0..1_000_000) |_| {
                switch (self.service.poll(ticket)) {
                    .success, .unavailable => return,
                    .pending => std.Thread.yield() catch {},
                    .stale => return error.StaleCurrentTicket,
                }
            }
            return error.WakeTimeout;
        }

        fn awaitWakeEntered(self: *Self) !void {
            for (0..1_000_000) |_| {
                if (self.wake_entered.load(.acquire)) return;
                std.Thread.yield() catch {};
            }
            return error.WakeTimeout;
        }

        fn awaitSnapshotCalls(self: *Self, count: u32) !void {
            for (0..1_000_000) |_| {
                if (self.snapshot_calls.load(.acquire) >= count) return;
                std.Thread.yield() catch {};
            }
            return error.SnapshotTimeout;
        }

        fn awaitWakeCount(self: *Self, count: u32) !void {
            for (0..1_000_000) |_| {
                if (self.wake_count.load(.acquire) >= count) return;
                std.Thread.yield() catch {};
            }
            return error.WakeTimeout;
        }

        fn unblockWake(self: *Self) void {
            self.block_wake.store(false, .release);
            self.wake_release.notify();
        }

        fn snapshot(context: *anyopaque, _: u64, output: *TestService.MetricsSnapshot) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = self.snapshot_calls.fetchAdd(1, .acq_rel);
            while (!self.snapshot_allowed.load(.acquire)) {
                const observed = self.snapshot_gate.observe();
                if (self.snapshot_allowed.load(.acquire)) break;
                if (self.snapshot_gate.arm(observed)) self.snapshot_gate.wait(observed);
            }
            output.* = .{ .epoch = 1 };
        }

        fn now(context: *anyopaque) !u64 {
            const self: *Self = @ptrCast(@alignCast(context));
            const call = self.clock_calls.fetchAdd(1, .acq_rel) + 1;
            if (self.expire_clock_call != 0 and call >= self.expire_clock_call) {
                return self.expired_now;
            }
            return 1;
        }

        fn notified(context: *anyopaque, ticket: Ticket, identity: WakeIdentity) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.last_wake.store(ticket.generation, .release);
            self.last_identity.store(identity.service_generation, .release);
            self.last_stream_wake.store(identity.stream_generation, .release);
            _ = self.wake_count.fetchAdd(1, .acq_rel);
            self.wake_entered.store(true, .release);
            while (self.block_wake.load(.acquire)) {
                const observed = self.wake_release.observe();
                if (!self.block_wake.load(.acquire)) break;
                if (self.wake_release.arm(observed)) self.wake_release.wait(observed);
            }
            self.wake_event.notify();
        }
    };
}

fn awaitIdle(service: anytype) !void {
    for (0..1_000_000) |_| {
        if (statePhase(service.state.load(.acquire)) == .idle) return;
        std.Thread.yield() catch {};
    }
    return error.IdleTimeout;
}

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const event_counter = @import("../event_counter.zig");
const futex_epoch = @import("../futex_epoch.zig");
const gzip_decoder = @import("decoder.zig");
const gzip_output_mailbox = @import("output_mailbox.zig");
const pool_lifecycle = @import("decoder_pool_lifecycle.zig");
const gzip_input_queue = @import("input_queue.zig");
const types = @import("decoder_pool_types.zig");

pub const Owner = types.Owner;
pub const Limits = types.Limits;
pub const Counts = types.Counts;
pub const Result = types.Result;
pub const Lease = types.Lease;
pub const OutputRejection = types.OutputRejection;
pub const Signals = types.Signals;

pub const StartError = std.Thread.SpawnError || error{
    AlreadyStarted,
    EventCounterOpenFailed,
};

pub const AccessError = error{
    NotRunning,
    StaleLease,
    JobTerminal,
};

pub const FeedError = AccessError || gzip_input_queue.WriteError;
pub const FinishError = AccessError || gzip_input_queue.FinishError;
pub const AckError = AccessError || error{
    JobNotTerminal,
    SignalsPending,
};
pub const OutputAckError = AccessError || gzip_output_mailbox.AcknowledgeError;
pub const CloseError = error{
    JobsPending,
    NotQuiesced,
    WakePollLive,
};

const space_signal: u8 = 1 << 0;
const output_signal: u8 = 1 << 1;
const terminal_signal: u8 = 1 << 2;
var test_pause_wake = std.atomic.Value(bool).init(false);
var test_wake_paused = std.atomic.Value(bool).init(false);
var test_pause_decode = std.atomic.Value(bool).init(false);
var test_decode_paused = std.atomic.Value(bool).init(false);
var test_pause_wait_state = std.atomic.Value(bool).init(false);
var test_wait_state_paused = std.atomic.Value(bool).init(false);

/// Fixed, allocation-free controller over stable caller-owned decoder slots.
/// Pool and slots stay fixed from `init` through `finishStop`. Public control,
/// wake-consume, and ack methods have exactly one owning worker thread; free
/// lists, lifecycle, and terminal-consumed state are deliberately non-atomic.
pub fn FixedPool(
    comptime slot_count: usize,
    comptime queue_capacity: usize,
    comptime receive_buffer_bytes: usize,
    comptime members_max: usize,
) type {
    comptime {
        if (slot_count == 0) @compileError("gzip decoder pool needs at least one slot");
        if (slot_count > 64) {
            @compileError("gzip decoder pool slot count exceeds hard maximum 64");
        }
    }
    const InputQueue = gzip_input_queue.Queue(queue_capacity, receive_buffer_bytes);
    const Decoder = gzip_decoder.Decoder(members_max);
    const OutputMailbox = gzip_output_mailbox.Mailbox(receive_buffer_bytes);

    return struct {
        const Self = @This();
        pub const slots_len: usize = slot_count;
        pub const input_queue_bytes: usize = queue_capacity;
        pub const receive_bytes: usize = receive_buffer_bytes;
        pub const output_mailbox_capacity_bytes: usize = receive_buffer_bytes;
        pub const output_mailbox_bytes: usize = @sizeOf(OutputMailbox);
        pub const member_limit: usize = members_max;
        pub const Status = enum(u8) {
            stopped,
            idle,
            ready,
            running,
            canceling,
            publishing,
            terminal,
        };

        pub const Lifecycle = enum(u8) { initialized, running, quiesced, stopped };
        pub const WakeBatch = struct {
            counter_count: u64,
            slots: [slot_count]Signals,
        };
        pub const ConsumeWakeResult = union(enum) {
            consumed: WakeBatch,
            failed: event_counter.Failure,
        };
        pub const TestAccess = if (builtin.is_test) struct {
            pub fn startPrefix(pool: *Self, stack_size: usize, count: usize) !void {
                pool.counter = switch (event_counter.Counter.open()) {
                    .opened => |opened| opened,
                    .failed => return error.EventCounterOpenFailed,
                };
                pool.counter_open = true;
                pool.counter_failure = null;
                try pool_lifecycle.spawnPrefix(pool, stack_size, count, Slot.threadMain);
            }

            pub fn rollback(pool: *Self) void {
                pool_lifecycle.rollbackStarted(pool);
            }

            pub fn publishSpace(pool: *Self, index: u16) void {
                pool.slots[index].publishSignal(space_signal);
            }

            pub fn publishTerminal(pool: *Self, index: u16) void {
                pool.slots[index].publishSignal(terminal_signal);
            }

            pub fn pauseWake(enabled: bool) void {
                test_pause_wake.store(enabled, .release);
            }

            pub fn wakePaused() bool {
                return test_wake_paused.load(.acquire);
            }

            pub fn pauseDecode(enabled: bool) void {
                test_pause_decode.store(enabled, .release);
            }

            pub fn decodePaused() bool {
                return test_decode_paused.load(.acquire);
            }

            pub fn notifyThread(pool: *Self, index: u16) void {
                pool.slots[index].wakeThread();
            }

            pub fn armThreadWait(pool: *Self, index: u16) u32 {
                const event = &pool.slots[index].event;
                const observed = event.observe();
                if (!event.arm(observed)) @panic("gzip pool test waiter arm failed");
                return observed;
            }

            pub fn threadWaiting(pool: *const Self, index: u16) bool {
                return pool.slots[index].event.waiting();
            }

            pub fn threadEpoch(pool: *const Self, index: u16) u32 {
                return pool.slots[index].event.epoch();
            }

            pub fn pauseWaitState(enabled: bool) void {
                test_pause_wait_state.store(enabled, .release);
            }

            pub fn waitStatePaused() bool {
                return test_wait_state_paused.load(.acquire);
            }

            pub fn threadShuttingDown(pool: *const Self, index: u16) bool {
                return pool.slots[index].shutdown.load(.acquire);
            }

            pub fn outputProducerWaiting(pool: *const Self, index: u16) bool {
                return OutputMailbox.TestAccess.producerWaiting(&pool.slots[index].mailbox);
            }

            pub fn outputStorage(pool: *const Self, index: u16) []const u8 {
                return OutputMailbox.TestAccess.storage(&pool.slots[index].mailbox);
            }
        } else struct {};
        const Output = union(enum) {
            buffered: []u8,
            streaming,
        };
        const Job = struct {
            owner: Owner = .{ .connection_index = 0, .request_index = 0, .generation = 0 },
            output: Output = .{ .buffered = &.{} },
            limits: Limits = .{ .encoded_max = 0, .decoded_max = 0 },
        };

        pub const Slot = struct {
            queue: InputQueue,
            mailbox: OutputMailbox,
            thread: ?std.Thread,
            thread_id: std.atomic.Value(std.Thread.Id),
            counter: *event_counter.Counter,
            state: std.atomic.Value(Status) align(64),
            shutdown: std.atomic.Value(bool),
            event: futex_epoch.Event,
            signals: std.atomic.Value(u8) align(64),
            generation: u64,
            occupied: bool,
            terminal_consumed: bool,
            job: Job,
            output_rejection: ?OutputRejection,
            result_value: Result,

            fn init(slot: *Slot, counter: *event_counter.Counter) void {
                slot.* = .{
                    .queue = undefined,
                    .mailbox = undefined,
                    .thread = null,
                    .thread_id = .init(0),
                    .counter = counter,
                    .state = .init(.idle),
                    .shutdown = .init(false),
                    .event = .{},
                    .signals = .init(0),
                    .generation = 0,
                    .occupied = false,
                    .terminal_consumed = false,
                    .job = .{},
                    .output_rejection = null,
                    .result_value = .canceled,
                };
                slot.queue.init(.{ .context = slot, .wake = notifySpace });
                slot.mailbox.init(.{ .context = slot, .wake = notifyOutput });
            }

            fn notifySpace(context: ?*anyopaque) void {
                const slot: *Slot = @ptrCast(@alignCast(context.?));
                slot.publishSignal(space_signal);
            }

            fn notifyOutput(context: ?*anyopaque) void {
                const slot: *Slot = @ptrCast(@alignCast(context.?));
                slot.publishSignal(output_signal);
            }

            fn publishSignal(slot: *Slot, bit: u8) void {
                const previous = slot.signals.fetchOr(bit, .release);
                if (previous == 0) {
                    if (slot.counter.signal()) |failure| {
                        std.debug.panic(
                            "gzip decoder pool eventfd signal failed: {t}",
                            .{failure.errno},
                        );
                    }
                }
            }

            fn wakeThread(slot: *Slot) void {
                slot.event.notify();
            }

            fn threadMain(slot: *Slot) void {
                slot.thread_id.store(std.Thread.getCurrentId(), .release);
                defer slot.thread_id.store(0, .release);
                while (slot.waitForJob()) {
                    if (comptime builtin.is_test) pauseDecodeForTest();
                    const candidate = slot.decodeJob();
                    const result_value = slot.claimResult(candidate);
                    if (result_value != .complete) slot.clearBufferedOutput();
                    slot.result_value = result_value;
                    slot.state.store(.terminal, .release);
                    slot.publishSignal(terminal_signal);
                }
                if (slot.state.load(.acquire) != .terminal) {
                    slot.state.store(.stopped, .release);
                }
            }

            fn waitForJob(slot: *Slot) bool {
                while (true) {
                    const shutting_down = slot.shutdown.load(.acquire);
                    if (comptime builtin.is_test) pauseWaitStateForTest();
                    const state = slot.state.load(.acquire);
                    switch (state) {
                        .ready => {
                            if (slot.state.cmpxchgStrong(
                                .ready,
                                .running,
                                .acq_rel,
                                .acquire,
                            ) == null) return true;
                        },
                        .canceling => return true,
                        else => {},
                    }
                    if (shutting_down) return false;
                    slot.waitForEpoch();
                }
            }

            fn waitForEpoch(slot: *Slot) void {
                const expected = slot.event.observe();
                if (slot.shutdown.load(.acquire) or
                    slot.state.load(.acquire) == .ready or
                    slot.state.load(.acquire) == .canceling or
                    !slot.event.arm(expected))
                {
                    return;
                }
                slot.event.wait(expected);
            }

            fn decodeJob(slot: *Slot) Result {
                if (slot.state.load(.acquire) == .canceling) return .canceled;
                return switch (slot.job.output) {
                    .buffered => |output_bytes| slot.decodeBuffered(output_bytes),
                    .streaming => slot.decodeStreaming(),
                };
            }

            fn decodeBuffered(slot: *Slot, output_bytes: []u8) Result {
                const decoded = Decoder.decodeReader(
                    slot.queue.reader(),
                    output_bytes,
                    slot.job.limits.encoded_max,
                    slot.job.limits.decoded_max,
                ) catch return .read_failed;
                return switch (decoded) {
                    .complete => |complete| .{ .complete = .{
                        .encoded = complete.encoded_consumed,
                        .decoded = complete.decoded_count,
                        .members = complete.member_count,
                    } },
                    .malformed => .malformed,
                    .over_limit => |limit| .{ .over_limit = limit },
                };
            }

            fn decodeStreaming(slot: *Slot) Result {
                const decoded = Decoder.decodeReaderToWriter(
                    slot.queue.reader(),
                    slot.mailbox.writer(),
                    slot.job.limits.encoded_max,
                    slot.job.limits.decoded_max,
                ) catch |err| return switch (err) {
                    error.ReadFailed => .read_failed,
                    error.WriteFailed => if (slot.mailbox.isCanceled()) .canceled else .read_failed,
                };
                return switch (decoded) {
                    .complete => |complete| .{ .complete = .{
                        .encoded = complete.encoded_consumed,
                        .decoded = complete.decoded_count,
                        .members = complete.member_count,
                    } },
                    .malformed => .malformed,
                    .over_limit => |limit| .{ .over_limit = limit },
                };
            }

            fn clearBufferedOutput(slot: *Slot) void {
                switch (slot.job.output) {
                    .buffered => |output_bytes| std.crypto.secureZero(u8, output_bytes),
                    .streaming => {},
                }
            }

            fn claimResult(slot: *Slot, candidate: Result) Result {
                while (true) {
                    switch (slot.state.load(.acquire)) {
                        .canceling => {
                            slot.state.store(.publishing, .release);
                            return .canceled;
                        },
                        .running => {
                            if (slot.state.cmpxchgStrong(
                                .running,
                                .publishing,
                                .acq_rel,
                                .acquire,
                            ) == null) return candidate;
                        },
                        else => @panic("gzip decoder pool result state invariant"),
                    }
                }
            }
        };

        slots: *[slot_count]Slot,
        free_indices: [slot_count]u16,
        free_count: u16,
        counter: event_counter.Counter,
        counter_open: bool,
        started_count: u16,
        lifecycle: Lifecycle,
        wake_descriptor_exposed: bool,
        wake_poll_retired: bool,
        counter_failure: ?event_counter.Failure,

        pub fn init(self: *Self, slots: *[slot_count]Slot) void {
            self.* = .{
                .slots = slots,
                .free_indices = undefined,
                .free_count = @intCast(slot_count),
                .counter = undefined,
                .counter_open = false,
                .started_count = 0,
                .lifecycle = .initialized,
                .wake_descriptor_exposed = false,
                .wake_poll_retired = false,
                .counter_failure = null,
            };
            for (slots, 0..) |*slot, index| {
                slot.init(&self.counter);
                self.free_indices[index] = @intCast(slot_count - 1 - index);
            }
        }

        pub fn start(self: *Self, stack_size: usize) StartError!void {
            if (self.lifecycle != .initialized) return error.AlreadyStarted;
            self.counter = switch (event_counter.Counter.open()) {
                .opened => |opened| opened,
                .failed => |failure| {
                    self.counter_failure = failure;
                    return error.EventCounterOpenFailed;
                },
            };
            self.counter_open = true;
            self.counter_failure = null;
            pool_lifecycle.spawnPrefix(self, stack_size, slot_count, Slot.threadMain) catch |err| {
                pool_lifecycle.rollbackStarted(self);
                return err;
            };
            self.lifecycle = .running;
        }

        /// Cancels and joins every decoder, preserving occupied terminal jobs
        /// while leaving eventfd open for quiesced settlement and poll retirement.
        pub fn beginStop(self: *Self) ?event_counter.Failure {
            return pool_lifecycle.beginStop(self);
        }

        /// Marks the external wake poll reaped after `beginStop` joins producers.
        pub fn retireWakePoll(self: *Self) CloseError!void {
            return pool_lifecycle.retireWakePoll(self);
        }

        /// Closes eventfd only when no exposed external poll can still reference it.
        pub fn finishStop(self: *Self) CloseError!?event_counter.Failure {
            return pool_lifecycle.finishStop(self);
        }

        /// Output stays stable and exclusive through `ack` or joined `beginStop`.
        pub fn acquire(
            self: *Self,
            owner_value: Owner,
            output_bytes: []u8,
            limits: Limits,
        ) ?Lease {
            return self.acquireJob(owner_value, .{ .buffered = output_bytes }, limits);
        }

        pub fn acquireStreaming(
            self: *Self,
            owner_value: Owner,
            limits: Limits,
        ) ?Lease {
            return self.acquireJob(owner_value, .streaming, limits);
        }

        fn acquireJob(
            self: *Self,
            owner_value: Owner,
            job_output: Output,
            limits: Limits,
        ) ?Lease {
            if (self.lifecycle != .running or self.free_count == 0) return null;
            self.free_count -= 1;
            const index = self.free_indices[self.free_count];
            const slot = &self.slots[index];
            if (slot.state.load(.acquire) != .idle or slot.occupied) {
                @panic("gzip decoder pool free slot invariant");
            }
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.job = .{ .owner = owner_value, .output = job_output, .limits = limits };
            slot.output_rejection = null;
            slot.occupied = true;
            slot.terminal_consumed = false;
            slot.state.store(.ready, .release);
            slot.wakeThread();
            return .{ .index = index, .generation = slot.generation };
        }

        pub fn feed(
            self: *Self,
            lease: Lease,
            bytes: []const u8,
        ) FeedError!gzip_input_queue.WriteResult {
            const slot = try self.activeSlot(lease);
            try requireWritable(slot.state.load(.acquire));
            return slot.queue.tryWrite(bytes);
        }

        pub fn finish(self: *Self, lease: Lease) FinishError!void {
            const slot = try self.activeSlot(lease);
            try requireWritable(slot.state.load(.acquire));
            return slot.queue.finish();
        }

        /// Idempotent through terminal. Cancellation never releases the lease;
        /// caller still consumes the terminal signal and acknowledges it.
        pub fn cancel(self: *Self, lease: Lease) AccessError!void {
            const slot = try self.activeSlot(lease);
            while (true) {
                const state = slot.state.load(.acquire);
                switch (state) {
                    .ready, .running => {
                        if (slot.state.cmpxchgStrong(
                            state,
                            .canceling,
                            .acq_rel,
                            .acquire,
                        ) != null) continue;
                        slot.queue.cancel();
                        slot.mailbox.cancel();
                        slot.wakeThread();
                        return;
                    },
                    .canceling => {
                        slot.queue.cancel();
                        slot.mailbox.cancel();
                        slot.wakeThread();
                        return;
                    },
                    .publishing, .terminal => return,
                    else => return error.JobTerminal,
                }
            }
        }

        pub fn shouldWaitForSpace(self: *Self, lease: Lease) AccessError!bool {
            const slot = try self.activeSlot(lease);
            try requireWritable(slot.state.load(.acquire));
            return slot.queue.shouldWaitForSpace();
        }

        /// Complete result and output bytes are visible after terminal acquire.
        pub fn result(self: *const Self, lease: Lease) AccessError!?Result {
            const slot = try self.leasedSlotConst(lease);
            if (slot.state.load(.acquire) != .terminal) return null;
            return slot.result_value;
        }

        pub fn owner(self: *const Self, lease: Lease) AccessError!Owner {
            return (try self.leasedSlotConst(lease)).job.owner;
        }

        /// Streaming chunk stays borrowed and stable through `acknowledgeOutput`.
        pub fn output(self: *const Self, lease: Lease) AccessError!?[]const u8 {
            const slot = try self.leasedSlotConst(lease);
            if (slot.job.output != .streaming) return null;
            return switch (slot.mailbox.poll()) {
                .chunk => |chunk| chunk,
                .empty, .canceled => null,
            };
        }

        pub fn acknowledgeOutput(self: *Self, lease: Lease) OutputAckError!void {
            const slot = try self.leasedSlot(lease);
            if (slot.job.output != .streaming) return error.NotReady;
            return slot.mailbox.acknowledge();
        }

        pub fn rejectOutput(
            self: *Self,
            lease: Lease,
            reason: OutputRejection,
        ) AccessError!void {
            const slot = try self.activeSlot(lease);
            slot.output_rejection = slot.output_rejection orelse reason;
            return self.cancel(lease);
        }

        pub fn outputRejection(
            self: *const Self,
            lease: Lease,
        ) AccessError!?OutputRejection {
            return (try self.leasedSlotConst(lease)).output_rejection;
        }

        /// Releases a terminal job only after `consumeWake` observed its bit.
        /// Quiesced release clears metadata and stops the slot without reuse.
        pub fn ack(self: *Self, lease: Lease) AckError!void {
            const slot = try self.leasedSlot(lease);
            if (slot.state.load(.acquire) != .terminal) return error.JobNotTerminal;
            if (!slot.terminal_consumed) return error.SignalsPending;
            slot.queue.reset();
            slot.mailbox.reset();
            slot.job = .{};
            slot.output_rejection = null;
            slot.occupied = false;
            slot.terminal_consumed = false;
            if (self.lifecycle == .running) {
                slot.state.store(.idle, .release);
                self.free_indices[self.free_count] = lease.index;
                self.free_count += 1;
            } else {
                slot.state.store(.stopped, .release);
            }
        }

        /// Drains eventfd before consuming all coalesced per-slot signals.
        pub fn consumeWake(self: *Self) ConsumeWakeResult {
            if (!self.counter_open) return .{ .failed = .{
                .stage = .drain,
                .errno = .BADF,
            } };
            const count = switch (self.counter.drain()) {
                .count => |value| value,
                .empty => 0,
                .failed => |failure| return .{ .failed = failure },
            };
            pauseWakeConsumptionForTest();
            var batch = WakeBatch{
                .counter_count = count,
                .slots = [_]Signals{.{}} ** slot_count,
            };
            for (self.slots, 0..) |*slot, index| {
                batch.slots[index] = @bitCast(slot.signals.swap(0, .acquire));
                if (batch.slots[index].terminal) slot.terminal_consumed = true;
            }
            return .{ .consumed = batch };
        }

        pub fn wakeDescriptor(self: *Self) linux.fd_t {
            if (!self.counter_open) @panic("gzip decoder pool counter is closed");
            self.wake_descriptor_exposed = true;
            return self.counter.descriptor;
        }

        pub fn available(self: *const Self) u16 {
            return if (self.lifecycle == .running) self.free_count else 0;
        }

        pub fn activeJobs(self: *const Self) u16 {
            if (self.lifecycle == .running) {
                return @intCast(slot_count - @as(usize, self.free_count));
            }
            if (self.lifecycle != .quiesced) return 0;
            var count: u16 = 0;
            for (self.slots) |*slot| count += @intFromBool(slot.occupied);
            return count;
        }

        pub fn lifecycleStatus(self: *const Self) Lifecycle {
            return self.lifecycle;
        }

        pub fn workerThreadId(self: *const Self, index: usize) ?std.Thread.Id {
            if (self.lifecycle != .running or index >= @as(usize, self.started_count)) return null;
            const thread_id = self.slots[index].thread_id.load(.acquire);
            return if (thread_id == 0) null else thread_id;
        }

        /// Producer-thread lookup for an O(1) signal-index to job mapping.
        pub fn leaseAt(self: *const Self, index: u16) ?Lease {
            if (!self.canSettle() or index >= slot_count) return null;
            const slot = &self.slots[index];
            if (!slot.occupied) return null;
            return .{ .index = index, .generation = slot.generation };
        }

        pub fn startFailure(self: *const Self) ?event_counter.Failure {
            return self.counter_failure;
        }

        fn activeSlot(self: *Self, lease: Lease) AccessError!*Slot {
            if (self.lifecycle != .running) return error.NotRunning;
            if (lease.index >= slot_count) return error.StaleLease;
            const slot = &self.slots[lease.index];
            if (!slot.occupied or slot.generation != lease.generation) {
                return error.StaleLease;
            }
            return slot;
        }

        fn activeSlotConst(self: *const Self, lease: Lease) AccessError!*const Slot {
            if (self.lifecycle != .running) return error.NotRunning;
            return self.leasedSlotConst(lease);
        }

        fn leasedSlot(self: *Self, lease: Lease) AccessError!*Slot {
            return @constCast(try self.leasedSlotConst(lease));
        }

        fn leasedSlotConst(self: *const Self, lease: Lease) AccessError!*const Slot {
            if (!self.canSettle()) return error.NotRunning;
            if (lease.index >= slot_count) return error.StaleLease;
            const slot = &self.slots[lease.index];
            if (!slot.occupied or slot.generation != lease.generation) {
                return error.StaleLease;
            }
            return slot;
        }

        fn canSettle(self: *const Self) bool {
            return self.lifecycle == .running or self.lifecycle == .quiesced;
        }
    };
}

fn requireWritable(state: anytype) AccessError!void {
    switch (state) {
        .ready, .running => {},
        else => return error.JobTerminal,
    }
}

fn pauseWakeConsumptionForTest() void {
    if (!builtin.is_test or !test_pause_wake.load(.acquire)) return;
    test_wake_paused.store(true, .release);
    while (test_pause_wake.load(.acquire)) std.Thread.yield() catch {};
    test_wake_paused.store(false, .release);
}

fn pauseDecodeForTest() void {
    if (!builtin.is_test or !test_pause_decode.load(.acquire)) return;
    test_decode_paused.store(true, .release);
    while (test_pause_decode.load(.acquire)) std.Thread.yield() catch {};
    test_decode_paused.store(false, .release);
}

fn pauseWaitStateForTest() void {
    if (!builtin.is_test or !test_pause_wait_state.load(.acquire)) return;
    test_wait_state_paused.store(true, .release);
    while (test_pause_wait_state.load(.acquire)) std.Thread.yield() catch {};
    test_wait_state_paused.store(false, .release);
}

const std = @import("std");
const builtin = @import("builtin");

const event_counter = @import("../event_counter.zig");
const reactor = @import("../reactor.zig");
const worker_wake_controller = @import("wake_controller.zig");

const active_flag: u64 = 1 << 0;
const pending_flag: u64 = 1 << 1;
const ready_flag: u64 = 1 << 2;
const generation_shift = 3;
pub const generation_max: u64 = std.math.maxInt(u64) >> generation_shift;

pub const NotifyResult = enum(u8) { published, coalesced, stale };
pub const PendingResult = enum(u8) { pending, ready, stale };
pub const ClaimResult = enum(u8) { claimed, not_ready, stale };
pub const InvalidateResult = enum(u8) { invalidated, stale, foreign };
pub const ConsumePause = enum(u8) { none, after_words, after_clear };

var test_consume_pause = std.atomic.Value(ConsumePause).init(.none);
var test_consume_paused = std.atomic.Value(bool).init(false);

pub const StreamWake = struct {
    state: *std.atomic.Value(u64),
    inventory_word: *std.atomic.Value(u64),
    summary_word: *std.atomic.Value(u64),
    inventory_signaled: *std.atomic.Value(bool),
    stale_notifications: *std.atomic.Value(u64),
    counter: *const event_counter.Counter,
    generation_value: u64,
    inventory_mask: u64,
    slot_index: u16,

    pub fn notify(wake: StreamWake) NotifyResult {
        var observed = wake.state.load(.acquire);
        while (true) {
            if (!isCurrent(observed, wake.generation_value)) {
                countStale(wake.stale_notifications);
                return .stale;
            }
            if (observed & ready_flag != 0) return .coalesced;
            if (wake.state.cmpxchgWeak(
                observed,
                observed | ready_flag,
                .acq_rel,
                .acquire,
            )) |changed| {
                observed = changed;
                continue;
            }
            _ = wake.inventory_word.fetchOr(wake.inventory_mask, .release);
            const word_index: usize = @as(usize, wake.slot_index) / 64;
            const summary_mask = @as(u64, 1) << @intCast(word_index % 64);
            _ = wake.summary_word.fetchOr(summary_mask, .release);
            signalInventory(wake.inventory_signaled, wake.counter);
            return .published;
        }
    }

    /// Called after a producer returns pending. A prior or racing wake wins.
    pub fn markPending(wake: StreamWake) PendingResult {
        var observed = wake.state.load(.acquire);
        while (true) {
            if (!isCurrent(observed, wake.generation_value)) return .stale;
            if (observed & ready_flag != 0) return .ready;
            if (observed & pending_flag != 0) return .pending;
            if (wake.state.cmpxchgWeak(
                observed,
                observed | pending_flag,
                .acq_rel,
                .acquire,
            )) |changed| {
                observed = changed;
                continue;
            }
            return .pending;
        }
    }

    /// Clears one retained wake only when the runtime can poll the producer.
    pub fn claimReady(wake: StreamWake) ClaimResult {
        var observed = wake.state.load(.acquire);
        while (true) {
            if (!isCurrent(observed, wake.generation_value)) return .stale;
            if (observed & ready_flag == 0) return .not_ready;
            const next = observed & ~(ready_flag | pending_flag);
            if (wake.state.cmpxchgWeak(
                observed,
                next,
                .acq_rel,
                .acquire,
            )) |changed| {
                observed = changed;
                continue;
            }
            return .claimed;
        }
    }

    pub fn generation(wake: StreamWake) u64 {
        return wake.generation_value;
    }

    pub fn index(wake: StreamWake) u16 {
        return wake.slot_index;
    }
};

pub const Phase = enum(u8) {
    initialized,
    running,
    stopping,
    fatal,
    stopped,
    failed,
};

pub const Error = error{
    InvalidWorkerIndex,
    InvalidPhase,
    InvalidSlot,
    SlotActive,
    GenerationExhausted,
    PublishersActive,
    PublishersNotJoined,
    EventCounterOpenFailed,
    EventCounterCloseFailed,
    WakeControlFailed,
    WakeDrainFailed,
    InvalidCompletion,
};

/// Fixed worker-local stream wake inventory. Its address stays stable from
/// `init` until every copied StreamWake is joined and the counter is closed.
pub fn Fixed(comptime slot_count: usize) type {
    comptime {
        if (slot_count == 0) @compileError("stream wake needs at least one slot");
        if (slot_count > 8192) @compileError("stream wake slot count exceeds 8192");
    }
    const word_count = std.math.divCeil(usize, slot_count, 64) catch unreachable;
    const summary_word_count = std.math.divCeil(usize, word_count, 64) catch unreachable;

    return struct {
        const Self = @This();

        pub const slots_len = slot_count;
        pub const ReadyBatch = struct {
            counter_count: u64,
            words: [word_count]u64,
            nonempty_words: [summary_word_count]u64,

            pub fn contains(batch: *const ReadyBatch, index_value: u16) bool {
                if (index_value >= slot_count) return false;
                const index: usize = index_value;
                const word_index = index / 64;
                const summary_index = word_index / 64;
                const summary_mask = @as(u64, 1) << @intCast(word_index % 64);
                if (batch.nonempty_words[summary_index] & summary_mask == 0) return false;
                return batch.words[word_index] & (@as(u64, 1) << @intCast(index % 64)) != 0;
            }

            pub fn count(batch: *const ReadyBatch) u16 {
                var total: u16 = 0;
                for (batch.nonempty_words, 0..) |summary_word, summary_index| {
                    var bits = summary_word;
                    while (bits != 0) {
                        const bit_index: u6 = @intCast(@ctz(bits));
                        const word_index = summary_index * 64 + bit_index;
                        total += @intCast(@popCount(batch.words[word_index]));
                        bits &= bits - 1;
                    }
                }
                return total;
            }
        };

        pub const HandleEvent = struct {
            /// Stable worker-owned batch, valid until the next `handle` call.
            ready: *const ReadyBatch,
            stopped: bool,
        };

        pub const TestAccess = if (builtin.is_test) struct {
            pub fn setGeneration(self: *Self, index: u16, generation: u64) void {
                std.debug.assert(index < slot_count and generation <= generation_max);
                std.debug.assert(self.states[index].load(.acquire) & active_flag == 0);
                self.states[index].store(generation << generation_shift, .release);
            }

            pub fn pauseConsume(point: ConsumePause) void {
                test_consume_pause.store(point, .release);
            }

            pub fn consumePaused() bool {
                return test_consume_paused.load(.acquire);
            }

            pub fn setStaleCount(self: *Self, count: u64) void {
                self.stale_notifications.store(count, .release);
            }
        } else struct {};

        states: [slot_count]std.atomic.Value(u64),
        inventory: [word_count]std.atomic.Value(u64),
        inventory_summary: [summary_word_count]std.atomic.Value(u64),
        ready_batch: ReadyBatch,
        inventory_signaled: std.atomic.Value(bool),
        stale_notifications: std.atomic.Value(u64),
        counter: event_counter.Counter,
        controller: worker_wake_controller.Controller,
        active_count: u16,
        counter_open: bool,
        cleanup_failed: bool,
        publishers_joined: bool,
        state: Phase,

        pub fn init(self: *Self, worker_index: u16) Error!void {
            self.* = .{
                .states = undefined,
                .inventory = undefined,
                .inventory_summary = undefined,
                .ready_batch = undefined,
                .inventory_signaled = .init(false),
                .stale_notifications = .init(0),
                .counter = undefined,
                .controller = worker_wake_controller.Controller.initAt(
                    worker_index,
                    reactor.stream_wake_control_slot,
                ) catch |problem| return switch (problem) {
                    error.InvalidWorkerIndex => error.InvalidWorkerIndex,
                    else => unreachable,
                },
                .active_count = 0,
                .counter_open = false,
                .cleanup_failed = false,
                .publishers_joined = false,
                .state = .initialized,
            };
            for (&self.states) |*slot| slot.* = .init(0);
            for (&self.inventory) |*word| word.* = .init(0);
            for (&self.inventory_summary) |*word| word.* = .init(0);
            self.resetReadyBatch();
        }

        pub fn start(self: *Self, backend: anytype) Error!void {
            if (self.state != .initialized or self.counter_open or self.publishers_joined) {
                return error.InvalidPhase;
            }
            self.counter = switch (event_counter.Counter.open()) {
                .opened => |opened| opened,
                .failed => return error.EventCounterOpenFailed,
            };
            self.counter_open = true;
            self.controller.arm(self.source(), backend) catch {
                const failed = self.counter.close();
                self.counter_open = false;
                if (failed != null) {
                    self.cleanup_failed = true;
                    self.state = .failed;
                    return error.EventCounterCloseFailed;
                }
                return error.WakeControlFailed;
            };
            self.state = .running;
        }

        /// Slot reuse follows invalidate, producer abort, producer join, then
        /// activate. Generation checks cannot prove the caller-owned join.
        pub fn activate(self: *Self, index: u16) Error!StreamWake {
            if (self.state != .running or self.publishers_joined) return error.InvalidPhase;
            if (index >= slot_count) return error.InvalidSlot;
            const slot = &self.states[index];
            var observed = slot.load(.acquire);
            while (true) {
                if (observed & active_flag != 0) return error.SlotActive;
                const previous_generation = observed >> generation_shift;
                if (previous_generation == generation_max) return error.GenerationExhausted;
                const generation = previous_generation + 1;
                const next = generation << generation_shift | active_flag;
                if (slot.cmpxchgWeak(observed, next, .acq_rel, .acquire)) |changed| {
                    observed = changed;
                    continue;
                }
                self.active_count += 1;
                return self.makeWake(index, generation);
            }
        }

        /// Publishes from immutable identity without retaining request storage.
        pub fn notifyIdentity(self: *Self, index: u16, generation: u64) NotifyResult {
            if (index >= slot_count or generation == 0 or generation > generation_max) {
                countStale(&self.stale_notifications);
                return .stale;
            }
            return self.makeWake(index, generation).notify();
        }

        pub fn markPendingIdentity(
            self: *Self,
            index: u16,
            generation: u64,
        ) PendingResult {
            if (!self.validIdentity(index, generation)) return .stale;
            return self.makeWake(index, generation).markPending();
        }

        pub fn claimReadyIdentity(
            self: *Self,
            index: u16,
            generation: u64,
        ) ClaimResult {
            if (!self.validIdentity(index, generation)) return .stale;
            return self.makeWake(index, generation).claimReady();
        }

        pub fn invalidateIdentityBeforeAbort(
            self: *Self,
            index: u16,
            generation: u64,
        ) InvalidateResult {
            if (!self.validIdentity(index, generation)) return .stale;
            return self.invalidateBeforeAbort(self.makeWake(index, generation));
        }

        /// Must precede producer abort; copied handles become stale immediately.
        pub fn invalidateBeforeAbort(
            self: *Self,
            wake: StreamWake,
        ) InvalidateResult {
            if (!self.owns(wake)) return .foreign;
            var observed = wake.state.load(.acquire);
            while (true) {
                if (!isCurrent(observed, wake.generation_value)) return .stale;
                const next = wake.generation_value << generation_shift;
                if (wake.state.cmpxchgWeak(
                    observed,
                    next,
                    .acq_rel,
                    .acquire,
                )) |changed| {
                    observed = changed;
                    continue;
                }
                std.debug.assert(self.active_count != 0);
                self.active_count -= 1;
                return .invalidated;
            }
        }

        /// Caller invokes this only after invalidation, producer abort, and join.
        pub fn confirmPublishersJoined(self: *Self) Error!void {
            switch (self.state) {
                .initialized, .running, .stopping, .failed => {},
                .fatal, .stopped => return error.InvalidPhase,
            }
            if (self.active_count != 0) return error.PublishersActive;
            self.publishers_joined = true;
        }

        pub fn beginStop(self: *Self, backend: anytype) Error!void {
            if (!self.publishers_joined) return error.PublishersNotJoined;
            switch (self.state) {
                .initialized => {
                    _ = self.controller.stop(backend) catch return error.WakeControlFailed;
                    self.state = .stopped;
                },
                .running => {
                    const event = self.controller.stop(backend) catch {
                        return error.WakeControlFailed;
                    };
                    if (event.stopped) return self.finishNormalStop();
                    self.state = .stopping;
                },
                .stopping, .stopped => {},
                .fatal, .failed => return error.InvalidPhase,
            }
        }

        pub fn handle(
            self: *Self,
            backend: anytype,
            completion: reactor.Completion,
        ) Error!HandleEvent {
            if (self.state != .running and self.state != .stopping) {
                return error.InvalidPhase;
            }
            const event = self.controller.handle(completion) catch |problem| {
                self.state = .failed;
                return if (problem == error.InvalidCompletion)
                    error.InvalidCompletion
                else
                    error.WakeControlFailed;
            };
            self.resetReadyBatch();
            if (event.ready) self.consumeInventory() catch |problem| {
                self.state = .failed;
                return problem;
            };
            if (event.stopped) {
                try self.finishNormalStop();
            } else if (event.ready and self.state == .running) {
                self.controller.rearm(self.source(), backend) catch {
                    self.state = .failed;
                    return error.WakeControlFailed;
                };
            }
            return .{ .ready = &self.ready_batch, .stopped = event.stopped };
        }

        /// Leaves descriptor and kernel tokens intact for backend-wide abort.
        pub fn beginFatalAfterPublishersJoined(self: *Self) Error!void {
            if (!self.publishers_joined) return error.PublishersNotJoined;
            switch (self.state) {
                .initialized, .running, .stopping, .failed => self.state = .fatal,
                .fatal => {},
                .stopped => return error.InvalidPhase,
            }
        }

        /// Backend ownership proof and joined publishers make counter close safe.
        pub fn finishFatalAfterBackend(self: *Self) Error!void {
            if (self.state != .fatal) return error.InvalidPhase;
            self.controller.abortAfterBackend();
            if (self.counter_open) {
                const failure = self.counter.close();
                self.counter_open = false;
                if (failure != null) {
                    self.cleanup_failed = true;
                    self.state = .failed;
                    return error.EventCounterCloseFailed;
                }
            }
            if (self.cleanup_failed) {
                self.state = .failed;
                return error.EventCounterCloseFailed;
            }
            self.state = .stopped;
        }

        pub fn phase(self: *const Self) Phase {
            return self.state;
        }

        pub fn activeCount(self: *const Self) u16 {
            return self.active_count;
        }

        pub fn currentPollToken(self: *const Self) ?reactor.OperationToken {
            return self.controller.currentPollToken();
        }

        pub fn currentCancelToken(self: *const Self) ?reactor.OperationToken {
            return self.controller.currentCancelToken();
        }

        /// Saturates instead of making diagnostics ambiguous after u64 overflow.
        pub fn staleNotificationCount(self: *const Self) u64 {
            return self.stale_notifications.load(.acquire);
        }

        fn makeWake(self: *Self, index: u16, generation: u64) StreamWake {
            const word_index: usize = @as(usize, index) / 64;
            const summary_index = word_index / 64;
            return .{
                .state = &self.states[index],
                .inventory_word = &self.inventory[word_index],
                .summary_word = &self.inventory_summary[summary_index],
                .inventory_signaled = &self.inventory_signaled,
                .stale_notifications = &self.stale_notifications,
                .counter = &self.counter,
                .generation_value = generation,
                .inventory_mask = @as(u64, 1) << @intCast(@as(usize, index) % 64),
                .slot_index = index,
            };
        }

        fn validIdentity(_: *const Self, index: u16, generation: u64) bool {
            return index < slot_count and generation != 0 and generation <= generation_max;
        }

        fn owns(self: *Self, wake: StreamWake) bool {
            if (wake.slot_index >= slot_count) return false;
            const word_index: usize = @as(usize, wake.slot_index) / 64;
            const summary_index = word_index / 64;
            return wake.state == &self.states[wake.slot_index] and
                wake.inventory_word == &self.inventory[word_index] and
                wake.summary_word == &self.inventory_summary[summary_index] and
                wake.inventory_signaled == &self.inventory_signaled and
                wake.stale_notifications == &self.stale_notifications and
                wake.counter == &self.counter;
        }

        fn source(self: *const Self) reactor.WakeSource {
            std.debug.assert(self.counter_open and self.counter.descriptor >= 0);
            return .{ .value = @intCast(self.counter.descriptor) };
        }

        fn consumeInventory(self: *Self) Error!void {
            const count = switch (self.counter.drain()) {
                .count => |value| value,
                .empty, .failed => return error.WakeDrainFailed,
            };
            self.ready_batch.counter_count = count;
            for (&self.inventory_summary, 0..) |*summary, summary_index| {
                var bits = summary.swap(0, .acquire);
                self.ready_batch.nonempty_words[summary_index] = bits;
                while (bits != 0) {
                    const bit_index: u6 = @intCast(@ctz(bits));
                    const word_index = summary_index * 64 + bit_index;
                    if (word_index >= word_count) return error.WakeDrainFailed;
                    self.ready_batch.words[word_index] =
                        self.inventory[word_index].swap(0, .acquire);
                    bits &= bits - 1;
                }
            }
            pauseConsumeForTest(.after_words);
            _ = self.inventory_signaled.swap(false, .acq_rel);
            pauseConsumeForTest(.after_clear);
            if (self.inventoryPending()) {
                signalInventory(&self.inventory_signaled, &self.counter);
            }
        }

        fn inventoryPending(self: *const Self) bool {
            for (&self.inventory_summary) |*word| {
                if (word.load(.acquire) != 0) return true;
            }
            return false;
        }

        fn finishNormalStop(self: *Self) Error!void {
            std.debug.assert(self.publishers_joined);
            if (self.counter_open) {
                const failure = self.counter.close();
                self.counter_open = false;
                if (failure != null) {
                    self.cleanup_failed = true;
                    self.state = .failed;
                    return error.EventCounterCloseFailed;
                }
            }
            self.state = .stopped;
        }

        fn resetReadyBatch(self: *Self) void {
            self.ready_batch.counter_count = 0;
            self.ready_batch.nonempty_words = [_]u64{0} ** summary_word_count;
        }
    };
}

fn isCurrent(state: u64, generation: u64) bool {
    return state & active_flag != 0 and state >> generation_shift == generation;
}

fn countStale(counter: *std.atomic.Value(u64)) void {
    var observed = counter.load(.monotonic);
    while (observed != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(observed, observed + 1, .monotonic, .monotonic)) |changed| {
            observed = changed;
            continue;
        }
        return;
    }
}

fn pauseConsumeForTest(point: ConsumePause) void {
    if (!builtin.is_test or test_consume_pause.load(.acquire) != point) return;
    test_consume_paused.store(true, .release);
    while (test_consume_pause.load(.acquire) == point) std.Thread.yield() catch {};
    test_consume_paused.store(false, .release);
}

fn signalInventory(
    signaled: *std.atomic.Value(bool),
    counter: *const event_counter.Counter,
) void {
    if (signaled.swap(true, .acq_rel)) return;
    if (counter.signal()) |failure| {
        std.debug.panic("stream wake eventfd signal failed: {t}", .{failure.errno});
    }
}

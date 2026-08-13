const std = @import("std");

const gzip_decoder_pool = @import("../gzip/decoder_pool.zig");
const reactor = @import("../reactor.zig");
const worker_wake_controller = @import("wake_controller.zig");

pub const Lease = gzip_decoder_pool.Lease;
pub const Signals = gzip_decoder_pool.Signals;

pub const Phase = enum(u8) {
    disabled,
    initialized,
    running,
    stopping,
    stopped,
    failed,
};

pub const Status = struct {
    phase: Phase,
    operations: u8,
    active_jobs: u16,
};

pub const Error = error{
    InvalidWorkerIndex,
    InvalidPhase,
    InvalidCompletion,
    StartFailed,
    WakeControlFailed,
    WakeConsumeFailed,
    TerminalFailed,
    StopFailed,
};

/// Owns decoder threads and their one-shot eventfd poll. Bodyless storage
/// instantiates the empty branch and carries no worker-local runtime state.
pub fn Lifecycle(comptime Storage: type) type {
    const enabled = Storage.gzip_decoder_thread_count != 0;
    return if (enabled) struct {
        const Self = @This();

        wake: worker_wake_controller.Controller,
        phase: Phase = .initialized,
        cleanup_failed: bool = false,

        pub fn init(worker_index: u16) Error!Self {
            return .{
                .wake = worker_wake_controller.Controller.init(worker_index) catch {
                    return error.InvalidWorkerIndex;
                },
            };
        }

        /// Starts the configured fixed threads and arms their wake source before
        /// the worker is allowed to submit its listener accept.
        pub fn start(self: *Self, storage: *Storage, backend: anytype) Error!void {
            if (self.phase != .initialized) return error.InvalidPhase;
            const pool = storage.gzipPool().?;
            pool.start(Storage.runtime_limits.gzip.thread_stack_bytes) catch {
                self.rollbackStart(pool, false);
                return error.StartFailed;
            };

            const descriptor = pool.wakeDescriptor();
            std.debug.assert(descriptor >= 0);
            self.wake.arm(.{ .value = @intCast(descriptor) }, backend) catch {
                self.rollbackStart(pool, true);
                return error.WakeControlFailed;
            };
            self.phase = .running;
        }

        /// Consumes every coalesced slot signal through the request transport
        /// transaction before rearming the one-shot poll.
        pub fn handle(
            self: *Self,
            storage: *Storage,
            backend: anytype,
            completion: reactor.Completion,
            signal_context: anytype,
            comptime on_signal: anytype,
        ) Error!void {
            if (self.phase != .running and self.phase != .stopping) {
                return error.InvalidPhase;
            }
            const event = self.wake.handle(completion) catch |problem| {
                return switch (problem) {
                    error.InvalidCompletion => error.InvalidCompletion,
                    else => error.WakeControlFailed,
                };
            };
            if (event.ready) {
                try consumeSignals(
                    storage.gzipPool().?,
                    signal_context,
                    on_signal,
                );
            }
            if (event.stopped) {
                try self.finishStopped(storage.gzipPool().?);
                return;
            }
            if (event.ready and self.phase == .running) {
                const descriptor = storage.gzipPool().?.wakeDescriptor();
                std.debug.assert(descriptor >= 0);
                self.wake.rearm(.{ .value = @intCast(descriptor) }, backend) catch {
                    return error.WakeControlFailed;
                };
            }
        }

        /// Normal stop joins producers first, then retires the external poll
        /// through its ordinary cancel/target completion pair.
        pub fn beginStop(self: *Self, storage: *Storage, backend: anytype) Error!void {
            switch (self.phase) {
                .initialized => {
                    const pool = storage.gzipPool().?;
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return error.StopFailed;
                    };
                    if (failure != null) {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return error.StopFailed;
                    }
                    _ = self.wake.stop(backend) catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return error.WakeControlFailed;
                    };
                    self.phase = .stopped;
                },
                .running => {
                    const pool = storage.gzipPool().?;
                    if (pool.activeJobs() != 0) return error.InvalidPhase;
                    if (pool.beginStop() != null) self.cleanup_failed = true;
                    self.phase = .stopping;
                    const event = self.wake.stop(backend) catch {
                        return error.WakeControlFailed;
                    };
                    if (event.stopped) try self.finishStopped(pool);
                    if (self.cleanup_failed) return error.StopFailed;
                },
                .stopping, .stopped => {},
                .disabled, .failed => return error.InvalidPhase,
            }
        }

        /// Fatal stop joins every producer but deliberately leaves the eventfd
        /// and wake token intact until backend ownership is proven.
        pub fn beginFatal(self: *Self, storage: *Storage) void {
            switch (self.phase) {
                .running => {
                    if (storage.gzipPool().?.beginStop() != null) {
                        self.cleanup_failed = true;
                    }
                    self.phase = .stopping;
                },
                .initialized => {},
                .stopping, .stopped, .failed => {},
                .disabled => unreachable,
            }
        }

        /// Called only after the backend proves no kernel operation can still
        /// reference the eventfd. Returns false for any unresolved cleanup.
        pub fn finishFatalAfterBackend(
            self: *Self,
            storage: *Storage,
            signal_context: anytype,
            comptime on_signal: anytype,
        ) bool {
            self.wake.abortAfterBackend();
            const pool = storage.gzipPool().?;
            switch (pool.lifecycleStatus()) {
                .initialized => {
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return false;
                    };
                    if (failure != null) self.cleanup_failed = true;
                },
                .quiesced => {
                    settleFatalSignals(pool, signal_context, on_signal) catch {
                        self.cleanup_failed = true;
                    };
                    pool.retireWakePoll() catch {
                        self.cleanup_failed = true;
                    };
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return false;
                    };
                    if (failure != null) self.cleanup_failed = true;
                },
                .stopped => {},
                .running => {
                    self.cleanup_failed = true;
                },
            }
            self.phase = if (self.cleanup_failed) .failed else .stopped;
            return !self.cleanup_failed;
        }

        pub fn status(self: *const Self, storage: *const Storage) Status {
            return .{
                .phase = self.phase,
                .operations = @as(u8, @intFromBool(self.wake.currentPollToken() != null)) +
                    @as(u8, @intFromBool(self.wake.currentCancelToken() != null)),
                .active_jobs = storage.gzip_decoders.activeJobs(),
            };
        }

        pub fn isStopped(self: *const Self) bool {
            return self.phase == .stopped;
        }

        fn rollbackStart(self: *Self, pool: *Storage.GzipDecoderPool, exposed: bool) void {
            switch (pool.lifecycleStatus()) {
                .running => {
                    _ = pool.beginStop();
                    if (exposed) pool.retireWakePoll() catch {
                        self.cleanup_failed = true;
                    };
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return;
                    };
                    if (failure != null) self.cleanup_failed = true;
                },
                .initialized => {
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return;
                    };
                    if (failure != null and failure.?.stage == .close) {
                        self.cleanup_failed = true;
                    }
                },
                .quiesced => {
                    if (exposed) pool.retireWakePoll() catch {
                        self.cleanup_failed = true;
                    };
                    const failure = pool.finishStop() catch {
                        self.cleanup_failed = true;
                        self.phase = .failed;
                        return;
                    };
                    if (failure != null) self.cleanup_failed = true;
                },
                .stopped => if (pool.startFailure()) |failure| {
                    if (failure.stage == .close) self.cleanup_failed = true;
                },
            }
            self.phase = if (self.cleanup_failed) .failed else .stopped;
        }

        fn finishStopped(self: *Self, pool: *Storage.GzipDecoderPool) Error!void {
            pool.retireWakePoll() catch {
                self.cleanup_failed = true;
                self.phase = .failed;
                return error.StopFailed;
            };
            const failure = pool.finishStop() catch {
                self.cleanup_failed = true;
                self.phase = .failed;
                return error.StopFailed;
            };
            if (failure != null) {
                self.cleanup_failed = true;
                self.phase = .failed;
                return error.StopFailed;
            }
            self.phase = .stopped;
        }

        fn consumeSignals(
            pool: *Storage.GzipDecoderPool,
            signal_context: anytype,
            comptime on_signal: anytype,
        ) Error!void {
            const batch = switch (pool.consumeWake()) {
                .consumed => |consumed| consumed,
                .failed => return error.WakeConsumeFailed,
            };
            var signal_failed = false;
            for (batch.slots, 0..) |signals, index| {
                if (!signals.space and !signals.output and !signals.terminal) continue;
                on_signal(signal_context, @as(u16, @intCast(index)), signals) catch {
                    signal_failed = true;
                };
            }
            if (signal_failed) return error.TerminalFailed;
        }

        /// Joined producers cannot publish again. Scan preserved jobs as well
        /// as eventfd bits so a prior failed callback cannot strand a lease.
        fn settleFatalSignals(
            pool: *Storage.GzipDecoderPool,
            signal_context: anytype,
            comptime on_signal: anytype,
        ) Error!void {
            const batch = switch (pool.consumeWake()) {
                .consumed => |consumed| consumed,
                .failed => return error.WakeConsumeFailed,
            };
            var terminal_seen = [_]bool{false} ** Storage.GzipDecoderPool.slots_len;
            var signal_failed = false;
            for (batch.slots, 0..) |signals, index| {
                terminal_seen[index] = signals.terminal;
                if (!signals.terminal) continue;
                on_signal(signal_context, @as(u16, @intCast(index)), signals) catch {
                    signal_failed = true;
                };
            }
            for (terminal_seen, 0..) |seen, index| {
                if (seen or pool.leaseAt(@intCast(index)) == null) continue;
                on_signal(
                    signal_context,
                    @as(u16, @intCast(index)),
                    .{ .terminal = true },
                ) catch {
                    signal_failed = true;
                };
            }
            if (signal_failed) return error.TerminalFailed;
        }
    } else struct {
        const Self = @This();

        pub fn init(worker_index: u16) Error!Self {
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            return .{};
        }

        pub fn start(_: *Self, _: *Storage, _: anytype) Error!void {}

        pub fn handle(
            _: *Self,
            _: *Storage,
            _: anytype,
            _: reactor.Completion,
            _: anytype,
            comptime _: anytype,
        ) Error!void {
            return error.InvalidCompletion;
        }

        pub fn beginStop(_: *Self, _: *Storage, _: anytype) Error!void {}

        pub fn beginFatal(_: *Self, _: *Storage) void {}

        pub fn finishFatalAfterBackend(
            _: *Self,
            _: *Storage,
            _: anytype,
            comptime _: anytype,
        ) bool {
            return true;
        }

        pub fn status(_: *const Self, _: *const Storage) Status {
            return .{ .phase = .disabled, .operations = 0, .active_jobs = 0 };
        }

        pub fn isStopped(_: *const Self) bool {
            return true;
        }
    };
}

const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const sink_driver = @import("sink_driver.zig");

pub const ControlError = error{
    AlreadyStarted,
    CapacityExceeded,
    InvalidEntry,
    NoOperation,
    NotQuiescent,
};

pub const Outcome = enum(u8) {
    committed,
    aborted,
    failed,
};

pub const UpstreamFailure = enum(u8) {
    body,
    upload,
    verification,
    application,
    response_preparation,
    peer_disconnect,
    framework_canceled,
};

pub const FailureClass = union(enum) {
    upstream: UpstreamFailure,
    sink,
};

pub const CleanupFailureClass = enum(u8) {
    sink,
};

pub const FatalPhase = enum(u8) {
    preflight,
    commit,
    abort,
};

pub const FatalClass = enum(u8) {
    ownership_unproven,
    poisoned,
    busy,
    no_active,
    phase_mismatch,
    driver_failed,
    request_already_pending,
    invalid_request,
    completion_without_request,
    completion_kind_mismatch,
    completion_overflow,
    invalid_success,
    unexpected_control,
};

pub const Fatal = struct {
    class: FatalClass,
    phase: FatalPhase,
    entry_index: ?usize,
};

pub const PrimaryFailure = struct {
    class: FailureClass,
    entry_index: ?usize,
};

pub fn Finalizer(comptime Sink: type, comptime max_begun: usize) type {
    upload.validateRequestSink(Sink);
    if (max_begun > std.math.maxInt(u32)) {
        @compileError("upload finalizer capacity exceeds u32");
    }
    const mask_word_count = max_begun / 64 + @intFromBool(max_begun % 64 != 0);

    return struct {
        const Self = @This();
        const Lifecycle = sink_driver.Lifecycle(Sink);
        const Phase = enum(u8) { collecting, commit, abort, done, fatal };
        const Operation = enum(u1) { commit, abort };

        pub const Report = struct {
            outcome: Outcome = .aborted,
            primary: ?PrimaryFailure = null,
            cleanup_failure_mask: [mask_word_count]u64 =
                [_]u64{0} ** mask_word_count,
            cleanup_failure_classes: [max_begun]?CleanupFailureClass =
                [_]?CleanupFailureClass{null} ** max_begun,
            commit_attempted_count: u32 = 0,
            commit_completed_count: u32 = 0,
            abort_attempted_count: u32 = 0,
            abort_completed_count: u32 = 0,
            cleanup_failure_count: u32 = 0,

            pub fn responseAllowed(self: *const Report) bool {
                return self.outcome != .failed;
            }

            pub fn cleanupFailed(self: *const Report, index: usize) bool {
                return self.cleanupFailureClass(index) != null;
            }

            pub fn cleanupFailureClass(
                self: *const Report,
                index: usize,
            ) ?CleanupFailureClass {
                if (index >= max_begun) return null;
                if (comptime max_begun == 0) return null;
                return self.cleanup_failure_classes[index];
            }
        };

        pub const Step = union(enum) {
            request: upload.IoRequest,
            done: *const Report,
            fatal: Fatal,
        };

        states: [max_begun]*Sink.State = undefined,
        begun_count: usize = 0,
        cursor: usize = 0,
        current_index: usize = 0,
        phase: Phase = .collecting,
        operation: ?Operation = null,
        report: Report = .{},

        pub fn init() Self {
            return .{};
        }

        /// Appends one state in file-start order. The pointee remains stable
        /// until the returned finalization report is consumed.
        pub fn recordBegun(self: *Self, state: *Sink.State) ControlError!usize {
            if (self.phase != .collecting) return error.AlreadyStarted;
            if (comptime max_begun == 0) return error.CapacityExceeded;
            if (self.begun_count == max_begun) return error.CapacityExceeded;
            const index = self.begun_count;
            self.states[index] = state;
            self.begun_count += 1;
            return index;
        }

        pub fn noteSinkFailure(self: *Self, index: usize) ControlError!void {
            if (self.phase != .collecting) return error.AlreadyStarted;
            if (index >= self.begun_count) return error.InvalidEntry;
            if (self.report.primary == null) {
                self.report.primary = .{
                    .class = .sink,
                    .entry_index = index,
                };
            }
        }

        pub fn startCommit(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
        ) ControlError!Step {
            if (try self.preflight(lifecycle)) |terminal| return terminal;
            if (lifecycle.failed) {
                return self.failFatal(.driver_failed, .preflight, null);
            }
            self.phase = .commit;
            self.cursor = 0;
            return self.driveCommit(runtime, lifecycle);
        }

        pub fn startAbort(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
            cause: ?UpstreamFailure,
        ) ControlError!Step {
            if (try self.preflight(lifecycle)) |terminal| return terminal;
            if (cause) |problem| if (self.report.primary == null) {
                self.report.primary = .{
                    .class = .{ .upstream = problem },
                    .entry_index = null,
                };
            };
            self.phase = .abort;
            self.cursor = self.begun_count;
            return self.driveAbort(runtime, lifecycle);
        }

        pub fn complete(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
            completion: upload.IoCompletion,
        ) ControlError!Step {
            const operation = self.operation orelse return error.NoOperation;
            return switch (operation) {
                .commit => self.resumeCommit(runtime, lifecycle, completion),
                .abort => self.resumeAbort(runtime, lifecycle, completion),
            };
        }

        pub fn pendingRequest(
            self: *const Self,
            lifecycle: *const Lifecycle,
        ) ?upload.IoRequest {
            _ = self;
            return lifecycle.poller.pendingRequest();
        }

        pub fn pendingEntryIndex(self: *const Self) ?usize {
            if (self.operation == null) return null;
            return self.current_index;
        }

        fn preflight(self: *Self, lifecycle: *const Lifecycle) ControlError!?Step {
            if (self.phase != .collecting) return error.AlreadyStarted;
            if (!lifecycle.ownershipProven()) {
                return self.failFatal(.ownership_unproven, .preflight, null);
            }
            if (!lifecycle.quiescent()) return error.NotQuiescent;
            switch (lifecycle.latchedFailureSource()) {
                .none => if (lifecycle.failed) {
                    return self.failFatal(.driver_failed, .preflight, null);
                },
                .sink => if (self.report.primary == null) {
                    self.report.primary = .{ .class = .sink, .entry_index = null };
                },
                .invalid_request => {
                    return self.failFatal(.invalid_request, .preflight, null);
                },
                .completion => return self.failFatal(.poisoned, .preflight, null),
                .control => return self.failFatal(.unexpected_control, .preflight, null),
            }
            return null;
        }

        fn driveCommit(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
        ) Step {
            while (self.cursor < self.begun_count) {
                const index = self.cursor;
                self.current_index = index;
                self.report.commit_attempted_count += 1;
                const result = lifecycle.startCommit(
                    runtime,
                    self.stateAt(index),
                ) catch |problem| return self.commitError(
                    runtime,
                    lifecycle,
                    index,
                    problem,
                );
                switch (result) {
                    .request => |request| {
                        self.operation = .commit;
                        return .{ .request = request };
                    },
                    .done => self.commitCompleted(),
                }
            }
            self.phase = .done;
            self.report.outcome = .committed;
            return .{ .done = &self.report };
        }

        fn resumeCommit(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
            completion: upload.IoCompletion,
        ) Step {
            const index = self.current_index;
            const result = lifecycle.resumeCommit(
                runtime,
                self.stateAt(index),
                completion,
            ) catch |problem| {
                self.operation = null;
                return self.commitError(runtime, lifecycle, index, problem);
            };
            return switch (result) {
                .request => |request| .{ .request = request },
                .done => done: {
                    self.operation = null;
                    self.commitCompleted();
                    break :done self.driveCommit(runtime, lifecycle);
                },
            };
        }

        fn commitError(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
            index: usize,
            problem: Lifecycle.Error,
        ) Step {
            if (lifecycle.lastFailureSource() != .sink) {
                return self.driverFatal(lifecycle, problem, .commit, index);
            }
            self.report.primary = .{
                .class = .sink,
                .entry_index = index,
            };
            self.phase = .abort;
            self.cursor = self.begun_count;
            return self.driveAbort(runtime, lifecycle);
        }

        fn commitCompleted(self: *Self) void {
            self.report.commit_completed_count += 1;
            self.cursor += 1;
        }

        fn driveAbort(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
        ) Step {
            while (self.cursor > 0) {
                self.cursor -= 1;
                const index = self.cursor;
                self.current_index = index;
                self.report.abort_attempted_count += 1;
                const result = lifecycle.startAbort(
                    runtime,
                    self.stateAt(index),
                ) catch |problem| {
                    const failure = self.abortError(lifecycle, index, problem);
                    if (failure) |terminal| return terminal;
                    continue;
                };
                switch (result) {
                    .request => |request| {
                        self.operation = .abort;
                        return .{ .request = request };
                    },
                    .done => self.report.abort_completed_count += 1,
                }
            }
            return self.finishAbort();
        }

        fn resumeAbort(
            self: *Self,
            runtime: *Sink.Runtime,
            lifecycle: *Lifecycle,
            completion: upload.IoCompletion,
        ) Step {
            const index = self.current_index;
            const result = lifecycle.resumeAbort(
                runtime,
                self.stateAt(index),
                completion,
            ) catch |problem| {
                self.operation = null;
                if (self.abortError(lifecycle, index, problem)) |terminal| return terminal;
                return self.driveAbort(runtime, lifecycle);
            };
            return switch (result) {
                .request => |request| .{ .request = request },
                .done => done: {
                    self.operation = null;
                    self.report.abort_completed_count += 1;
                    break :done self.driveAbort(runtime, lifecycle);
                },
            };
        }

        fn abortError(
            self: *Self,
            lifecycle: *Lifecycle,
            index: usize,
            problem: Lifecycle.Error,
        ) ?Step {
            if (lifecycle.lastFailureSource() != .sink) {
                return self.driverFatal(lifecycle, problem, .abort, index);
            }
            self.markCleanupFailure(index, .sink);
            return null;
        }

        fn markCleanupFailure(
            self: *Self,
            index: usize,
            class: CleanupFailureClass,
        ) void {
            if (comptime max_begun > 0) {
                const bit = @as(u6, @truncate(index));
                self.report.cleanup_failure_mask[index / 64] |=
                    @as(u64, 1) << bit;
                self.report.cleanup_failure_classes[index] = class;
            }
            self.report.cleanup_failure_count += 1;
        }

        fn finishAbort(self: *Self) Step {
            self.phase = .done;
            self.report.outcome = if (self.report.primary != null or
                self.report.cleanup_failure_count != 0)
                .failed
            else
                .aborted;
            return .{ .done = &self.report };
        }

        fn driverFatal(
            self: *Self,
            lifecycle: *const Lifecycle,
            problem: Lifecycle.Error,
            phase: FatalPhase,
            index: usize,
        ) Step {
            const class = classifyFatal(
                problem,
                lifecycle.lastFailureSource(),
            );
            return self.failFatal(class, phase, index);
        }

        fn failFatal(
            self: *Self,
            class: FatalClass,
            phase: FatalPhase,
            index: ?usize,
        ) Step {
            self.operation = null;
            self.phase = .fatal;
            return .{ .fatal = .{
                .class = class,
                .phase = phase,
                .entry_index = index,
            } };
        }

        fn stateAt(self: *Self, index: usize) *Sink.State {
            if (comptime max_begun == 0) unreachable;
            return self.states[index];
        }

        fn classifyFatal(
            problem: Lifecycle.Error,
            source: sink_driver.FailureSource,
        ) FatalClass {
            return switch (source) {
                .completion => completionFatal(problem),
                .invalid_request => .invalid_request,
                .control => controlFatal(problem),
                .none => .unexpected_control,
                .sink => unreachable,
            };
        }

        fn completionFatal(problem: Lifecycle.Error) FatalClass {
            return switch (problem) {
                error.Poisoned => .poisoned,
                error.NoActive => .no_active,
                error.PhaseMismatch => .phase_mismatch,
                error.CompletionWithoutRequest => .completion_without_request,
                error.CompletionKindMismatch => .completion_kind_mismatch,
                error.CompletionOverflow => .completion_overflow,
                error.InvalidSuccess => .invalid_success,
                else => .unexpected_control,
            };
        }

        fn controlFatal(problem: Lifecycle.Error) FatalClass {
            return switch (problem) {
                error.Busy => .busy,
                error.Failed => .driver_failed,
                error.RequestAlreadyPending => .request_already_pending,
                else => .unexpected_control,
            };
        }
    };
}

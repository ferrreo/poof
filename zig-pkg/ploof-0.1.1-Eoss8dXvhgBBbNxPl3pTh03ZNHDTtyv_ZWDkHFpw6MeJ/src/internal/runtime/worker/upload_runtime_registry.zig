const std = @import("std");

const multipart = @import("../../../multipart/upload.zig");
const reactor = @import("../reactor.zig");
const upload_file_table = @import("../upload/file_table.zig");
const upload_transport = @import("../upload/transport.zig");
const validation = @import("../upload/transport_validation.zig");
const runtime_deadline = @import("upload_runtime_deadline.zig");
const support = @import("upload_runtime_registry_support.zig");
const sink = @import("upload_runtime_registry_sink.zig");
const runtimeIndex = support.runtimeIndex;
const runtimeOwner = support.runtimeOwner;

pub fn Lifecycle(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime RuntimePhase: type,
    comptime Event: type,
    comptime Error: type,
) type {
    return struct {
        pub fn beginStart(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            entropy: *const [32]u8,
            now_ns: u64,
        ) Error!Event {
            if (self.phase != .idle or self.transport.pendingTargets() != 0) {
                return error.StateInvariant;
            }
            self.phase = .starting;
            self.runtime_cursor = 0;
            self.runtime_entropy = entropy.*;
            self.startup_failure = null;
            self.startup_failure_index = null;
            self.startup_diagnostic = null;
            self.runtime_deadline_diagnostic = null;
            self.runtime_metric_index = null;
            self.rollback_cleanup_failed = false;
            self.runtime_now_ns = now_ns;
            return driveStart(self, storage, io) catch |problem| {
                if (runtimeTargetHalfSubmitted(self)) return problem;
                if (self.phase == .starting) {
                    return startupFailed(self, storage, io, problem);
                }
                return problem;
            };
        }

        pub fn beginStop(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            now_ns: u64,
        ) Error!Event {
            if (self.phase != .ready or self.transport.pendingTargets() != 0) {
                return error.StateInvariant;
            }
            self.phase = .stopping;
            self.runtime_cursor = App.UploadCatalog.sink_types.len;
            self.startup_failure = null;
            self.startup_failure_index = null;
            self.startup_diagnostic = null;
            self.runtime_deadline_diagnostic = null;
            self.runtime_metric_index = null;
            self.rollback_cleanup_failed = false;
            self.runtime_now_ns = now_ns;
            return driveStop(self, storage, io);
        }

        pub fn complete(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            cookie: anytype,
            completion: multipart.IoCompletion,
        ) Error!Event {
            if (cookie.registry_index != runtimeIndex(
                self.runtime_cursor,
                cookie.phase,
                self.startup_cleanup_index,
            )) {
                return error.StateInvariant;
            }
            return switch (cookie.phase) {
                .start => completeStart(self, storage, io, cookie.registry_index, completion),
                .stop => completeStop(self, storage, io, cookie.registry_index, completion),
                .cleanup => if (self.phase != .rolling_back)
                    error.StateInvariant
                else
                    completeOwnerCleanup(
                        self,
                        storage,
                        io,
                        cookie.registry_index,
                        completion,
                    ),
            };
        }

        pub fn completeTransport(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            token: reactor.OperationToken,
            delivery: ?@TypeOf(self.transport).Delivery,
            now_ns: u64,
        ) Error!Event {
            self.runtime_now_ns = now_ns;
            const action = self.runtime_deadline.observeTransport(token, delivery) catch
                return error.StateInvariant;
            try applyAction(self, io, action);
            return settleDeadline(self, storage, io);
        }

        pub fn completeControl(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Event {
            self.runtime_now_ns = now_ns;
            const fields = completion.token.fields() catch return error.StateInvariant;
            const action: runtime_deadline.Action = switch (fields.kind) {
                .timeout => self.runtime_deadline.observeTimeout(completion) catch
                    return error.StateInvariant,
                .cancel => action: {
                    self.runtime_deadline.observeTimeoutCancel(completion) catch |problem| {
                        return if (problem == error.BackendFailure)
                            error.BackendFailure
                        else
                            error.StateInvariant;
                    };
                    break :action .none;
                },
                else => return error.StateInvariant,
            };
            try applyAction(self, io, action);
            return settleDeadline(self, storage, io);
        }

        fn completeStart(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
            completion: multipart.IoCompletion,
        ) Error!Event {
            if (self.phase != .starting) return error.StateInvariant;
            const poll = sink.resumeStart(
                App,
                Error,
                self,
                storage,
                index,
                completion,
            ) catch |problem| {
                if (self.startup_cleanup_active) return finishStartupCleanup(self, storage, io);
                return startupFailed(self, storage, io, problem);
            };
            switch (poll) {
                .request => |request| {
                    submit(self, io, index, .start, request) catch |problem| {
                        if (runtimeTargetHalfSubmitted(self)) return problem;
                        return startupSubmissionFailed(self, storage, io, index, problem);
                    };
                    return .none;
                },
                .done => self.runtime_cursor += 1,
            }
            if (self.startup_cleanup_active) return finishStartupCleanup(self, storage, io);
            return driveStart(self, storage, io) catch |problem| {
                if (runtimeTargetHalfSubmitted(self)) return problem;
                return startupFailed(self, storage, io, problem);
            };
        }

        fn completeStop(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
            completion: multipart.IoCompletion,
        ) Error!Event {
            if (self.phase != .stopping and self.phase != .rolling_back) {
                return error.StateInvariant;
            }
            const poll = sink.resumeStop(App, Error, storage, index, completion) catch |problem| {
                return stopFailed(self, storage, io, index, problem);
            };
            switch (poll) {
                .request => |request| {
                    submit(self, io, index, .stop, request) catch |problem| {
                        if (runtimeTargetHalfSubmitted(self)) return problem;
                        if (!sink.abandonStop(App, storage, index)) return error.StateInvariant;
                        return stopFailed(self, storage, io, index, problem);
                    };
                    return .none;
                },
                .done => if (try stoppedSink(self, storage, io, index)) |event| return event,
            }
            return if (self.phase == .rolling_back)
                driveRollback(self, storage, io)
            else
                driveStop(self, storage, io);
        }

        fn startupFailed(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            problem: Error,
        ) Error!Event {
            std.debug.assert(self.phase == .starting);
            std.debug.assert(self.startup_failure == null);
            std.debug.assert(self.startup_failure_index == null);
            self.startup_failure = problem;
            self.startup_failure_index = @intCast(self.runtime_cursor);
            self.runtime_metric_index = self.startup_failure_index;
            self.startup_cleanup_active = false;
            self.startup_cleanup_index = @intCast(self.runtime_cursor);
            return beginOwnerCleanup(
                self,
                storage,
                io,
                @intCast(self.runtime_cursor),
            );
        }

        fn startupSubmissionFailed(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
            problem: Error,
        ) Error!Event {
            std.debug.assert(self.phase == .starting);
            std.debug.assert(index == self.runtime_cursor);
            if (!self.startup_cleanup_active) {
                std.debug.assert(self.startup_failure == null);
                std.debug.assert(self.startup_failure_index == null);
                const sink_failure_active = self.startup_diagnostic != null;
                self.startup_failure = if (sink_failure_active)
                    error.ApplicationFailure
                else
                    problem;
                self.startup_failure_index = index;
                self.runtime_metric_index = index;
                self.startup_cleanup_active = true;
                self.startup_cleanup_index = index;
                self.rollback_cleanup_failed = sink_failure_active;
            } else {
                self.rollback_cleanup_failed = true;
            }
            return driveStartupCleanup(self, storage, io, index);
        }

        fn driveStartupCleanup(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
        ) Error!Event {
            const poll = sink.resumeStart(
                App,
                Error,
                self,
                storage,
                index,
                .{ .failure = .canceled },
            ) catch return finishStartupCleanup(self, storage, io);
            switch (poll) {
                .done => {
                    self.runtime_cursor += 1;
                    return finishStartupCleanup(self, storage, io);
                },
                .request => |request| submit(self, io, index, .start, request) catch |problem| {
                    if (runtimeTargetHalfSubmitted(self)) return problem;
                    self.rollback_cleanup_failed = true;
                    if (!sink.abandonStart(App, self, storage, index)) {
                        return error.StateInvariant;
                    }
                    return finishStartupCleanup(self, storage, io);
                },
            }
            return .none;
        }

        fn finishStartupCleanup(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
        ) Error!Event {
            std.debug.assert(self.startup_cleanup_active);
            self.startup_cleanup_active = false;
            return beginOwnerCleanup(self, storage, io, self.startup_cleanup_index);
        }

        fn beginOwnerCleanup(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
        ) Error!Event {
            std.debug.assert(self.runtime_cleanup_handle == null);
            self.startup_cleanup_index = index;
            self.phase = .rolling_back;
            return driveOwnerCleanup(self, storage, io, index);
        }

        fn completeOwnerCleanup(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
            completion: multipart.IoCompletion,
        ) Error!Event {
            const handle = self.runtime_cleanup_handle orelse return error.StateInvariant;
            self.runtime_cleanup_handle = null;
            if (completion == .failure) {
                self.rollback_cleanup_failed = true;
                self.transport.table().abandon(
                    handle,
                    runtimeOwner(self.worker_index, index),
                ) catch return error.StateInvariant;
            }
            return driveOwnerCleanup(self, storage, io, index);
        }

        fn driveOwnerCleanup(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
        ) Error!Event {
            const owner = runtimeOwner(self.worker_index, index);
            var cursor = upload_file_table.CleanupCursor{};
            while (self.transport.nextCleanup(&cursor)) |entry| {
                if (!entry.owner.eql(owner)) continue;
                if (entry.phase != .open or entry.references != 0) {
                    self.rollback_cleanup_failed = true;
                    if (entry.phase != .ownership_unproven) {
                        self.transport.table().abandon(entry.handle, owner) catch {
                            return error.StateInvariant;
                        };
                    }
                    continue;
                }
                self.runtime_cleanup_handle = entry.handle;
                submit(
                    self,
                    io,
                    index,
                    .cleanup,
                    .{ .close = .{ .file = entry.handle } },
                ) catch |problem| {
                    if (runtimeTargetHalfSubmitted(self)) return problem;
                    self.runtime_cleanup_handle = null;
                    self.rollback_cleanup_failed = true;
                    self.transport.table().abandon(entry.handle, owner) catch {
                        return error.StateInvariant;
                    };
                    continue;
                };
                return .none;
            }
            return driveRollback(self, storage, io);
        }

        fn stopFailed(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
            problem: Error,
        ) Error!Event {
            std.debug.assert(@as(u32, index) + 1 == self.runtime_cursor);
            if (self.phase == .stopping) {
                std.debug.assert(self.startup_failure == null);
                std.debug.assert(self.startup_failure_index == null);
                self.startup_failure = problem;
                self.startup_failure_index = index;
                self.runtime_metric_index = index;
            } else {
                std.debug.assert(self.phase == .rolling_back);
                std.debug.assert(self.startup_failure != null);
                std.debug.assert(self.startup_failure_index != null);
                self.rollback_cleanup_failed = true;
            }
            self.runtime_cursor -= 1;
            return beginOwnerCleanup(self, storage, io, index);
        }

        fn stoppedSink(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
        ) Error!?Event {
            std.debug.assert(@as(u32, index) + 1 == self.runtime_cursor);
            self.runtime_cursor -= 1;
            if (!ownerHasHandles(self, index)) return null;
            if (self.phase == .stopping) {
                std.debug.assert(self.startup_failure == null);
                std.debug.assert(self.startup_failure_index == null);
                self.startup_failure = error.ApplicationFailure;
                self.startup_failure_index = index;
                self.runtime_metric_index = index;
            } else {
                std.debug.assert(self.phase == .rolling_back);
                std.debug.assert(self.startup_failure != null);
                std.debug.assert(self.startup_failure_index != null);
                self.rollback_cleanup_failed = true;
            }
            return try beginOwnerCleanup(self, storage, io, index);
        }

        fn ownerHasHandles(self: anytype, index: u16) bool {
            const owner = runtimeOwner(self.worker_index, index);
            var cursor = upload_file_table.CleanupCursor{};
            while (self.transport.nextCleanup(&cursor)) |entry| {
                if (entry.owner.eql(owner)) return true;
            }
            return false;
        }

        fn driveStart(self: anytype, storage: *Storage, io: *Reactor) Error!Event {
            while (self.runtime_cursor < App.UploadCatalog.sink_types.len) {
                const index: u16 = @intCast(self.runtime_cursor);
                const poll = try sink.start(App, Error, self, storage, index);
                switch (poll) {
                    .request => |request| {
                        submit(self, io, index, .start, request) catch |problem| {
                            if (runtimeTargetHalfSubmitted(self)) return problem;
                            return startupSubmissionFailed(self, storage, io, index, problem);
                        };
                        return .none;
                    },
                    .done => self.runtime_cursor += 1,
                }
            }
            self.phase = .ready;
            return .registry_ready;
        }

        fn driveStop(self: anytype, storage: *Storage, io: *Reactor) Error!Event {
            while (self.runtime_cursor != 0) {
                const index: u16 = @intCast(self.runtime_cursor - 1);
                const poll = sink.stop(App, Error, storage, index) catch |problem| {
                    return stopFailed(self, storage, io, index, problem);
                };
                switch (poll) {
                    .request => |request| {
                        submit(self, io, index, .stop, request) catch |problem| {
                            if (runtimeTargetHalfSubmitted(self)) return problem;
                            if (!sink.abandonStop(App, storage, index)) {
                                return error.StateInvariant;
                            }
                            return stopFailed(self, storage, io, index, problem);
                        };
                        return .none;
                    },
                    .done => if (try stoppedSink(self, storage, io, index)) |event| {
                        return event;
                    },
                }
            }
            self.phase = .stopped;
            return .registry_stopped;
        }

        fn driveRollback(self: anytype, storage: *Storage, io: *Reactor) Error!Event {
            while (self.runtime_cursor != 0) {
                const index: u16 = @intCast(self.runtime_cursor - 1);
                const poll = sink.stop(App, Error, storage, index) catch |problem| {
                    return stopFailed(self, storage, io, index, problem);
                };
                switch (poll) {
                    .request => |request| {
                        submit(self, io, index, .stop, request) catch |problem| {
                            if (runtimeTargetHalfSubmitted(self)) return problem;
                            if (!sink.abandonStop(App, storage, index)) {
                                return error.StateInvariant;
                            }
                            return stopFailed(self, storage, io, index, problem);
                        };
                        return .none;
                    },
                    .done => if (try stoppedSink(self, storage, io, index)) |event| {
                        return event;
                    },
                }
            }
            self.phase = .failed;
            self.runtime_metric_index = self.startup_failure_index;
            return self.startup_failure orelse error.StateInvariant;
        }

        fn submit(
            self: anytype,
            io: *Reactor,
            registry_index: u16,
            phase: RuntimePhase,
            request: multipart.IoRequest,
        ) Error!void {
            if (self.runtime_deadline.active) return error.StateInvariant;
            const deadline_ns = std.math.add(
                u64,
                self.runtime_now_ns,
                Storage.runtime_limits.timeouts.startup_io_ns,
            ) catch {
                if (phase == .start and self.phase == .starting) {
                    recordDeadlineFailure(self, registry_index, .clock_overflow, 0);
                }
                return error.ApplicationFailure;
            };
            const owner = runtimeOwner(self.worker_index, registry_index);
            const token = try nextToken(
                self,
                validation.expectedKind(std.meta.activeTag(request)),
            );
            const prepared = self.transport.prepareTarget(
                owner,
                token,
                .{ .runtime = .{ .registry_index = registry_index, .phase = phase } },
                request,
            ) catch return error.TransportFailure;
            io.submit(prepared) catch {
                const delivery = self.transport.rollback(token) catch {
                    return error.TransportFailure;
                };
                if (delivery != null) return error.TransportFailure;
                return error.BackendFailure;
            };
            self.transport.markSubmitted(token) catch {
                self.runtime_submission_unproven = true;
                return error.TransportFailure;
            };
            const timeout = nextToken(self, .timeout) catch |problem| {
                self.runtime_submission_unproven = true;
                return problem;
            };
            io.submit(.{ .token = timeout, .operation = .{ .timeout = .{
                .deadline_ns = deadline_ns,
            } } }) catch {
                self.runtime_submission_unproven = true;
                return error.BackendFailure;
            };
            self.runtime_deadline.begin(
                .{ .registry_index = registry_index, .phase = phase },
                token,
                timeout,
                deadline_ns,
            ) catch {
                self.runtime_submission_unproven = true;
                return error.StateInvariant;
            };
        }

        fn runtimeTargetHalfSubmitted(self: anytype) bool {
            return !self.runtime_deadline.active and self.transport.pendingTargets() != 0;
        }

        fn applyAction(
            self: anytype,
            io: *Reactor,
            action: runtime_deadline.Action,
        ) Error!void {
            switch (action) {
                .none => {},
                .cancel_timeout => {
                    const target = self.runtime_deadline.timeout_token orelse
                        return error.StateInvariant;
                    const token = try nextToken(self, .cancel);
                    io.submit(.{ .token = token, .operation = .{ .cancel = .{
                        .target = target,
                    } } }) catch return error.BackendFailure;
                    self.runtime_deadline.armTimeoutCancel(token) catch
                        return error.StateInvariant;
                },
                .cancel_target => {
                    const target = self.runtime_deadline.target_token orelse
                        return error.StateInvariant;
                    const token = try nextToken(self, .upload_cancel);
                    const submission = self.transport.prepareCancel(target, token) catch
                        return error.TransportFailure;
                    io.submit(submission) catch {
                        _ = self.transport.rollback(token) catch
                            return error.TransportFailure;
                        return error.BackendFailure;
                    };
                    self.transport.markSubmitted(token) catch return error.TransportFailure;
                    self.runtime_deadline.armTargetCancel(token) catch
                        return error.StateInvariant;
                },
            }
        }

        fn settleDeadline(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
        ) Error!Event {
            const outcome = (self.runtime_deadline.takeOutcome() catch
                return error.StateInvariant) orelse return .none;
            return switch (outcome) {
                .target => |delivery| switch (delivery.cookie) {
                    .runtime => |cookie| complete(
                        self,
                        storage,
                        io,
                        cookie,
                        delivery.completion,
                    ),
                    .request => error.StateInvariant,
                },
                .deadline => |failure| deadlineSettled(self, storage, io, failure),
            };
        }

        fn deadlineSettled(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            failure: anytype,
        ) Error!Event {
            if (failure.cookie.phase == .cleanup) {
                return complete(
                    self,
                    storage,
                    io,
                    failure.cookie,
                    failure.delivery.completion,
                );
            }
            if (failure.cookie.phase == .start) {
                recordDeadlineFailure(
                    self,
                    failure.cookie.registry_index,
                    failure.kind,
                    failure.deadline_ns,
                );
                if (!self.startup_cleanup_active) {
                    return deadlineStartFailed(
                        self,
                        storage,
                        io,
                        failure.cookie.registry_index,
                    );
                }
            }
            return complete(
                self,
                storage,
                io,
                failure.cookie,
                .{ .failure = .canceled },
            );
        }

        fn recordDeadlineFailure(
            self: anytype,
            registry_index: u16,
            kind: runtime_deadline.FailureKind,
            deadline_ns: u64,
        ) void {
            if (self.runtime_deadline_diagnostic != null) return;
            self.runtime_deadline_diagnostic = .{
                .registry_index = registry_index,
                .failure = .{
                    .kind = switch (kind) {
                        .deadline => .deadline,
                        .timer_failure => .timer_failure,
                        .clock_overflow => .clock_overflow,
                    },
                    .timeout_ns = Storage.runtime_limits.timeouts.startup_io_ns,
                    .started_ns = if (deadline_ns == 0)
                        self.runtime_now_ns
                    else
                        deadline_ns - Storage.runtime_limits.timeouts.startup_io_ns,
                    .deadline_ns = deadline_ns,
                },
            };
        }

        fn deadlineStartFailed(
            self: anytype,
            storage: *Storage,
            io: *Reactor,
            index: u16,
        ) Error!Event {
            if (self.phase != .starting or index != self.runtime_cursor or
                self.startup_failure != null or self.startup_failure_index != null)
            {
                return error.StateInvariant;
            }
            self.startup_failure = error.ApplicationFailure;
            self.startup_failure_index = index;
            self.runtime_metric_index = index;
            self.startup_cleanup_active = true;
            self.startup_cleanup_index = index;
            return driveStartupCleanup(self, storage, io, index);
        }

        fn nextToken(
            self: anytype,
            kind: reactor.OperationKind,
        ) Error!reactor.OperationToken {
            var sequence = self.runtime_sequence;
            for (0..8) |_| {
                const token = reactor.OperationToken.init(.{
                    .kind = kind,
                    .worker_index = self.worker_index,
                    .slot_index = reactor.upload_runtime_control_slot,
                    .slot_generation = 1,
                    .sequence = sequence,
                }) catch return error.StateInvariant;
                const next = reactor.nextSequence(sequence);
                if (!self.runtime_deadline.contains(token)) {
                    self.runtime_sequence = next;
                    return token;
                }
                sequence = next;
            }
            return error.StateInvariant;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");

const application = @import("../../../application.zig");
const response_stream = @import("../../../response/stream.zig");
const response_framing = @import("../../http1/response_framing.zig");
const response_transfer = @import("../../http1/response_transfer.zig");
const worker_stream_wake = @import("../worker/stream_wake.zig");

pub const Error = error{
    InvalidLifecycle,
    InvalidTransmission,
    InvalidWake,
    InvalidOutcome,
    InvalidInvalidation,
};

pub const Phase = enum(u8) {
    sending_head,
    sending_suppressed_head,
    sending_body,
    waiting,
    awaiting_invalidation,
    sending_terminal,
    finished,
};

pub const SendKind = enum(u8) { head, body, terminal };

pub const Send = struct {
    kind: SendKind,
    bytes: []const u8,
};

/// Caller drains each send before calling `sent`. Wake invalidation remains caller-owned.
pub const Action = union(enum) {
    send: Send,
    pending,
    /// Invoke `ready` once in a later caller turn; never loop inside one dispatch.
    poll_ready,
    invalidate: application.TransportOutcome,
    finished: application.TransportOutcome,
};

const Cleanup = enum(u8) {
    normal_exact,
    normal_unknown,
    failure,
};

/// Allocation-free HTTP/1.1 stream driver over one stable application workspace.
pub fn State(comptime App: type) type {
    return struct {
        const Self = @This();

        workspace: *App.Workspace,
        staging: []u8,
        framing: response_framing.Plan,
        trailers: response_transfer.TrailerPlan,
        runtime_wake: worker_stream_wake.StreamWake = undefined,
        producer_wake: response_stream.Wake = undefined,
        success_outcome: application.TransportOutcome,
        terminal_bytes: usize = 0,
        cleanup: Cleanup = .failure,
        state: Phase,

        /// `self`, `workspace`, and `staging` remain stable until a finished action.
        pub fn init(
            self: *Self,
            workspace: *App.Workspace,
            prepared: application.Prepared,
            staging: []u8,
            runtime_wake: ?worker_stream_wake.StreamWake,
            success_outcome: application.TransportOutcome,
        ) Error!Action {
            const transmission = switch (prepared.transmission) {
                .finite => return error.InvalidTransmission,
                .stream => |stream| stream,
            };
            if (!successOutcomeValid(success_outcome)) return error.InvalidOutcome;
            if (transmission.framing.invoke_stream != (runtime_wake != null)) {
                return error.InvalidWake;
            }
            self.* = .{
                .workspace = workspace,
                .staging = staging,
                .framing = transmission.framing,
                .trailers = transmission.trailers,
                .success_outcome = success_outcome,
                .state = .sending_head,
            };
            if (transmission.framing.invoke_stream) {
                self.runtime_wake = runtime_wake.?;
                self.producer_wake = response_stream.Wake.init(
                    &self.runtime_wake,
                    self.runtime_wake.generation(),
                    notifyProducerWake,
                );
            }

            if (!transmissionValid(self)) return self.rejectAtInit(.framework_canceled);
            if (declarationsAlias(
                workspace.stream.trailerNames(),
                transmission.trailers,
                staging,
            )) {
                return self.rejectAtInit(.producer_failed);
            }
            if (!transmission.framing.invoke_stream) {
                workspace.stream.suppress() catch return error.InvalidLifecycle;
                self.state = .sending_suppressed_head;
                return send(.head, prepared.source.contiguous_wire);
            }
            return send(.head, prepared.source.contiguous_wire);
        }

        /// Advances only after the prior send bytes were fully drained.
        pub fn sent(self: *Self) Error!Action {
            return switch (self.state) {
                .sending_head => self.drive(),
                .sending_suppressed_head => self.finish(self.success_outcome),
                .sending_body => self.drive(),
                .sending_terminal => self.finish(self.success_outcome),
                else => error.InvalidLifecycle,
            };
        }

        /// Claims one retained wake. A new `poll_ready` action requires another caller turn.
        pub fn ready(self: *Self) Error!Action {
            if (self.state != .waiting) return error.InvalidLifecycle;
            return switch (self.runtime_wake.claimReady()) {
                .claimed => self.drive(),
                .not_ready => .pending,
                .stale => self.finishAlreadyInvalidated(.framework_canceled),
            };
        }

        /// Requests cancellation after caller has recovered any outstanding SEND buffer.
        pub fn cancel(
            self: *Self,
            outcome: application.TransportOutcome,
        ) Error!Action {
            if (!cancelOutcomeValid(outcome)) return error.InvalidOutcome;
            return switch (self.state) {
                .sending_head, .sending_body, .waiting => self.requestFailure(outcome),
                .awaiting_invalidation => self.requestFailure(outcome),
                .sending_terminal => self.finish(outcome),
                .sending_suppressed_head => self.finish(outcome),
                .finished => error.InvalidLifecycle,
            };
        }

        /// Confirms caller-owned wake invalidation, then settles producer callbacks once.
        pub fn invalidated(
            self: *Self,
            result: worker_stream_wake.InvalidateResult,
        ) Error!Action {
            if (self.state != .awaiting_invalidation) return error.InvalidLifecycle;
            if (result != .invalidated) return error.InvalidInvalidation;
            return switch (self.cleanup) {
                .normal_exact => self.joinAndFinish(),
                .normal_unknown => self.joinAndSendTerminal(),
                .failure => self.settleFailure(),
            };
        }

        pub fn phase(self: *const Self) Phase {
            return self.state;
        }

        /// The outstanding buffer is the complete response; no producer poll remains.
        pub fn bufferCompletionFinishesResponse(self: *const Self) bool {
            return self.state == .sending_terminal or
                self.state == .sending_suppressed_head;
        }

        pub fn wake(self: *const Self) ?worker_stream_wake.StreamWake {
            if (!self.framing.invoke_stream) return null;
            return self.runtime_wake;
        }

        fn drive(self: *Self) Action {
            const output = switch (self.framing.framing) {
                .chunked => response_transfer.chunkWritable(self.staging) catch {
                    return self.requestFailure(.framework_canceled);
                },
                .fixed => self.staging,
                .none => return self.requestFailure(.framework_canceled),
            };
            const result = self.workspace.stream.poll(output, self.producer_wake) catch |problem| {
                return self.requestFailure(mapDriveError(problem));
            };
            return switch (result) {
                .progress => |count| self.progress(output[0..count]),
                .pending => self.pending(),
                .done => |fields| self.done(fields),
            };
        }

        fn progress(self: *Self, bytes: []const u8) Action {
            const wire = switch (self.framing.framing) {
                .chunked => response_transfer.writeChunk(self.staging, bytes) catch {
                    return self.requestFailure(.framework_canceled);
                },
                .fixed => bytes,
                .none => return self.requestFailure(.framework_canceled),
            };
            self.state = .sending_body;
            return send(.body, wire);
        }

        fn pending(self: *Self) Action {
            self.state = .waiting;
            return switch (self.runtime_wake.markPending()) {
                .pending => .pending,
                .ready => .poll_ready,
                .stale => self.finishAlreadyInvalidated(.framework_canceled),
            };
        }

        fn done(self: *Self, fields: []const response_stream.TrailerField) Action {
            return switch (self.framing.framing) {
                .fixed => self.requestNormalInvalidation(.normal_exact),
                .chunked => self.prepareTerminal(fields),
                .none => self.requestFailure(.framework_canceled),
            };
        }

        fn prepareTerminal(
            self: *Self,
            fields: []const response_stream.TrailerField,
        ) Action {
            if (fields.len > response_transfer.standard_trailer_limits.fields_max) {
                return self.requestFailure(.producer_failed);
            }
            if (doneFieldsAlias(fields, self.staging)) {
                return self.requestFailure(.producer_failed);
            }
            const written = response_transfer.writeTerminal(
                response_transfer.standard_trailer_limits,
                self.staging,
                self.trailers,
                transferFields(fields),
            ) catch |problem| return self.requestFailure(mapTerminalError(problem));
            self.terminal_bytes = written.len;
            return self.requestNormalInvalidation(.normal_unknown);
        }

        fn requestNormalInvalidation(self: *Self, cleanup: Cleanup) Action {
            self.cleanup = cleanup;
            self.state = .awaiting_invalidation;
            return .{ .invalidate = self.success_outcome };
        }

        fn requestFailure(
            self: *Self,
            outcome: application.TransportOutcome,
        ) Action {
            self.cleanup = .failure;
            self.success_outcome = outcome;
            self.state = .awaiting_invalidation;
            return .{ .invalidate = outcome };
        }

        fn rejectAtInit(
            self: *Self,
            outcome: application.TransportOutcome,
        ) Action {
            if (self.framing.invoke_stream) return self.requestFailure(outcome);
            self.workspace.stream.suppress() catch unreachable;
            return self.finish(outcome);
        }

        fn joinAndFinish(self: *Self) Action {
            self.workspace.stream.join() catch unreachable;
            return self.finish(self.success_outcome);
        }

        fn joinAndSendTerminal(self: *Self) Action {
            self.workspace.stream.join() catch unreachable;
            self.state = .sending_terminal;
            return send(.terminal, self.staging[0..self.terminal_bytes]);
        }

        fn settleFailure(self: *Self) Action {
            switch (self.workspace.stream.phase()) {
                .polling, .canary, .failed => {
                    self.workspace.stream.abort() catch unreachable;
                    self.workspace.stream.join() catch unreachable;
                },
                .done, .aborted => self.workspace.stream.join() catch unreachable,
                .joined => unreachable,
            }
            return self.finish(self.success_outcome);
        }

        fn finishAlreadyInvalidated(
            self: *Self,
            outcome: application.TransportOutcome,
        ) Action {
            self.success_outcome = outcome;
            self.cleanup = .failure;
            return self.settleFailure();
        }

        fn finish(self: *Self, outcome: application.TransportOutcome) Action {
            self.success_outcome = outcome;
            self.state = .finished;
            return .{ .finished = outcome };
        }
    };
}

fn send(kind: SendKind, bytes: []const u8) Action {
    return .{ .send = .{ .kind = kind, .bytes = bytes } };
}

fn notifyProducerWake(context: *anyopaque, generation: u64) void {
    const wake: *worker_stream_wake.StreamWake = @ptrCast(@alignCast(context));
    if (wake.generation() != generation) return;
    _ = wake.notify();
}

fn successOutcomeValid(outcome: application.TransportOutcome) bool {
    return outcome == .completed or outcome == .head_suppressed;
}

fn cancelOutcomeValid(outcome: application.TransportOutcome) bool {
    return outcome == .write_stalled or
        outcome == .peer_aborted or
        outcome == .framework_canceled or
        outcome == .aborted;
}

fn transmissionValid(state: anytype) bool {
    if (state.staging.len < 6) return false;
    if (!trailerPlanValid(state.trailers)) return false;
    if (state.framing.emit_trailers != state.trailers.emitted) return false;
    if (!state.framing.invoke_stream) {
        return !state.framing.send_body and !state.framing.emit_trailers;
    }
    return switch (state.workspace.stream.framing) {
        .unknown => state.framing.send_body and state.framing.framing == .chunked and
            (!state.trailers.emitted or sameDeclarations(
                state.workspace.stream.trailerNames(),
                state.trailers.declarations,
            )),
        .exact => |expected| state.workspace.stream.trailerNames().len == 0 and
            state.framing.send_body == (expected != 0) and
            !state.trailers.emitted and switch (state.framing.framing) {
            .fixed => |actual| actual == expected,
            else => false,
        },
    };
}

fn trailerPlanValid(plan: response_transfer.TrailerPlan) bool {
    var scratch: [5]u8 = undefined;
    _ = response_transfer.writeTerminal(
        response_transfer.standard_trailer_limits,
        &scratch,
        plan,
        &.{},
    ) catch return false;
    return true;
}

fn sameDeclarations(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    if (left.len == 0) return true;
    if (left.ptr != right.ptr) return false;
    for (left, right) |left_name, right_name| {
        if (left_name.ptr != right_name.ptr or left_name.len != right_name.len) return false;
    }
    return true;
}

fn mapDriveError(problem: anyerror) application.TransportOutcome {
    return switch (problem) {
        error.ExactOverrun => .exact_overrun,
        error.ExactUnderrun => .exact_underrun,
        error.OutputTooSmall, error.InvalidLifecycle => .framework_canceled,
        else => .producer_failed,
    };
}

fn mapTerminalError(problem: response_transfer.WriteError) application.TransportOutcome {
    return switch (problem) {
        error.OutputTooSmall => .framework_canceled,
        else => .producer_failed,
    };
}

fn declarationsAlias(
    declarations: []const []const u8,
    plan: response_transfer.TrailerPlan,
    staging: []const u8,
) bool {
    if (typedSliceAliases([]const u8, declarations, staging)) return true;
    for (declarations) |name| if (bytesAlias(name, staging)) return true;
    if (typedSliceAliases([]const u8, plan.declarations, staging)) return true;
    for (plan.declarations) |name| if (bytesAlias(name, staging)) return true;
    return false;
}

fn doneFieldsAlias(
    fields: []const response_stream.TrailerField,
    staging: []const u8,
) bool {
    if (typedSliceAliases(response_stream.TrailerField, fields, staging)) return true;
    for (fields) |field| {
        if (bytesAlias(field.name, staging) or bytesAlias(field.value, staging)) return true;
    }
    return false;
}

fn typedSliceAliases(comptime T: type, values: []const T, bytes: []const u8) bool {
    if (values.len == 0) return false;
    const length = std.math.mul(usize, values.len, @sizeOf(T)) catch return true;
    return regionsOverlap(@intFromPtr(values.ptr), length, @intFromPtr(bytes.ptr), bytes.len);
}

fn bytesAlias(left: []const u8, right: []const u8) bool {
    return regionsOverlap(@intFromPtr(left.ptr), left.len, @intFromPtr(right.ptr), right.len);
}

fn regionsOverlap(left: usize, left_len: usize, right: usize, right_len: usize) bool {
    if (left_len == 0 or right_len == 0) return false;
    if (left <= right) return right - left < left_len;
    return left - right < right_len;
}

fn transferFields(
    fields: []const response_stream.TrailerField,
) []const response_transfer.TrailerField {
    comptime {
        if (@sizeOf(response_stream.TrailerField) !=
            @sizeOf(response_transfer.TrailerField) or
            @alignOf(response_stream.TrailerField) !=
                @alignOf(response_transfer.TrailerField) or
            @offsetOf(response_stream.TrailerField, "name") !=
                @offsetOf(response_transfer.TrailerField, "name") or
            @offsetOf(response_stream.TrailerField, "value") !=
                @offsetOf(response_transfer.TrailerField, "value"))
        {
            @compileError("response trailer field layouts must remain identical");
        }
    }
    const pointer: [*]const response_transfer.TrailerField = @ptrCast(fields.ptr);
    return pointer[0..fields.len];
}

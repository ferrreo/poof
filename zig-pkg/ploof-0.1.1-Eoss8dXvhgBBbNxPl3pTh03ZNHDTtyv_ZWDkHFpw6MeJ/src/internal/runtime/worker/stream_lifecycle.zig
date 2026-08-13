const reactor = @import("../reactor.zig");
const worker_stream_wake = @import("stream_wake.zig");

pub const StreamWake = worker_stream_wake.StreamWake;
pub const NotifyResult = worker_stream_wake.NotifyResult;
pub const PendingResult = worker_stream_wake.PendingResult;
pub const ClaimResult = worker_stream_wake.ClaimResult;
pub const InvalidateResult = worker_stream_wake.InvalidateResult;
pub const Error = worker_stream_wake.Error;

pub const Phase = enum(u8) {
    disabled,
    initialized,
    running,
    stopping,
    fatal,
    stopped,
    failed,
};

pub const Status = struct {
    phase: Phase,
    operations: u8,
    active_publishers: u16,
    stale_notifications: u64,
};

/// Conditionally owns one worker-local stream wake inventory. The disabled
/// branch has no storage and never opens or submits a wake source.
pub fn Lifecycle(comptime configured: bool, comptime request_slots: u16) type {
    const Wakes = worker_stream_wake.Fixed(request_slots);
    const WakeStorage = if (configured) Wakes else struct {};

    return struct {
        const Self = @This();

        pub const enabled = configured;
        pub const slots_len = request_slots;
        pub const HandleEvent = Wakes.HandleEvent;

        wakes: WakeStorage = if (configured) undefined else .{},

        pub fn init(worker_index: u16) Error!Self {
            if (comptime configured) {
                var self: Self = undefined;
                try self.wakes.init(worker_index);
                return self;
            }
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            return .{};
        }

        pub fn start(self: *Self, backend: anytype) Error!void {
            if (comptime configured) try self.wakes.start(backend);
        }

        pub fn activate(self: *Self, index: u16) Error!StreamWake {
            if (comptime configured) return self.wakes.activate(index);
            return error.InvalidPhase;
        }

        pub fn notifyIdentity(
            self: *Self,
            index: u16,
            generation: u64,
        ) NotifyResult {
            if (comptime configured) return self.wakes.notifyIdentity(index, generation);
            return .stale;
        }

        pub fn markPendingIdentity(
            self: *Self,
            index: u16,
            generation: u64,
        ) PendingResult {
            if (comptime configured) return self.wakes.markPendingIdentity(index, generation);
            return .stale;
        }

        pub fn claimReadyIdentity(
            self: *Self,
            index: u16,
            generation: u64,
        ) ClaimResult {
            if (comptime configured) return self.wakes.claimReadyIdentity(index, generation);
            return .stale;
        }

        pub fn invalidateIdentityBeforeAbort(
            self: *Self,
            index: u16,
            generation: u64,
        ) InvalidateResult {
            if (comptime configured) {
                return self.wakes.invalidateIdentityBeforeAbort(index, generation);
            }
            return .foreign;
        }

        /// Must precede producer abort and join. The returned handle is stale
        /// as soon as invalidation succeeds.
        pub fn invalidateBeforeAbort(
            self: *Self,
            wake: StreamWake,
        ) InvalidateResult {
            if (comptime configured) return self.wakes.invalidateBeforeAbort(wake);
            return .foreign;
        }

        /// Caller invokes this only after every invalidated producer has
        /// completed abort, where needed, and join.
        pub fn confirmPublishersJoined(self: *Self) Error!void {
            if (comptime configured) try self.wakes.confirmPublishersJoined();
        }

        pub fn beginStop(self: *Self, backend: anytype) Error!void {
            if (comptime configured) try self.wakes.beginStop(backend);
        }

        pub fn handle(
            self: *Self,
            backend: anytype,
            completion: reactor.Completion,
        ) Error!HandleEvent {
            if (comptime configured) return self.wakes.handle(backend, completion);
            return error.InvalidCompletion;
        }

        /// Publisher invalidation, producer abort, and producer join must all
        /// precede this transition.
        pub fn beginFatalAfterPublishersJoined(self: *Self) Error!void {
            if (comptime configured) {
                try self.wakes.beginFatalAfterPublishersJoined();
            }
        }

        /// Caller invokes this only after backend ownership is proven.
        pub fn finishFatalAfterBackend(self: *Self) Error!void {
            if (comptime configured) try self.wakes.finishFatalAfterBackend();
        }

        pub fn status(self: *const Self) Status {
            if (comptime !configured) return disabledStatus();
            return .{
                .phase = mapPhase(self.wakes.phase()),
                .operations = @as(u8, @intFromBool(self.wakes.currentPollToken() != null)) +
                    @as(u8, @intFromBool(self.wakes.currentCancelToken() != null)),
                .active_publishers = self.wakes.activeCount(),
                .stale_notifications = self.wakes.staleNotificationCount(),
            };
        }

        pub fn isStopped(self: *const Self) bool {
            const current = self.status().phase;
            return current == .disabled or current == .stopped;
        }

        pub fn currentPollToken(self: *const Self) ?reactor.OperationToken {
            if (comptime configured) return self.wakes.currentPollToken();
            return null;
        }

        pub fn currentCancelToken(self: *const Self) ?reactor.OperationToken {
            if (comptime configured) return self.wakes.currentCancelToken();
            return null;
        }
    };
}

fn disabledStatus() Status {
    return .{
        .phase = .disabled,
        .operations = 0,
        .active_publishers = 0,
        .stale_notifications = 0,
    };
}

fn mapPhase(phase: worker_stream_wake.Phase) Phase {
    return switch (phase) {
        .initialized => .initialized,
        .running => .running,
        .stopping => .stopping,
        .fatal => .fatal,
        .stopped => .stopped,
        .failed => .failed,
    };
}

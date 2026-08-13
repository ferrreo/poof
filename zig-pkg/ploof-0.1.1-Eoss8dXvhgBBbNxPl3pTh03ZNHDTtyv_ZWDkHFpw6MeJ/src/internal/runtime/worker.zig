const std = @import("std");

const forwarding = @import("../../forwarding.zig");
const lifecycle = @import("../../lifecycle.zig");
const accept_controller = @import("accept_controller.zig");
const connection_driver = @import("connection/driver.zig");
const connection_observation = @import("connection/observation.zig");
const reactor = @import("reactor.zig");
const startup_diagnostic = @import("../multipart/file_sink_startup_diagnostic.zig");
const runtime_time = @import("time.zig");
const worker_completion = @import("worker/completion.zig");
const worker_cleanup = @import("worker/cleanup.zig");
const worker_completion_route = @import("worker/completion_route.zig");
const worker_fatal = @import("worker/fatal.zig");
const worker_gzip_lifecycle = @import("worker/gzip_lifecycle.zig");
const worker_invariants = @import("worker/invariants.zig");
const worker_initialization = @import("worker/initialization.zig");
const worker_metrics = @import("worker/metrics.zig");
const worker_stream_runtime = @import("worker/stream_runtime.zig");
const worker_time = @import("worker/time.zig");

pub const MetricsSnapshot = worker_metrics.Snapshot;
pub const UploadMetricsSnapshot = worker_metrics.UploadMetricsSnapshot;
pub const UploadRouteMetricsSnapshot = @import("worker/upload_transport.zig").RouteMetricsSnapshot;
pub const Phase = worker_cleanup.Phase;

pub const Step = enum(u8) {
    progressed,
    flush_retry,
    stopped,
};

pub const LoopStatus = struct { phase: Phase, flush_pending: bool };

pub const ClockSample = struct {
    monotonic_ns: u64,
    epoch_second: i64,
};

pub const Error = error{
    InvalidApplicationConfiguration,
    InvalidWorkerIndex,
    InvalidPhase,
    FlushPending,
    InvalidClock,
    InvalidCompletion,
    ControllerFailure,
    DriverFailure,
    GzipFailure,
    StreamFailure,
    BackendFailure,
    UploadFailure,
    StaticFailure,
};

pub const FatalCleanup = worker_cleanup.FatalCleanup;
pub const CleanupStatus = worker_cleanup.Status;

pub fn Worker(comptime App: type, comptime Storage: type, comptime Reactor: type) type {
    return ConfiguredWorker(App, Storage, Reactor, forwarding.standard_limits);
}

pub fn ConfiguredWorker(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime forwarding_limits: forwarding.Limits,
) type {
    return ObservedConfiguredWorker(
        App,
        Storage,
        Reactor,
        forwarding_limits,
        connection_observation.Disabled,
    );
}

pub fn ObservedConfiguredWorker(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime forwarding_limits: forwarding.Limits,
    comptime Observation: type,
) type {
    const Driver = connection_driver.ObservedConfiguredDriver(
        App,
        Storage,
        Reactor,
        forwarding_limits,
        Observation,
    );
    const GzipLifecycle = worker_gzip_lifecycle.Lifecycle(Storage);
    const connection_capacity: usize = Storage.runtime_limits.connection_slots;
    const uploads_enabled = @hasDecl(App, "upload_async_sink_present") and
        App.upload_async_sink_present;
    const upload_registry_present = uploads_enabled or
        (@hasDecl(App, "upload_sink_present") and App.upload_sink_present);
    const UploadEntropy = if (upload_registry_present) [32]u8 else struct {};
    const Initialization = worker_initialization.Controller(
        App,
        Storage,
        Reactor,
        Error,
        Observation,
        forwarding_limits,
        upload_registry_present,
    );
    const ControlFlags = packed struct(u8) {
        draining_grace: bool = false,
        stop_accept_scheduled: bool = false,
        services_allowed: bool = true,
        services_started: bool = false,
        upload_stop_scheduled: bool = false,
        live_static_stop_scheduled: bool = false,
        padding: u2 = 0,
    };

    return struct {
        const Self = @This();
        pub const ObservationRuntime = Observation;
        const listener_slot = std.math.maxInt(u16);
        const zero_entropy: [32]u8 = @splat(0);
        const GzipSignalContext = struct { worker: *Self, now_ns: u64 };
        const StreamReadyContext = struct { worker: *Self, now_ns: u64 };

        storage: *Storage,
        io: *Reactor,
        admission_controller: ?*const lifecycle.Controller,
        controller: accept_controller.Controller,
        gzip: GzipLifecycle,
        driver: Driver,
        date_cache: runtime_time.ImfFixdateCache,
        last_date_refresh_ns: ?u64,
        last_monotonic_ns: u64,
        phase: Phase,
        flush_pending: bool,
        fatal: bool,
        control_flags: ControlFlags,
        stop_scheduling_done: bool,
        stop_cursor: u16,
        upload_entropy: UploadEntropy,
        paused_receives: [connection_capacity]bool,
        paused_receive_count: u16,
        receive_resume_credits: u16,
        receive_resume_cursor: u16,
        fatal_cleanup: FatalCleanup,
        accepted_sockets_discarded: u32,
        connection_discard_failures: u16,
        workspace_abort_attempts: u16,
        workspace_abort_failures: u16,
        metrics: worker_metrics.WorkerMetrics,

        pub const init = Initialization.init;
        pub const initForwarding = Initialization.initForwarding;
        pub const initForwardingControlled = Initialization.initForwardingControlled;

        pub fn start(self: *Self, sample: ClockSample) Error!Step {
            self.control_flags.services_allowed = true;
            return self.startBootstrap(sample);
        }

        pub fn startDeferred(self: *Self, sample: ClockSample) Error!Step {
            self.control_flags.services_allowed = false;
            return self.startBootstrap(sample);
        }

        fn startBootstrap(self: *Self, sample: ClockSample) Error!Step {
            if (self.phase != .idle) return error.InvalidPhase;
            defer if (comptime upload_registry_present) {
                std.crypto.secureZero(u8, &self.upload_entropy);
            };
            self.last_monotonic_ns = sample.monotonic_ns;
            self.driver.observation.sample(sample.monotonic_ns);
            self.refreshDate(sample) catch return error.InvalidClock;
            self.bindDate();
            _ = self.driver.beginLiveStaticRoots(sample.monotonic_ns) catch {
                return self.fail(error.StaticFailure);
            };
            const entropy = if (comptime upload_registry_present)
                &self.upload_entropy
            else
                &zero_entropy;
            const registry_start = self.driver.beginUploadRegistry(entropy, sample.monotonic_ns);
            const upload_event = registry_start catch return self.fail(error.UploadFailure);
            self.phase = .running;
            _ = upload_event;
            try self.maybeStartServices();
            return self.flushSubmitted();
        }

        pub fn handle(
            self: *Self,
            completion: reactor.Completion,
            sample: ClockSample,
        ) Error!Step {
            if (self.phase != .running and self.phase != .stopping) {
                return self.failCompletion(completion, error.InvalidPhase);
            }
            if (self.flush_pending) return self.failCompletion(completion, error.FlushPending);
            if (sample.monotonic_ns < self.last_monotonic_ns) {
                return self.failCompletion(completion, error.InvalidClock);
            }
            self.last_monotonic_ns = sample.monotonic_ns;
            self.driver.observation.sample(sample.monotonic_ns);
            const fields = completion.token.fields() catch {
                return self.failCompletion(completion, error.InvalidCompletion);
            };
            if (fields.worker_index != self.controller.worker_index) {
                return self.failCompletion(completion, error.InvalidCompletion);
            }
            if (worker_completion.acceptedSocket(completion) != null and
                !worker_completion.claimsAcceptedSocket(
                    completion,
                    fields,
                    listener_slot,
                    self.controller.generation,
                    self.controller.accept_token,
                ))
            {
                return self.failCompletion(completion, error.InvalidCompletion);
            }
            try self.routeCompletion(completion, fields, sample);
            worker_completion.record(&self.metrics, fields.kind, completion.result);
            if (self.requestWorkMayProgress() and
                worker_completion.hasBorrowedReceive(completion))
            {
                if (self.receive_resume_credits < Storage.runtime_limits.receive_buffers) {
                    self.receive_resume_credits += 1;
                }
            }
            if (self.requestWorkMayProgress()) {
                self.resumeOneReceive() catch return self.fail(error.DriverFailure);
            }
            return self.flushSubmitted();
        }

        fn routeCompletion(
            self: *Self,
            completion: reactor.Completion,
            fields: reactor.TokenFields,
            sample: ClockSample,
        ) Error!void {
            return worker_completion_route.route(
                Error,
                listener_slot,
                GzipSignalContext,
                handleGzipSignal,
                StreamReadyContext,
                handleStreamReady,
                self,
                completion,
                fields,
                sample,
            );
        }

        pub fn failBackend(self: *Self) Error {
            return self.fail(error.BackendFailure);
        }

        pub fn failClock(self: *Self, completion: reactor.Completion) Error {
            return self.failCompletion(completion, error.InvalidClock);
        }

        pub fn stop(self: *Self) Error!Step {
            switch (self.phase) {
                .idle, .running => {
                    self.phase = .stopping;
                    self.control_flags.draining_grace = false;
                    self.clearReceiveRecovery();
                },
                .stopping => if (self.control_flags.draining_grace) {
                    self.control_flags.draining_grace = false;
                    self.stop_cursor = 0;
                    self.stop_scheduling_done = false;
                    self.clearReceiveRecovery();
                },
                .stopped => return .stopped,
                .failed => return error.BackendFailure,
            }
            if (self.flush_pending) return self.retryFlush();
            return self.scheduleStop() catch |problem| self.fail(problem);
        }

        pub fn stopAt(self: *Self, sample: ClockSample) Error!Step {
            try self.observeClock(sample);
            return self.stop();
        }

        pub fn beginDrain(self: *Self) Error!Step {
            switch (self.phase) {
                .idle, .running => {
                    self.phase = .stopping;
                    self.control_flags.draining_grace = true;
                },
                .stopping => if (!self.control_flags.draining_grace) return self.stop(),
                .stopped => return .stopped,
                .failed => return error.BackendFailure,
            }
            if (self.flush_pending) return self.retryFlush();
            return self.scheduleDrain() catch |problem| self.fail(problem);
        }

        pub fn beginDrainAt(self: *Self, sample: ClockSample) Error!Step {
            try self.observeClock(sample);
            return self.beginDrain();
        }

        pub fn retryFlush(self: *Self) Error!Step {
            if (!self.flush_pending) return error.InvalidPhase;
            const step = try self.flushSubmitted();
            if (step == .flush_retry or self.phase != .stopping) return step;
            return if (self.control_flags.draining_grace)
                self.scheduleDrain() catch |problem| self.fail(problem)
            else
                self.scheduleStop() catch |problem| self.fail(problem);
        }

        pub fn cleanupStatus(self: *const Self) CleanupStatus {
            self.assertInvariants();
            return worker_cleanup.snapshot(self);
        }

        pub fn loopStatus(self: *const Self) LoopStatus {
            return .{ .phase = self.phase, .flush_pending = self.flush_pending };
        }

        pub fn reconcileStopWithExternalOperations(
            self: *Self,
            operations: [2]?reactor.OperationToken,
        ) void {
            if (operations[0] != null and operations[1] != null and
                operations[0].?.eql(operations[1].?)) return;
            var active: u8 = 0;
            for (operations) |operation| {
                const token = operation orelse continue;
                if (!self.io.tokenActive(token)) return;
                active += 1;
            }
            worker_cleanup.updateStoppedWithExternalActive(self, active);
            self.assertInvariants();
        }

        pub fn cachedDate(self: *const Self) []const u8 {
            return self.date_cache.slice();
        }

        pub fn metricsSnapshot(self: *const Self) MetricsSnapshot {
            return self.metrics.snapshot();
        }

        pub fn uploadMetricsSnapshot(self: *const Self) UploadMetricsSnapshot {
            return self.driver.uploadMetricsSnapshot();
        }

        pub fn uploadRouteMetricsSnapshot(
            self: *const Self,
            route_id: u16,
        ) ?UploadRouteMetricsSnapshot {
            return self.driver.uploadRouteMetricsSnapshot(route_id);
        }

        pub fn uploadStartupDiagnostic(self: *const Self) ?*const startup_diagnostic.Diagnostic {
            return self.driver.uploadStartupDiagnostic();
        }

        pub fn handleListenerControl(
            self: *Self,
            completion: reactor.Completion,
            now_ns: u64,
        ) !accept_controller.Event {
            const available_before = self.storage.connection_pool.available();
            const event = self.controller.handle(
                completion,
                self.storage,
                self.io,
                now_ns,
            ) catch |problem| {
                self.recordListenerAcquisitions(available_before);
                return problem;
            };
            self.recordListenerAcquisitions(available_before);
            return event;
        }

        pub fn startServices(self: *Self) Error!void {
            if (self.control_flags.services_started) return error.InvalidPhase;
            if (!self.driver.liveStaticRootsReady() or !self.driver.uploadRegistryReady()) {
                return error.InvalidPhase;
            }
            self.gzip.start(self.storage, self.io) catch {
                return self.fail(error.GzipFailure);
            };
            self.storage.stream_wakes.start(self.io) catch {
                return self.fail(error.StreamFailure);
            };
            self.controller.start(self.storage, self.io) catch {
                return self.fail(error.ControllerFailure);
            };
            self.control_flags.services_started = true;
        }

        pub fn maybeStartServices(self: *Self) Error!void {
            if (!self.control_flags.services_allowed or
                self.control_flags.services_started or self.phase != .running)
            {
                return;
            }
            if (!self.driver.liveStaticRootsReady() or !self.driver.uploadRegistryReady()) return;
            try self.startServices();
        }

        pub fn bootstrapReady(self: *const Self) bool {
            return self.phase == .running and self.driver.liveStaticRootsReady() and
                self.driver.uploadRegistryReady();
        }

        pub fn allowServices(self: *Self) Error!Step {
            if (self.phase != .running) return error.InvalidPhase;
            if (self.control_flags.services_allowed) return .progressed;
            self.control_flags.services_allowed = true;
            try self.maybeStartServices();
            return self.flushSubmitted();
        }

        pub fn startupReady(self: *const Self) bool {
            return self.phase == .running and !self.flush_pending and
                self.control_flags.services_started and self.driver.liveStaticRootsReady() and
                self.driver.uploadRegistryReady();
        }

        pub fn startupFailure(
            self: *const Self,
        ) ?@import("worker/live_static.zig").StartupDiagnostic {
            return self.driver.liveStaticStartupDiagnostic();
        }

        pub fn listenerReadyToClose(self: *const Self) bool {
            return self.controller.isStopped();
        }

        pub fn handleListenerEvent(
            self: *Self,
            event: accept_controller.Event,
            now_ns: u64,
        ) Error!void {
            switch (event) {
                .none, .stopped => {},
                .accepted => |connection_index| {
                    if (self.phase == .running and !self.fatal and self.admissionAllowed()) {
                        self.driver.start(connection_index, now_ns) catch {
                            return error.DriverFailure;
                        };
                    } else {
                        const disposition = self.driver.stop(connection_index) catch {
                            return error.DriverFailure;
                        };
                        if (disposition == .released) {
                            self.metrics.recordConnectionsClosed(1);
                        }
                    }
                },
            }
        }

        fn recordListenerAcquisitions(self: *Self, available_before: u16) void {
            const available_after = self.storage.connection_pool.available();
            std.debug.assert(available_after <= available_before);
            const acquired = available_before - available_after;
            std.debug.assert(acquired <= 1);
            if (acquired == 1) {
                self.metrics.recordConnectionAccepted(Storage.runtime_limits.connection_slots);
            }
        }

        pub fn handleConnection(
            self: *Self,
            connection_index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const disposition = self.driver.handle(completion, now_ns) catch {
                return error.DriverFailure;
            };
            self.syncPausedReceive(connection_index);
            if (disposition == .released) {
                self.metrics.recordConnectionsClosed(1);
                self.controller.capacityReturned(self.storage, self.io) catch {
                    return error.ControllerFailure;
                };
            }
        }

        fn handleGzipSignal(
            context: GzipSignalContext,
            slot_index: u16,
            signals: worker_gzip_lifecycle.Signals,
        ) connection_driver.Error!void {
            try context.worker.driver.handleGzipSignals(
                slot_index,
                signals,
                context.now_ns,
            );
        }

        fn handleStreamReady(context: StreamReadyContext, request_index: u16) Error!void {
            const available_before = context.worker.storage.connection_pool.available();
            context.worker.driver.handleStreamReady(request_index, context.now_ns) catch {
                return error.DriverFailure;
            };
            const released = try context.worker.recordGzipReleases(available_before);
            if (released != 0) context.worker.controller.capacityReturned(
                context.worker.storage,
                context.worker.io,
            ) catch return error.ControllerFailure;
        }

        pub fn recordGzipReleases(self: *Self, available_before: u16) Error!u16 {
            const available_after = self.storage.connection_pool.available();
            if (available_after < available_before) return error.DriverFailure;
            const released = available_after - available_before;
            if (released != 0) self.metrics.recordConnectionsClosed(released);
            return released;
        }

        fn scheduleStop(self: *Self) Error!Step {
            if (!self.control_flags.stop_accept_scheduled) {
                self.controller.stop(self.io) catch return error.ControllerFailure;
                self.control_flags.stop_accept_scheduled = true;
                const step = try self.flushSubmitted();
                if (step == .flush_retry) return step;
            }

            while (self.stop_cursor < Storage.runtime_limits.connection_slots) {
                const connection_index = self.stop_cursor;
                self.stop_cursor += 1;
                if (self.storage.connections[connection_index].phase == .free) continue;
                const disposition = self.driver.stop(connection_index) catch {
                    return error.DriverFailure;
                };
                if (disposition == .released) self.metrics.recordConnectionsClosed(1);
                self.syncPausedReceive(connection_index);
                const step = try self.flushSubmitted();
                if (step == .flush_retry) return step;
            }
            self.stop_scheduling_done = true;
            return self.flushSubmitted();
        }

        fn scheduleDrain(self: *Self) Error!Step {
            if (!self.control_flags.stop_accept_scheduled) {
                self.controller.stop(self.io) catch return error.ControllerFailure;
                self.control_flags.stop_accept_scheduled = true;
                const step = try self.flushSubmitted();
                if (step == .flush_retry) return step;
            }
            while (self.stop_cursor < Storage.runtime_limits.connection_slots) {
                const connection_index = self.stop_cursor;
                self.stop_cursor += 1;
                if (self.storage.connections[connection_index].phase == .free) continue;
                const disposition = self.driver.beginDrain(connection_index) catch {
                    return error.DriverFailure;
                };
                if (disposition == .released) self.metrics.recordConnectionsClosed(1);
                self.syncPausedReceive(connection_index);
                const step = try self.flushSubmitted();
                if (step == .flush_retry) return step;
            }
            self.stop_scheduling_done = true;
            return self.flushSubmitted();
        }

        fn resumeOneReceive(self: *Self) Error!void {
            if (self.receive_resume_credits == 0) return;
            if (self.paused_receive_count == 0) return;
            var checked: u16 = 0;
            while (checked < Storage.runtime_limits.connection_slots) : (checked += 1) {
                const index: usize = self.receive_resume_cursor;
                self.receive_resume_cursor = @intCast(
                    (index + 1) % self.storage.connections.len,
                );
                if (!self.paused_receives[index]) continue;
                const resumed = self.driver.resumeReceive(@intCast(index)) catch {
                    return error.DriverFailure;
                };
                self.syncPausedReceive(@intCast(index));
                if (resumed) {
                    std.debug.assert(self.receive_resume_credits != 0);
                    self.receive_resume_credits -= 1;
                    return;
                }
            }
        }

        pub fn syncPausedReceive(self: *Self, connection_index: u16) void {
            const connection = &self.storage.connections[connection_index];
            const should_track = self.requestWorkMayProgress() and
                connection.phase != .free and connection.phase != .closing and
                connection.receive_flags.paused;
            const tracked = self.paused_receives[connection_index];
            if (tracked == should_track) return;

            self.paused_receives[connection_index] = should_track;
            if (should_track) {
                std.debug.assert(self.paused_receive_count < connection_capacity);
                self.paused_receive_count += 1;
            } else {
                std.debug.assert(self.paused_receive_count != 0);
                self.paused_receive_count -= 1;
            }
        }

        fn clearReceiveRecovery(self: *Self) void {
            self.paused_receives = [_]bool{false} ** connection_capacity;
            self.paused_receive_count = 0;
            self.receive_resume_credits = 0;
        }

        fn requestWorkMayProgress(self: *const Self) bool {
            return self.phase == .running or
                (self.phase == .stopping and self.control_flags.draining_grace);
        }

        fn flushSubmitted(self: *Self) Error!Step {
            if (self.phase == .stopping and self.stop_scheduling_done and
                self.storage.request_pool.available() == self.storage.requests.len)
            {
                self.gzip.beginStop(self.storage, self.io) catch {
                    return self.fail(error.GzipFailure);
                };
                worker_stream_runtime.beginStop(self.storage, self.io) catch {
                    return self.fail(error.StreamFailure);
                };
                if (!self.control_flags.live_static_stop_scheduled) {
                    _ = self.driver.beginLiveStaticStop() catch {
                        return self.fail(error.StaticFailure);
                    };
                    self.control_flags.live_static_stop_scheduled = true;
                }
                if (!self.control_flags.upload_stop_scheduled and
                    self.driver.uploadRegistryReady())
                {
                    const event = self.driver.stopUploadRegistry(self.last_monotonic_ns) catch {
                        return self.fail(error.UploadFailure);
                    };
                    if (event != .none and event != .registry_stopped) {
                        return self.fail(error.UploadFailure);
                    }
                    self.control_flags.upload_stop_scheduled = true;
                }
            }
            _ = self.io.flush() catch |problem| {
                if (problem == error.SubmissionRetry) {
                    self.flush_pending = true;
                    self.assertInvariants();
                    return .flush_retry;
                }
                return self.fail(error.BackendFailure);
            };
            self.flush_pending = false;
            worker_cleanup.updateStopped(self);
            self.assertInvariants();
            return if (self.phase == .stopped) .stopped else .progressed;
        }

        pub fn refreshDate(self: *Self, sample: ClockSample) Error!void {
            return worker_time.refresh(self, sample);
        }

        fn observeClock(self: *Self, sample: ClockSample) Error!void {
            if (sample.monotonic_ns < self.last_monotonic_ns) return error.InvalidClock;
            self.last_monotonic_ns = sample.monotonic_ns;
            self.driver.observation.sample(sample.monotonic_ns);
            try self.refreshDate(sample);
            self.bindDate();
        }

        pub fn bindDate(self: *Self) void {
            worker_time.bind(self);
        }

        fn enterFatal(self: *Self) void {
            if (!self.fatal) self.metrics.recordFatalTransition();
            self.fatal = true;
            self.clearReceiveRecovery();
            if (self.phase != .stopped and self.phase != .failed) self.phase = .stopping;
        }

        fn admissionAllowed(self: *const Self) bool {
            const controller = self.admission_controller orelse return true;
            return controller.isReady();
        }

        fn emergencyAbort(self: *Self) void {
            worker_fatal.emergencyAbort(App, self);
        }

        pub fn fail(self: *Self, problem: Error) Error {
            self.enterFatal();
            self.emergencyAbort();
            self.assertInvariants();
            return problem;
        }

        fn failCompletion(self: *Self, completion: reactor.Completion, problem: Error) Error {
            if (worker_completion.acceptedSocket(completion)) |socket| {
                self.metrics.recordConnectionAccepted(Storage.runtime_limits.connection_slots);
                self.io.discard(socket) catch return self.failProcessExit(problem);
                self.accepted_sockets_discarded +|= 1;
                self.metrics.recordConnectionsClosed(1);
            }
            return self.fail(problem);
        }

        pub fn failProcessExit(self: *Self, problem: Error) Error {
            self.enterFatal();
            self.emergencyAbort();
            self.fatal_cleanup = .process_exit_required;
            self.phase = .failed;
            self.assertInvariants();
            return problem;
        }

        fn assertInvariants(self: *const Self) void {
            worker_invariants.check(self, Storage);
        }
    };
}

const std = @import("std");

const forwarding = @import("forwarding.zig");
const lifecycle = @import("lifecycle.zig");
const startup = @import("startup.zig");
const startup_api = @import("server/startup.zig");
const buffer_ring = @import("internal/runtime/buffer_ring.zig");
const event_counter = @import("internal/runtime/event_counter.zig");
const futex_epoch = @import("internal/runtime/futex_epoch.zig");
const io_uring_backend = @import("internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("internal/runtime/listener.zig");
const memory_budget = @import("internal/runtime/memory_budget.zig");
const runtime_config = @import("internal/runtime/config.zig");
const runtime_capacity = @import("internal/runtime/runtime_capacity.zig");
const server_clock = @import("internal/runtime/server/clock.zig");
const server_command = @import("internal/runtime/server/command.zig");
const server_mutex = @import("internal/runtime/server/mutex.zig");
const server_metrics_runtime = @import("internal/runtime/server/metrics_runtime.zig");
const server_metrics_binding = @import("internal/runtime/server/metrics_binding.zig");
const connection_observation = @import("internal/runtime/connection/observation.zig");
const server_observability = @import("internal/runtime/server/observability.zig");
const server_shutdown_runtime = @import("internal/runtime/server/shutdown_runtime.zig");
const server_signal = @import("internal/runtime/server/signal.zig");
const server_status = @import("internal/runtime/server/status.zig");
const server_worker = @import("internal/runtime/server/worker.zig");
const server_types = @import("server/types.zig");
const worker_runtime = @import("internal/runtime/worker.zig");
const worker_storage = @import("internal/runtime/worker/storage.zig");

pub const standard_worker_thread_stack_bytes =
    server_types.standard_worker_thread_stack_bytes;
pub const Options = server_types.Options;
pub const AccessLogOptions = server_types.AccessLogOptions;
pub const OpenMetricsOptions = server_types.OpenMetricsOptions;
pub const StartConfig = server_types.StartConfig;
pub const ShutdownResult = server_types.ShutdownResult;
pub const ShutdownError = server_types.ShutdownError;
pub const SignalShutdownError = ShutdownError || server_signal.Error;
pub const MetricsError = server_metrics_runtime.Error;

const NodeStatus = enum(u8) {
    empty,
    initializing,
    bootstrapped,
    ready,
    startup_failed,
    stopped,
    runtime_failed,
};

/// Builds a caller-owned server whose complete bounded worker storage is fixed
/// at compile time. The value must remain at one address from `start` onward.
/// A global declaration must spell `align(@alignOf(ServerType))` so its worker
/// cache lines retain the type's required alignment through the linker.
pub fn Server(comptime App: type, comptime requested_options: Options) type {
    const options = server_types.validated(requested_options);
    const limits = runtime_config.Limits.validate(options.limits);
    const ForwardingProfile = forwarding.Profile(options.forwarding_limits);
    const ReceiveBuffers = buffer_ring.BufferRing(
        limits.receive_buffers,
        limits.receive_buffer_bytes,
        options.receive_buffer_group,
    );
    const file_inputs = runtime_capacity.Inputs{
        .connection_slots = @as(u32, limits.connection_slots),
        .body_workspace_slots = @as(u32, limits.body_workspace_slots),
        .upload_window_max = @as(u32, App.upload_window_max),
        .request_handles_max = @as(u32, App.upload_request_handles_max),
        .runtime_handles_max = @as(u32, App.upload_runtime_handles_max),
        .async_sink_present = App.upload_async_sink_present,
        .live_static_slots = @as(u32, App.live_static_slots_per_worker),
        .live_static_roots = @as(u32, App.live_static_root_count),
    };
    const Backend = io_uring_backend.IoUringBackendWithFiles(
        limits,
        ReceiveBuffers,
        file_inputs,
    );
    const Storage = worker_storage.Storage(App, limits);
    const Observability = server_observability.Runtime(
        App,
        options.workers_max,
        limits.request_slots,
        options.access_log,
    );
    const Observation = connection_observation.Binding(Observability.ObservationController);
    const Worker = worker_runtime.ObservedConfiguredWorker(
        App,
        Storage,
        Backend,
        options.forwarding_limits,
        Observation,
    );
    const slab_storage_bytes = Storage.required_bytes + Storage.slab_alignment - 1;

    return struct {
        const Self = @This();
        const MetricsBinding = server_metrics_binding.Binding(App, Self);
        const Node = struct {
            status: std.atomic.Value(NodeStatus) = .init(.empty),
            listener: listener_runtime.Listener = undefined,
            command: server_command.Channel = undefined,
            receive_buffers: ReceiveBuffers.Buffers = undefined,
            backend: Backend = undefined,
            storage: Storage = undefined,
            slab: [slab_storage_bytes]u8 = undefined,
            worker: Worker = undefined,
            clock: server_clock.Clock = .{},
            thread: ?std.Thread = null,
            failure: startup_api.WorkerFailure = undefined,
            published: server_status.Published = .{},
            observation: Observability.ObservationController = undefined,
        };
        lifecycle_controller: lifecycle.Controller = .{},
        startup_event: futex_epoch.Event = .{},
        startup_control_event: futex_epoch.Event = .{},
        shutdown_mutex: server_mutex.Mutex = .{},
        shutdown_call_mutex: server_mutex.Mutex = .{},
        commands_ready: std.atomic.Value(bool) = .init(false),
        startup_done: std.atomic.Value(bool) = .init(false),
        shutdown_deadlines_set: std.atomic.Value(bool) = .init(false),
        grace_deadline_ns: std.atomic.Value(u64) = .init(0),
        force_deadline_ns: std.atomic.Value(u64) = .init(0),
        forwarding_profile: ForwardingProfile = undefined,
        observability: Observability = .{},
        metrics: MetricsBinding = .{},
        completion: event_counter.Counter = undefined,
        nodes: [options.workers_max]Node = undefined,
        shutdown_profile: lifecycle.ShutdownProfile = .{},
        readiness_binding: ?*lifecycle.Readiness = null,
        bound_address: listener_runtime.Address = undefined,
        address_identity: usize = 0,
        worker_count: u16 = 0,
        configured_count: u16 = 0,
        thread_count: u16 = 0,
        completion_live: std.atomic.Value(bool) = .init(false),
        start_attempted: std.atomic.Value(bool) = .init(false),
        shutdown_finalized: bool = false,
        shutdown_final_report: lifecycle.ShutdownIncomplete = .{
            .remaining = .{},
            .dropped_access_events = 0,
        },

        pub const compiled_options = options;
        pub const runtime_limits = limits;
        pub const StartResult = startup_api.Result;
        pub const StartupFailure = startup_api.Failure;
        pub const MetricsSnapshot = Observability.Snapshot;

        pub fn init() Self {
            return .{};
        }

        pub fn phase(self: *const Self) lifecycle.Phase {
            self.assertStableAddressIfStarted();
            return self.lifecycle_controller.phase();
        }

        pub fn drainStage(self: *const Self) lifecycle.DrainStage {
            self.assertStableAddressIfStarted();
            return self.lifecycle_controller.drainStage();
        }

        pub fn isReady(self: *const Self) bool {
            return self.phase() == .ready;
        }

        pub fn address(self: *const Self) ?listener_runtime.Address {
            return if (self.isReady()) self.bound_address else null;
        }

        pub const metricsSnapshot = server_metrics_binding.snapshot;
        pub const __publishMetrics = server_metrics_binding.publish;

        pub fn start(
            self: *Self,
            state: *App.StateType,
            config: StartConfig,
        ) StartResult {
            self.shutdown_mutex.lock();
            if (self.start_attempted.load(.acquire)) {
                self.shutdown_mutex.unlock();
                return failureResult(.{ .configuration = .server_already_started });
            }
            self.address_identity = @intFromPtr(self);
            self.start_attempted.store(true, .release);
            defer self.finishStartupAttempt();
            if (config.worker_count == 0) {
                _ = self.lifecycle_controller.markFailed();
                self.shutdown_mutex.unlock();
                return failureResult(.{ .configuration = .worker_count_zero });
            }
            if (config.worker_count > options.workers_max) {
                _ = self.lifecycle_controller.markFailed();
                self.shutdown_mutex.unlock();
                return failureResult(.{
                    .configuration = .worker_count_above_compiled_max,
                });
            }
            if (config.shutdown.issue() != null) {
                _ = self.lifecycle_controller.markFailed();
                self.shutdown_mutex.unlock();
                return failureResult(.{
                    .configuration = .shutdown_duration_overflow,
                });
            }
            if (options.access_log.enabled and config.access_log_descriptor == null) {
                _ = self.lifecycle_controller.markFailed();
                self.shutdown_mutex.unlock();
                return failureResult(.{
                    .configuration = .access_log_descriptor_required,
                });
            }
            if (!options.access_log.enabled and config.access_log_descriptor != null) {
                _ = self.lifecycle_controller.markFailed();
                self.shutdown_mutex.unlock();
                return failureResult(.{
                    .configuration = .access_log_descriptor_unexpected,
                });
            }
            self.readiness_binding = config.readiness;
            self.shutdown_profile = config.shutdown;
            self.shutdown_mutex.unlock();
            switch (startup.checkApplication(App, state)) {
                .ready => {},
                .failure => |problem| {
                    return self.failBeforeThreads(.{ .application = problem });
                },
            }
            switch (ForwardingProfile.initDetailed(config.forwarding)) {
                .profile => |profile| self.forwarding_profile = profile,
                .failure => |problem| {
                    return self.failBeforeThreads(.{ .forwarding = problem });
                },
            }
            switch (startup.check(App, .{ .ring = .{
                .submission_entries = limits.submission_entries,
                .completion_entries = limits.completion_entries,
            } })) {
                .ready => {},
                .failure => |problem| {
                    return self.failBeforeThreads(.{ .capability = problem });
                },
            }
            return self.startChecked(state, config);
        }

        pub fn beginDrain(self: *Self) ShutdownError!lifecycle.Transition {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            if (!self.start_attempted.load(.acquire)) return error.ServerNotRunning;
            self.assertStableAddress();
            return self.beginDrainLocked();
        }

        pub fn beginForced(self: *Self) ShutdownError!lifecycle.Transition {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            if (!self.start_attempted.load(.acquire)) return error.ServerNotRunning;
            self.assertStableAddress();
            return self.beginForcedLocked();
        }

        pub fn __notifyWorkerFailure(self: *Self) void {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            self.assertStableAddress();
            self.ensureShutdownDeadlines() catch self.setImmediateShutdownDeadlines();
            _ = self.lifecycle_controller.beginDrain();
            _ = self.lifecycle_controller.beginForced();
            self.metrics.requestStop();
            if (self.commands_ready.load(.acquire)) self.publishCommand(.force) catch {};
            self.startup_control_event.notify();
            if (self.completion_live.load(.acquire)) _ = self.completion.signal();
        }

        pub fn shutdown(self: *Self) ShutdownError!ShutdownResult {
            return self.shutdownInternal(false, {});
        }

        pub fn shutdownSignaled(
            self: *Self,
            source: *server_signal.Source,
        ) SignalShutdownError!ShutdownResult {
            return self.shutdownInternal(true, source);
        }

        fn shutdownInternal(
            self: *Self,
            comptime signaled: bool,
            source: if (signaled) *server_signal.Source else void,
        ) (if (signaled) SignalShutdownError else ShutdownError)!ShutdownResult {
            const ErrorType = if (signaled) SignalShutdownError else ShutdownError;
            return server_shutdown_runtime.shutdown(
                ErrorType,
                self,
                signaled,
                source,
                Self.assertStableAddress,
                Self.beginDrainLocked,
                Self.shutdownDeadlines,
                Self.waitForStartup,
                Self.startupIncomplete,
            );
        }

        pub fn shutdownReport(self: *const Self) lifecycle.ShutdownIncomplete {
            self.assertStableAddress();
            return server_shutdown_runtime.report(self);
        }

        fn startChecked(
            self: *Self,
            state: *App.StateType,
            config: StartConfig,
        ) StartResult {
            self.worker_count = config.worker_count;
            self.completion = switch (event_counter.Counter.open()) {
                .opened => |counter| counter,
                .failed => return self.failBeforeThreads(.{
                    .completion_counter = error.CompletionCounterOpenFailed,
                }),
            };
            self.completion_live.store(true, .release);
            self.observability.startLogger(config.access_log_descriptor) catch |problem| {
                self.closeCompletion();
                return self.failBeforeThreads(.{ .access_logger = problem });
            };
            if (self.configureNodes(config.listener)) |problem| {
                return self.failConfigured(problem);
            }
            if (self.enableCommands()) |problem| return self.failConfigured(problem);
            if (self.spawnNodes(state)) |problem| return self.failSpawned(problem);
            if (self.awaitBootstrap()) |problem| return self.failSpawned(problem);
            if (self.startMetrics()) |problem| return self.failSpawned(problem);
            const runtime_memory = memory_budget.report(
                Worker,
                Storage,
                Backend,
                &self.nodes[0].backend,
                self.worker_count,
            ) catch |problem| {
                return self.failSpawned(.{ .memory_budget = problem });
            };
            if (self.releaseServices()) |problem| return self.failSpawned(problem);
            if (self.awaitStartup()) |problem| return self.failSpawned(problem);
            if (self.completeReadiness()) |problem| return self.failSpawned(problem);
            return .{ .ready = .{
                .address = self.bound_address,
                .worker_count = self.worker_count,
                .memory = .{
                    .runtime = runtime_memory,
                    .server_value_bytes = @sizeOf(Self),
                    .application_route_index_static_bytes = if (@hasDecl(
                        App,
                        "route_index_static_bytes",
                    )) App.route_index_static_bytes else 0,
                    .worker_thread_requested_stack_bytes = options.worker_thread_stack_bytes,
                    .process_worker_thread_requested_stack_bytes = @as(
                        u64,
                        options.worker_thread_stack_bytes,
                    ) * self.worker_count,
                },
            } };
        }

        fn configureNodes(
            self: *Self,
            requested_listener: listener_runtime.Config,
        ) ?StartupFailure {
            var listener_config = requested_listener;
            for (self.nodes[0..self.worker_count], 0..) |*node, index| {
                node.* = .{};
                node.status.store(.initializing, .monotonic);
                node.observation = self.observability.initObservation(@intCast(index));
                node.command = server_command.Channel.init(@intCast(index)) catch |problem| {
                    return workerFailure(@intCast(index), .command, problem, .clean);
                };
                const opened = listener_runtime.open(listener_config);
                node.listener = switch (opened) {
                    .listener => |value| value,
                    .failure => |problem| {
                        node.command.abortAfterBackend();
                        return .{ .listener = .{
                            .worker_index = @intCast(index),
                            .problem = problem,
                        } };
                    },
                };
                self.configured_count += 1;
                if (index == 0) {
                    self.bound_address = node.listener.bound_address;
                    listener_config.address = self.bound_address;
                }
            }
            return null;
        }

        fn spawnNodes(self: *Self, state: *App.StateType) ?StartupFailure {
            for (self.nodes[0..self.worker_count], 0..) |*node, index| {
                node.thread = std.Thread.spawn(
                    .{ .stack_size = options.worker_thread_stack_bytes },
                    workerMain,
                    .{ self, state, @as(u16, @intCast(index)) },
                ) catch |problem| {
                    return workerFailure(@intCast(index), .thread, problem, .clean);
                };
                self.thread_count += 1;
            }
            return null;
        }

        fn enableCommands(self: *Self) ?StartupFailure {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            self.commands_ready.store(true, .release);
            const stage = self.lifecycle_controller.drainStage();
            const command: server_command.Command = switch (stage) {
                .none => return null,
                .grace => .drain,
                .forced => .force,
            };
            self.publishCommand(command) catch |problem| {
                return workerFailure(0, .command, problem, .clean);
            };
            return null;
        }

        fn releaseServices(self: *Self) ?StartupFailure {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            if (self.lifecycle_controller.phase() != .starting) {
                return .{ .configuration = .startup_interrupted };
            }
            self.publishCommand(.serve) catch |problem| {
                return workerFailure(0, .command, problem, .clean);
            };
            return null;
        }

        fn completeReadiness(self: *Self) ?StartupFailure {
            self.shutdown_mutex.lock();
            defer self.shutdown_mutex.unlock();
            if (self.lifecycle_controller.phase() != .starting) {
                return .{ .configuration = .startup_interrupted };
            }
            if (self.readiness_binding) |readiness| {
                readiness.bind(&self.lifecycle_controller) catch {
                    return .{ .configuration = .readiness_already_bound };
                };
            }
            if (self.lifecycle_controller.markReady() != .advanced) {
                return .{ .configuration = .startup_interrupted };
            }
            return null;
        }

        fn startMetrics(self: *Self) ?StartupFailure {
            self.metrics.start(self, options.open_metrics.thread_stack_bytes) catch |problem| {
                return .{ .metrics_service = problem };
            };
            return null;
        }

        fn workerMain(self: *Self, state: *App.StateType, worker_index: u16) void {
            server_worker.main(App, self, state, worker_index);
        }

        fn awaitBootstrap(self: *Self) ?StartupFailure {
            return self.awaitNodeStatus(.bootstrapped);
        }

        fn awaitStartup(self: *Self) ?StartupFailure {
            return self.awaitNodeStatus(.ready);
        }

        fn awaitNodeStatus(self: *Self, wanted: NodeStatus) ?StartupFailure {
            while (true) {
                const observed = self.startup_event.observe();
                var reported: u16 = 0;
                var failure: ?StartupFailure = null;
                for (self.nodes[0..self.thread_count]) |*node| {
                    switch (node.status.load(.acquire)) {
                        .ready => reported += 1,
                        .bootstrapped => if (wanted == .bootstrapped) {
                            reported += 1;
                        },
                        .startup_failed, .runtime_failed => {
                            reported += 1;
                            if (failure == null) failure = .{ .worker = node.failure };
                        },
                        .stopped => {
                            reported += 1;
                            if (failure == null) {
                                failure = workerFailure(
                                    node.worker.controller.worker_index,
                                    .start,
                                    error.WorkerStoppedDuringStartup,
                                    .clean,
                                );
                            }
                        },
                        .empty, .initializing => {},
                    }
                }
                if (reported == self.thread_count) return failure;
                if (self.startup_event.arm(observed)) self.startup_event.wait(observed);
            }
        }

        fn failBeforeThreads(self: *Self, failure: StartupFailure) StartResult {
            if (self.lifecycle_controller.phase() == .draining) {
                _ = self.lifecycle_controller.markStopped();
            } else {
                _ = self.lifecycle_controller.markFailed();
            }
            return failureResult(failure);
        }

        fn failConfigured(self: *Self, failure: StartupFailure) StartResult {
            self.commands_ready.store(false, .release);
            self.closeUnthreaded(0);
            self.closeCompletion();
            if (!server_shutdown_runtime.stopLoggerUntil(
                self,
                self.startupCleanupDeadline(),
            )) {
                return self.failBeforeThreads(workerFailure(
                    0,
                    .start,
                    error.AccessLoggerCleanupIncomplete,
                    .process_exit_required,
                ));
            }
            return self.failBeforeThreads(failure);
        }

        fn failSpawned(self: *Self, failure: StartupFailure) StartResult {
            self.closeUnthreaded(self.thread_count);
            self.metrics.requestStop();
            if (self.lifecycle_controller.phase() == .draining) {
                _ = self.lifecycle_controller.beginForced();
            }
            for (self.nodes[0..self.thread_count]) |*node| {
                _ = node.command.publish(.force) catch {};
            }
            const end_ns = self.startupCleanupDeadline();
            const workers_terminal = server_shutdown_runtime.waitForTerminal(
                self,
                end_ns,
            ) catch false;
            const cleanup_complete = workers_terminal and
                server_shutdown_runtime.stopMetricsUntil(self, end_ns) and
                server_shutdown_runtime.stopLoggerUntil(self, end_ns);
            if (cleanup_complete) {
                server_shutdown_runtime.joinThreads(self);
                self.closeCompletion();
            }
            if (self.lifecycle_controller.phase() == .draining) {
                if (cleanup_complete) _ = self.lifecycle_controller.markStopped();
            } else {
                _ = self.lifecycle_controller.markFailed();
            }
            if (!cleanup_complete) {
                return failureResult(workerFailure(
                    0,
                    .start,
                    error.StartupCleanupIncomplete,
                    .process_exit_required,
                ));
            }
            return failureResult(failure);
        }

        fn closeUnthreaded(self: *Self, first: u16) void {
            for (self.nodes[first..self.configured_count]) |*node| {
                _ = node.listener.close();
                node.command.abortAfterBackend();
                node.status.store(.startup_failed, .release);
            }
            self.configured_count = first;
        }

        fn closeCompletion(self: *Self) void {
            if (!self.completion_live.swap(false, .acq_rel)) return;
            _ = self.completion.close();
        }

        fn publishCommand(self: *Self, command: server_command.Command) !void {
            for (self.nodes[0..self.configured_count]) |*node| {
                const status = node.status.load(.acquire);
                switch (status) {
                    .startup_failed, .stopped, .runtime_failed => continue,
                    .empty, .initializing, .bootstrapped, .ready => {},
                }
                _ = try node.command.publish(command);
            }
        }

        fn assertStableAddress(self: *const Self) void {
            if (!self.start_attempted.load(.acquire) or
                self.address_identity != @intFromPtr(self))
            {
                @panic("PLOOF Server moved after start");
            }
        }

        fn assertStableAddressIfStarted(self: *const Self) void {
            if (self.start_attempted.load(.acquire)) self.assertStableAddress();
        }

        fn beginDrainLocked(self: *Self) ShutdownError!lifecycle.Transition {
            const phase_before = self.lifecycle_controller.phase();
            const transition: lifecycle.Transition = switch (phase_before) {
                .starting, .ready => transition: {
                    try self.ensureShutdownDeadlines();
                    break :transition self.lifecycle_controller.beginDrain();
                },
                .draining => if (self.lifecycle_controller.drainStage() == .grace)
                    .unchanged
                else
                    return .unchanged,
                .stopped, .failed => return .unchanged,
            };
            self.metrics.requestStop();
            if (self.commands_ready.load(.acquire)) {
                try self.publishCommand(.drain);
            }
            return transition;
        }

        fn beginForcedLocked(self: *Self) ShutdownError!lifecycle.Transition {
            const stage_before = self.lifecycle_controller.drainStage();
            if (stage_before == .none) return .unchanged;
            const transition = if (stage_before == .grace)
                self.lifecycle_controller.beginForced()
            else
                lifecycle.Transition.unchanged;
            if (self.commands_ready.load(.acquire)) {
                try self.publishCommand(.force);
            }
            self.startup_control_event.notify();
            if (self.completion_live.load(.acquire) and self.completion.signal() != null) {
                return error.CompletionCounterFailed;
            }
            return transition;
        }

        fn ensureShutdownDeadlines(self: *Self) ShutdownError!void {
            if (self.shutdown_deadlines_set.load(.acquire)) return;
            const bounds = try lifecycle.deadlines(
                try server_clock.monotonicNow(),
                self.shutdown_profile,
            );
            self.grace_deadline_ns.store(bounds.grace_ns, .monotonic);
            self.force_deadline_ns.store(bounds.force_ns, .monotonic);
            self.shutdown_deadlines_set.store(true, .release);
        }

        fn setImmediateShutdownDeadlines(self: *Self) void {
            self.grace_deadline_ns.store(0, .monotonic);
            self.force_deadline_ns.store(0, .monotonic);
            self.shutdown_deadlines_set.store(true, .release);
        }

        fn shutdownDeadlines(self: *const Self) lifecycle.Deadlines {
            if (!self.shutdown_deadlines_set.load(.acquire)) {
                @panic("PLOOF shutdown deadlines missing");
            }
            return .{
                .grace_ns = self.grace_deadline_ns.load(.monotonic),
                .force_ns = self.force_deadline_ns.load(.monotonic),
            };
        }

        fn startupCleanupDeadline(self: *const Self) u64 {
            if (self.shutdown_deadlines_set.load(.acquire)) {
                return self.force_deadline_ns.load(.monotonic);
            }
            const now_ns = server_clock.monotonicNow() catch return 0;
            return std.math.add(u64, now_ns, self.shutdown_profile.force_ns) catch
                std.math.maxInt(u64);
        }

        fn finishStartupAttempt(self: *Self) void {
            self.startup_done.store(true, .release);
            self.startup_control_event.notify();
        }

        fn waitForStartup(self: *Self, bounds: lifecycle.Deadlines) ShutdownError!bool {
            while (!self.startup_done.load(.acquire)) {
                const forced = self.lifecycle_controller.drainStage() == .forced;
                const deadline_ns = if (forced) bounds.force_ns else bounds.grace_ns;
                if (try self.waitStartupUntil(deadline_ns, !forced)) return true;
                if (forced) return false;
                _ = try self.beginForced();
            }
            return true;
        }

        fn waitStartupUntil(
            self: *Self,
            deadline_ns: u64,
            stop_on_forced: bool,
        ) server_clock.Error!bool {
            while (!self.startup_done.load(.acquire)) {
                const now_ns = try server_clock.monotonicNow();
                if (now_ns >= deadline_ns) return false;
                const observed = self.startup_control_event.observe();
                if (self.startup_done.load(.acquire) or
                    (stop_on_forced and self.lifecycle_controller.drainStage() == .forced))
                {
                    return self.startup_done.load(.acquire);
                }
                if (!self.startup_control_event.arm(observed)) continue;
                switch (self.startup_control_event.waitFor(observed, deadline_ns - now_ns)) {
                    .notified, .interrupted => continue,
                    .timed_out => return self.startup_done.load(.acquire),
                }
            }
            return true;
        }

        fn startupIncomplete(self: *const Self) ShutdownResult {
            _ = self;
            return .{ .incomplete = .{
                .remaining = .{ .workers = 1 },
                .dropped_access_events = 0,
            } };
        }
    };
}

fn failureResult(failure: startup_api.Failure) startup_api.Result {
    return .{ .failure = failure };
}

fn workerFailure(
    worker_index: u16,
    stage: startup_api.WorkerStage,
    problem: anyerror,
    cleanup: startup_api.Cleanup,
) startup_api.Failure {
    return .{ .worker = .{
        .worker_index = worker_index,
        .stage = stage,
        .problem = problem,
        .cleanup = cleanup,
    } };
}

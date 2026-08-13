const std = @import("std");

const multipart = @import("../../../multipart/upload.zig");
const startup_diagnostic = @import("../../multipart/file_sink_startup_diagnostic.zig");
const multipart_finalization = @import("../../application/multipart_finalization.zig");
const multipart_parser = @import("../../multipart/parser.zig");
const upload_finalizer = @import("../../upload/finalizer.zig");
const reactor = @import("../reactor.zig");
const upload_transport = @import("../upload/transport.zig");
const request_controller = @import("upload_request_controller.zig");
const request_failure = @import("upload_request_failure.zig");
const disabled_controller = @import("upload_disabled_controller.zig");
const runtime_registry = @import("upload_runtime_registry.zig");
const runtime_deadline = @import("upload_runtime_deadline.zig");
const worker_metrics = @import("metrics.zig");
const route_metrics = @import("upload_route_metrics.zig");
const metrics_record = @import("upload_metrics_record.zig");

pub const RouteMetricsSnapshot = route_metrics.Snapshot;
pub const RejectionStatus = request_failure.RejectionStatus;

pub const Error = error{
    ApplicationFailure,
    BackendFailure,
    InvalidRequest,
    InvalidWorkerIndex,
    StateInvariant,
    TransportFailure,
};

pub const Resume = struct {
    connection_index: u16,
    request_index: u16,
    progress: multipart_parser.Progress,
};

pub const Finalized = struct {
    connection_index: u16,
    request_index: u16,
    report: multipart_finalization.Report,
    response_failed: bool,
};

pub const Rejected = struct {
    connection_index: u16,
    request_index: u16,
    status: RejectionStatus,
};

pub const Phase = enum(u8) {
    idle,
    starting,
    rolling_back,
    ready,
    stopping,
    stopped,
    failed,
};

pub const Event = union(enum) {
    none,
    registry_ready,
    registry_stopped,
    request_resumed: Resume,
    request_rejected: Rejected,
    request_finalized: Finalized,
};

pub const StartupDiagnostic = startup_diagnostic.Diagnostic;

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
) type {
    const enabled = @hasDecl(App, "upload_async_sink_present") and
        App.upload_async_sink_present;
    if (!enabled) return disabled_controller.Controller(App, Storage, Error, Event);
    if (!@hasDecl(Reactor, "file_handle_capacity") or
        !@hasDecl(Reactor, "file_target_capacity"))
    {
        @compileError("PLOOF-E3523 upload application requires upload-capable reactor");
    }
    if (Reactor.file_target_capacity == 0) {
        @compileError("PLOOF-E3524 upload reactor target capacity must be positive");
    }

    const RequestCookie = request_controller.Cookie;
    const RuntimePhase = enum(u2) { start, stop, cleanup };
    const RuntimeCookie = struct {
        registry_index: u16,
        phase: RuntimePhase,
    };
    const Cookie = union(enum) {
        request: RequestCookie,
        runtime: RuntimeCookie,
    };
    const Transport = upload_transport.Transport(
        Cookie,
        Reactor.file_handle_capacity,
        Reactor.file_target_capacity,
    );
    const RuntimeDeadline = runtime_deadline.Race(RuntimeCookie, Transport.Delivery);
    const Requests = request_controller.Controller(
        App,
        Storage,
        Reactor,
        Transport,
        Cookie,
        Event,
        Error,
    );
    const RuntimeRegistry = runtime_registry.Lifecycle(
        App,
        Storage,
        Reactor,
        RuntimePhase,
        Event,
        Error,
    );
    const RuntimeDeadlineMarker = struct {
        registry_index: u16,
        failure: startup_diagnostic.DeadlineFailure,
    };
    const request_capacity: usize = Storage.runtime_limits.request_slots;

    return struct {
        const Self = @This();
        const UpstreamFailure = upload_finalizer.UpstreamFailure;

        transport: Transport = Transport.init(),
        requests: Requests = .{},
        upload_metrics: worker_metrics.UploadMetrics = .{},
        finalization_generations: [request_capacity]u16 = @splat(0),
        worker_index: u16,
        runtime_sequence: u16 = 1,
        runtime_deadline: RuntimeDeadline = .{},
        runtime_submission_unproven: bool = false,
        runtime_deadline_diagnostic: ?RuntimeDeadlineMarker = null,
        runtime_now_ns: u64 = 0,
        runtime_cursor: u32 = 0,
        runtime_entropy: [32]u8 = @splat(0),
        startup_failure: ?Error = null,
        startup_failure_index: ?u16 = null,
        startup_diagnostic: ?StartupDiagnostic = null,
        runtime_metric_index: ?u16 = null,
        runtime_cleanup_handle: ?multipart.FileHandle = null,
        startup_cleanup_index: u16 = 0,
        rollback_cleanup_failed: bool = false,
        startup_cleanup_active: bool = false,
        phase: Phase = .idle,

        pub fn init(worker_index: u16) Error!Self {
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            return .{ .worker_index = worker_index };
        }

        pub fn beginRegistryStart(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            entropy: *const [32]u8,
        ) Error!Event {
            return self.beginRegistryStartAt(storage, io, entropy, 0);
        }

        pub fn beginRegistryStartAt(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            entropy: *const [32]u8,
            now_ns: u64,
        ) Error!Event {
            defer self.scrubRuntimeEntropyIfReleased();
            self.runtime_metric_index = null;
            self.runtime_now_ns = now_ns;
            return RuntimeRegistry.beginStart(self, storage, io, entropy, now_ns) catch |failure| {
                self.recordFatal(
                    fatalClass(failure),
                    runtimeIdentity(self.runtime_metric_index),
                );
                return failure;
            };
        }

        pub fn beginRegistryStop(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
        ) Error!Event {
            return self.beginRegistryStopAt(storage, io, self.runtime_now_ns);
        }

        pub fn beginRegistryStopAt(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            now_ns: u64,
        ) Error!Event {
            defer self.scrubRuntimeEntropyIfReleased();
            self.runtime_metric_index = null;
            self.runtime_now_ns = now_ns;
            return RuntimeRegistry.beginStop(self, storage, io, now_ns) catch |failure| {
                self.recordFatal(
                    fatalClass(failure),
                    runtimeIdentity(self.runtime_metric_index),
                );
                return failure;
            };
        }

        fn scrubRuntimeEntropyIfReleased(self: *Self) void {
            if (self.phase != .starting) std.crypto.secureZero(u8, &self.runtime_entropy);
        }

        pub fn submitParserWork(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
        ) Error!Event {
            return self.submitParserWorkAt(storage, io, request_index, 0);
        }

        pub fn submitParserWorkAt(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            now_ns: u64,
        ) Error!Event {
            if (self.phase != .ready) {
                self.recordFatal(.state_invariant, null);
                return error.StateInvariant;
            }
            return self.requests.submitParserWork(
                &self.transport,
                &self.upload_metrics,
                self.worker_index,
                storage,
                io,
                request_index,
                now_ns,
            ) catch |problem| {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    fatalClass(problem),
                    self.requests.failureIdentity(),
                );
                return problem;
            };
        }

        pub fn beginRequestAbort(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            cause: UpstreamFailure,
        ) Error!Event {
            if (self.phase != .ready) {
                self.recordFatal(.state_invariant, null);
                return error.StateInvariant;
            }
            const event = self.requests.beginAbort(
                &self.transport,
                &self.upload_metrics,
                self.worker_index,
                storage,
                io,
                request_index,
                cause,
            ) catch |problem| {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    fatalClass(problem),
                    self.requests.failureIdentity(),
                );
                return problem;
            };
            return self.acceptRequestEvent(
                event,
                request_index,
                storage.requests[request_index].generation,
            );
        }

        pub fn complete(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            completion: reactor.Completion,
        ) Error!Event {
            return self.completeAt(storage, io, completion, 0);
        }

        pub fn completeAt(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Event {
            const fields = completion.token.fields() catch {
                self.recordFatal(.state_invariant, null);
                return error.StateInvariant;
            };
            defer if (fields.slot_index == reactor.upload_runtime_control_slot) {
                self.scrubRuntimeEntropyIfReleased();
            };
            if (fields.slot_index == reactor.upload_runtime_control_slot) {
                self.runtime_now_ns = now_ns;
            }
            if (fields.slot_index == reactor.upload_runtime_control_slot and
                (fields.kind == .timeout or fields.kind == .cancel))
            {
                return RuntimeRegistry.completeControl(
                    self,
                    storage,
                    io,
                    completion,
                    now_ns,
                ) catch |problem| {
                    self.recordFatal(
                        fatalClass(problem),
                        runtimeIdentity(self.runtime_metric_index),
                    );
                    return problem;
                };
            }
            const target_owner = self.transport.targetOwner(completion.token);
            const target_identity = ownerIdentity(target_owner);
            if (requestTarget(completion)) {
                self.requests.observeTargetCompletion(completion.token, now_ns) catch {
                    self.recordFatalForOwner(.state_invariant, target_identity, target_owner);
                    return error.StateInvariant;
                };
            }
            const delivery = self.transport.complete(completion) catch {
                if (completionKind(completion) == .upload_cancel) {
                    self.recordCancellationForOwner(.failed, target_owner);
                }
                self.recordFatalForOwner(.transport, target_identity, target_owner);
                return error.TransportFailure;
            };
            if (fields.slot_index == reactor.upload_runtime_control_slot) {
                return RuntimeRegistry.completeTransport(
                    self,
                    storage,
                    io,
                    completion.token,
                    delivery,
                    now_ns,
                ) catch |problem| {
                    self.recordFatal(
                        fatalClass(problem),
                        runtimeIdentity(self.runtime_metric_index),
                    );
                    return problem;
                };
            }
            const delivered = delivery orelse return .none;
            return switch (delivered.cookie) {
                .request => |cookie| self.completeRequest(
                    storage,
                    io,
                    cookie,
                    delivered.completion,
                    now_ns,
                ),
                .runtime => |cookie| self.completeRuntime(
                    storage,
                    io,
                    cookie,
                    delivered.completion,
                    target_identity,
                ),
            };
        }

        fn completeRuntime(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            cookie: RuntimeCookie,
            completion: multipart.IoCompletion,
            target_identity: ?worker_metrics.upload.Identity,
        ) Error!Event {
            defer self.scrubRuntimeEntropyIfReleased();
            self.runtime_metric_index = null;
            return RuntimeRegistry.complete(
                self,
                storage,
                io,
                cookie,
                completion,
            ) catch |problem| {
                const identity = runtimeIdentity(self.runtime_metric_index) orelse
                    target_identity;
                self.recordFatal(fatalClass(problem), identity);
                return problem;
            };
        }

        pub fn metricsSnapshot(self: *const Self) worker_metrics.UploadMetricsSnapshot {
            return self.upload_metrics.snapshot();
        }

        pub fn routeMetricsSnapshot(
            self: *const Self,
            route_id: u16,
        ) ?RouteMetricsSnapshot {
            return self.requests.route_metrics.snapshot(self.worker_index, route_id);
        }

        pub fn startupDiagnostic(self: *const Self) ?*const StartupDiagnostic {
            return if (self.startup_diagnostic) |*diagnostic| diagnostic else null;
        }

        pub fn recordFinalizationIfTerminal(
            self: *Self,
            storage: *Storage,
            request_index: u16,
        ) Error!void {
            if (request_index >= storage.requests.len) return error.InvalidRequest;
            const request = &storage.requests[request_index];
            if (request.generation == 0 or
                self.finalization_generations[request_index] == request.generation or
                !metrics_record.terminal(&request.workspace)) return;
            const request_state = self.requests.store.request(
                request_index,
                request.generation,
            ) catch |problem| {
                self.recordFatal(fatalClass(problem), null);
                return problem;
            };
            const workspace = storage.bodyWorkspace(request_index) catch {
                return error.StateInvariant;
            };
            var recorder = self.requests.route_metrics.recorderForRequest(
                &self.upload_metrics,
                &self.requests.store,
                storage,
                request_index,
            ) catch |problem| {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    fatalClass(problem),
                    null,
                );
                return problem;
            };
            const report = (App.__multipartFinalizationReport(
                &request.workspace,
                workspace,
            ) catch {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    .application,
                    null,
                );
                return error.ApplicationFailure;
            }) orelse {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    .state_invariant,
                    null,
                );
                return error.StateInvariant;
            };
            metrics_record.recordReport(
                App,
                &recorder,
                &request.workspace,
                workspace,
                report,
            ) catch |problem| {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    fatalClass(problem),
                    null,
                );
                return problem;
            };
            self.requests.route_metrics.succeed();
            request_state.finalized = true;
            self.finalization_generations[request_index] = request.generation;
        }

        pub fn retireRequest(
            self: *Self,
            storage: *Storage,
            request_index: u16,
        ) Error!void {
            if (request_index >= storage.requests.len or
                storage.requests[request_index].generation == 0)
            {
                return error.InvalidRequest;
            }
            try self.requests.store.retire(request_index);
            self.finalization_generations[request_index] = 0;
        }

        pub fn retireAllRequests(self: *Self) Error!void {
            for (0..request_capacity) |request_index| {
                try self.requests.store.retire(@intCast(request_index));
            }
            self.finalization_generations = @splat(0);
        }

        fn completeRequest(
            self: *Self,
            storage: *Storage,
            io: *Reactor,
            cookie: RequestCookie,
            completion: multipart.IoCompletion,
            now_ns: u64,
        ) Error!Event {
            if (self.phase != .ready) {
                self.requests.route_metrics.recordFatalForSlot(
                    &self.requests.store,
                    &self.upload_metrics,
                    cookie.request_index,
                    cookie.request_generation,
                    .state_invariant,
                    null,
                );
                return error.StateInvariant;
            }
            const event = self.requests.complete(
                &self.transport,
                &self.upload_metrics,
                self.worker_index,
                storage,
                io,
                cookie,
                completion,
                now_ns,
            ) catch |problem| {
                self.requests.route_metrics.recordPendingFatal(
                    &self.upload_metrics,
                    fatalClass(problem),
                    .{
                        .registry_index = cookie.registry_index,
                        .instance_index = cookie.instance_index,
                    },
                );
                return problem;
            };
            return self.acceptRequestEvent(
                event,
                cookie.request_index,
                cookie.request_generation,
            );
        }

        fn acceptRequestEvent(
            self: *Self,
            event: Event,
            request_index: u16,
            generation: u16,
        ) Error!Event {
            if (event == .request_finalized) {
                if (event.request_finalized.request_index != request_index) {
                    return error.StateInvariant;
                }
                self.finalization_generations[request_index] = generation;
            }
            return event;
        }

        fn recordFatalForOwner(
            self: *Self,
            class: worker_metrics.upload.FatalFailureClass,
            identity: ?worker_metrics.upload.Identity,
            owner: ?upload_transport.Owner,
        ) void {
            const value = owner orelse return self.recordFatal(class, identity);
            if (value.scope != .request) return self.recordFatal(class, identity);
            self.requests.route_metrics.recordFatalForSlot(
                &self.requests.store,
                &self.upload_metrics,
                value.slot.index,
                value.slot.generation,
                class,
                identity,
            );
        }

        fn recordCancellationForOwner(
            self: *Self,
            outcome: worker_metrics.upload.CancellationOutcome,
            owner: ?upload_transport.Owner,
        ) void {
            const value = owner orelse return self.upload_metrics.recordCancellation(outcome);
            if (value.scope != .request) {
                return self.upload_metrics.recordCancellation(outcome);
            }
            self.requests.route_metrics.recordCancellationForSlot(
                &self.requests.store,
                &self.upload_metrics,
                value.slot.index,
                value.slot.generation,
                outcome,
            );
        }

        fn recordFatal(
            self: *Self,
            class: worker_metrics.upload.FatalFailureClass,
            identity: ?worker_metrics.upload.Identity,
        ) void {
            self.upload_metrics.recordFatalFailure(class, identity);
        }

        pub fn pending(self: *const Self) u32 {
            return self.transport.pendingTargets() + self.runtime_deadline.controlPending();
        }

        pub fn ownershipProven(self: *const Self) bool {
            return self.transport.ownershipProven() and !self.runtime_deadline.active and
                !self.runtime_submission_unproven;
        }

        pub fn activeHandles(self: *const Self) u32 {
            return self.transport.tableConst().active();
        }

        pub fn registryReady(self: *const Self) bool {
            return self.phase == .ready;
        }
        pub fn registryStopped(self: *const Self) bool {
            return self.phase == .stopped;
        }
    };
}

fn completionKind(completion: reactor.Completion) ?reactor.OperationKind {
    const fields = completion.token.fields() catch return null;
    return fields.kind;
}

fn requestTarget(completion: reactor.Completion) bool {
    const fields = completion.token.fields() catch return false;
    return reactor.isUploadFileOperation(fields.kind) and
        fields.slot_index != reactor.upload_runtime_control_slot;
}

fn fatalClass(problem: Error) worker_metrics.upload.FatalFailureClass {
    return switch (problem) {
        error.ApplicationFailure => .application,
        error.BackendFailure => .backend,
        error.InvalidRequest => .invalid_request,
        error.InvalidWorkerIndex => .invalid_worker_index,
        error.StateInvariant => .state_invariant,
        error.TransportFailure => .transport,
    };
}

fn ownerIdentity(
    owner: ?upload_transport.Owner,
) ?worker_metrics.upload.Identity {
    const value = owner orelse return null;
    return .{
        .registry_index = value.registry_index,
        .instance_index = value.instance_index,
    };
}

fn runtimeIdentity(index: ?u16) ?worker_metrics.upload.Identity {
    return .{
        .registry_index = index orelse return null,
        .instance_index = 0,
    };
}

test {
    std.testing.refAllDecls(@This());
}

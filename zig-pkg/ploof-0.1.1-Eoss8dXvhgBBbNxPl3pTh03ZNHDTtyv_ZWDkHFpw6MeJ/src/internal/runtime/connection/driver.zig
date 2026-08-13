const std = @import("std");
const application = @import("../../../application.zig");
const forwarding = @import("../../../forwarding.zig");
const connection_admission = @import("admission.zig");
const connection_body_transport = @import("body_transport.zig");
const connection_completion = @import("completion.zig");
const connection_driver_prepare = @import("driver_prepare.zig");
const connection_driver_types = @import("driver_types.zig");
const connection_driver_live_static = @import("driver_live_static.zig");
const connection_driver_upload = @import("driver_upload.zig");
const connection_gzip_transport = @import("gzip_transport.zig");
const connection_invariants = @import("invariants.zig");
const connection_lifecycle = @import("lifecycle.zig");
const connection_metrics_transport = @import("metrics_transport.zig");
const connection_observation = @import("observation.zig");
const connection_observation_fallback = @import("observation_fallback.zig");
const connection_observation_io = @import("observation_io.zig");
const connection_operations = @import("operations.zig");
const connection_pipeline = @import("pipeline.zig");
const connection_rejection = @import("rejection.zig");
const connection_response_transport = @import("response_transport.zig");
const connection_send = @import("send.zig");
const connection_transport_failure = @import("transport_failure.zig");
const reactor = @import("../reactor.zig");
const worker_upload_transport = @import("../worker/upload_transport.zig");
const worker_live_static = @import("../worker/live_static.zig");
const rejection_response = @import("../../http1/rejection_response.zig");
const request_head = @import("../../http1/request_head.zig");
const server_metrics_request = @import("../server/metrics_request.zig");
pub const Error = connection_driver_types.Error;
pub const Disposition = connection_driver_types.Disposition;
pub fn Driver(comptime App: type, comptime Storage: type, comptime Reactor: type) type {
    return ConfiguredDriver(App, Storage, Reactor, forwarding.standard_limits);
}
pub fn ConfiguredDriver(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime forwarding_limits: forwarding.Limits,
) type {
    return ObservedConfiguredDriver(
        App,
        Storage,
        Reactor,
        forwarding_limits,
        connection_observation.Disabled,
    );
}
pub fn ObservedConfiguredDriver(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime forwarding_limits: forwarding.Limits,
    comptime Observation: type,
) type {
    const ForwardingProfile = forwarding.Profile(forwarding_limits);
    const default_forwarding_profile = ForwardingProfile.init(.{}) catch unreachable;
    return struct {
        const Self = @This();
        const BodyTransport = connection_body_transport.Transport(App, Storage, Error);
        const GzipTransport = connection_gzip_transport.Transport(App, Storage, Error);
        const ResponseTransport = connection_response_transport.Transport(App, Storage, Error);
        const MetricsTransport = connection_metrics_transport.Transport(
            App,
            Storage,
            Error,
            BodyTransport,
            ResponseTransport,
        );
        const Prepare = connection_driver_prepare.Controller(
            App,
            Storage,
            Error,
            BodyTransport,
            ResponseTransport,
            MetricsTransport,
        );
        const LiveStatic = worker_live_static.Controller(
            App,
            Storage,
            Reactor,
            Error,
            BodyTransport,
            ResponseTransport,
        );
        const Lifecycle = connection_lifecycle.Controller(
            App,
            Storage,
            Error,
            BodyTransport,
            GzipTransport,
            ResponseTransport,
        );
        const Operations = connection_operations.Operations(Storage, Reactor, Error);
        const Uploads = worker_upload_transport.Controller(App, Storage, Reactor);
        const uploads_enabled = @hasDecl(App, "upload_async_sink_present") and
            App.upload_async_sink_present;
        const UploadBridge = connection_driver_upload.Bridge(
            uploads_enabled,
            Error,
            worker_upload_transport.Event,
            BodyTransport,
        );
        const LiveStaticBridge = connection_driver_live_static.Bridge(Error);
        const Rejection = connection_rejection.Controller(Error);
        const runtime_limits = Storage.runtime_limits;
        const MetricsRuntime = server_metrics_request.Runtime(App);
        const ObservationFallback = connection_observation_fallback.Controller(Error);
        const ObservationIo = connection_observation_io.Controller(Error);
        const metrics_enabled = @hasDecl(App, "open_metrics_enabled") and
            App.open_metrics_enabled;
        state: *App.StateType,
        storage: *Storage,
        operations: Operations,
        uploads: Uploads,
        live_static: LiveStatic,
        metrics_runtime: MetricsRuntime,
        observation: Observation,
        runtime_fields: rejection_response.RuntimeFields,
        /// Listener-owned stable storage; must outlive this driver.
        forwarding_profile: *const ForwardingProfile,
        pub const handleGzipSignals = GzipTransport.handleGzipSignals;
        pub const settleGzipAfterBackend = GzipTransport.settleGzipAfterBackend;
        pub fn init(
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            runtime_fields: rejection_response.RuntimeFields,
        ) Error!Self {
            return initForwarding(
                state,
                storage,
                io,
                worker_index,
                runtime_fields,
                &default_forwarding_profile,
            );
        }
        pub fn initForwarding(
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            runtime_fields: rejection_response.RuntimeFields,
            forwarding_profile: *const ForwardingProfile,
        ) Error!Self {
            if (comptime metrics_enabled) {
                @compileError("OpenMetrics driver initialization requires a server runtime");
            }
            return initForwardingMetrics(
                state,
                storage,
                io,
                worker_index,
                runtime_fields,
                forwarding_profile,
                .init(),
                .init(),
            );
        }
        pub fn initForwardingMetrics(
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            runtime_fields: rejection_response.RuntimeFields,
            forwarding_profile: *const ForwardingProfile,
            metrics_runtime: MetricsRuntime,
            observation: Observation,
        ) Error!Self {
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            const probe = rejection_response.writeCapacityProbe(
                storage.pipeline(0),
                runtime_fields,
            ) catch |problem| return switch (problem) {
                error.OutputTooSmall => error.RejectionBufferTooSmall,
                else => error.InvalidRuntimeFields,
            };
            std.crypto.secureZero(u8, probe);
            if (comptime Storage.body_workspace_bytes_per_slot != 0) {
                const body_output = storage.responseWritable(0);
                defer storage.clearResponse(0);
                _ = rejection_response.writeCapacityProbe(
                    body_output,
                    runtime_fields,
                ) catch |problem| return switch (problem) {
                    error.OutputTooSmall => error.RejectionBufferTooSmall,
                    else => error.InvalidRuntimeFields,
                };
            }
            return .{
                .state = state,
                .storage = storage,
                .operations = Operations.init(io, worker_index),
                .uploads = Uploads.init(worker_index) catch return error.InvalidWorkerIndex,
                .live_static = try LiveStatic.init(worker_index),
                .metrics_runtime = metrics_runtime,
                .observation = observation,
                .runtime_fields = runtime_fields,
                .forwarding_profile = forwarding_profile,
            };
        }
        pub fn start(self: *Self, connection_index: u16, now_ns: u64) Error!void {
            const connection = try self.getConnection(connection_index);
            if (connection.phase != .first_head or connection.inflight_operations != 0 or
                connection.receive_token != null or connection.send_token != null or
                connection.timeout_token != null or connection.close_token != null)
            {
                return error.InvalidConnectionState;
            }
            _ = std.math.add(
                u64,
                now_ns,
                runtime_limits.timeouts.first_head_ns,
            ) catch return error.ClockOverflow;
            connection.receive_terminal_reaped = false;
            connection.proxy_destination = null;
            switch (connection.proxy_protocol.configure(
                self.forwarding_profile,
                connection.transport_peer,
            )) {
                .direct, .pending => {},
                .untrusted => {
                    try self.beginClose(connection_index);
                    connection_invariants.assertRecord(self.storage, connection_index);
                    return;
                },
            }
            try self.operations.submitReceiveForPhase(self.storage, connection_index);
            try self.operations.replaceTimeout(
                self.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.first_head_ns,
            );
            connection_invariants.assertRecord(self.storage, connection_index);
        }
        pub fn stop(self: *Self, connection_index: u16) Error!Disposition {
            const connection = try self.getConnection(connection_index);
            connection_invariants.assertRecord(self.storage, connection_index);
            if (connection.phase == .free) return .released;
            try self.beginClose(connection_index);
            connection_invariants.assertRecord(self.storage, connection_index);
            return if (connection.phase == .free) .released else .retained;
        }
        pub fn beginDrain(self: *Self, connection_index: u16) Error!Disposition {
            const connection = try self.getConnection(connection_index);
            connection_invariants.assertRecord(self.storage, connection_index);
            switch (connection.phase) {
                .free => return .released,
                .receiving_body, .responding => connection.close_after_response = true,
                .first_head, .keepalive_idle, .reused_head, .closing => {
                    try self.beginClose(connection_index);
                },
            }
            connection_invariants.assertRecord(self.storage, connection_index);
            return if (connection.phase == .free) .released else .retained;
        }
        pub fn handle(
            self: *Self,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Disposition {
            const fields = completion.token.fields() catch return error.InvalidCompletion;
            if (fields.kind != .cancel and completion.validate() != null) {
                return error.InvalidCompletion;
            }
            if (fields.worker_index != self.operations.worker_index or
                fields.slot_index >= self.storage.connections.len)
            {
                try self.operations.recycleIfBorrowed(completion);
                return .ignored_stale;
            }
            const connection = &self.storage.connections[fields.slot_index];
            if (connection.phase == .free or connection.generation != fields.slot_generation) {
                try self.operations.recycleIfBorrowed(completion);
                return .ignored_stale;
            }
            connection_invariants.assertRecord(self.storage, fields.slot_index);
            connection.receive_flags.send_budget = if (@hasDecl(Reactor, "direct")) 16 else 0;
            const kind = fields.kind;
            if (!isConnectionOperation(kind)) return error.InvalidCompletion;
            if (!completion.more) {
                if (connection.inflight_operations == 0) return error.InvalidCompletion;
                connection.inflight_operations -= 1;
            }
            switch (fields.kind) {
                .receive => try self.handleReceive(fields.slot_index, completion, now_ns),
                .send => try self.handleSend(fields.slot_index, completion, now_ns),
                .close => try self.handleClose(fields.slot_index, completion),
                .timeout => try self.handleTimeout(fields.slot_index, completion, now_ns),
                .cancel => try connection_completion.validateCancel(completion),
                else => unreachable,
            }
            ResponseTransport.streamOperationCompleted(
                self,
                fields.slot_index,
                fields.kind,
                fields.sequence,
            );
            try ResponseTransport.pollDeferredStream(self, fields.slot_index, now_ns);
            try self.maybeContinue(fields.slot_index, now_ns);
            try self.maybeRelease(fields.slot_index);
            connection_invariants.assertRecord(self.storage, fields.slot_index);
            return if (self.storage.connections[fields.slot_index].phase == .free)
                .released
            else
                .retained;
        }
        fn handleReceive(
            self: *Self,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const c = &self.storage.connections[index];
            if (c.receive_token == null or !c.receive_token.?.eql(completion.token)) {
                try self.operations.recycleIfBorrowed(completion);
                return;
            }
            if (!c.receive_flags.multishot and completion.more) {
                try self.operations.recycleIfBorrowed(completion);
                return self.beginClose(index);
            }
            if (!completion.more) {
                c.receive_token = null;
                c.receive_flags.multishot = false;
            }
            switch (completion.result) {
                .failure => |problem| {
                    if (c.phase == .closing) {
                        if (!completion.more) c.receive_terminal_reaped = true;
                    } else if (problem == .buffer_exhausted) {
                        c.receive_flags.paused = !c.receive_flags.gzip_rejecting and
                            (c.phase == .first_head or c.phase == .keepalive_idle or
                                c.phase == .reused_head or c.phase == .receiving_body);
                    } else if (problem == .canceled and c.phase == .responding) {
                        try self.maybeContinue(index, now_ns);
                    } else {
                        try self.beginCloseWithOutcome(
                            index,
                            connection_transport_failure.outcome(problem),
                        );
                    }
                },
                .success => |success| switch (success) {
                    .receive => |received| try self.handleReceived(index, received, now_ns),
                    else => unreachable,
                },
            }
            if (!completion.more and c.phase == .closing) {
                c.receive_terminal_reaped = true;
            } else if (!completion.more and c.phase == .responding) {
                try self.maybeContinue(index, now_ns);
            } else if (!completion.more and completion.result == .success and
                !c.receive_flags.paused and
                !c.receive_flags.gzip_paused and
                !c.receive_flags.gzip_rejecting) switch (c.phase) {
                .first_head, .reused_head, .receiving_body => try self.rearmReceive(index),
                else => {},
            };
        }
        fn rearmReceive(self: *Self, index: u16) Error!void {
            return self.operations.submitReceiveForPhase(self.storage, index);
        }
        fn handleReceived(
            self: *Self,
            index: u16,
            received: reactor.ReceiveResult,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[index];
            switch (received) {
                .end_of_stream => if (connection.receive_flags.gzip_rejecting) {} else {
                    if (connection.phase == .receiving_body) {
                        try BodyTransport.reject(self, index, .bad_request, now_ns);
                    } else if (connection.phase == .responding) {
                        connection.close_after_response = true;
                        try self.maybeContinue(index, now_ns);
                    } else if (connection.phase != .closing) {
                        try self.beginClose(index);
                    }
                },
                .bytes => |borrowed| {
                    var processing_error: ?Error = null;
                    self.consumeReceive(index, borrowed.bytes, now_ns) catch |problem| {
                        processing_error = problem;
                    };
                    try self.operations.recycleBorrowed(borrowed);
                    if (processing_error) |problem| return problem;
                },
            }
        }
        pub fn resumeReceive(self: *Self, connection_index: u16) Error!bool {
            const connection = try self.getConnection(connection_index);
            connection_invariants.assertRecord(self.storage, connection_index);
            if (connection.receive_flags.upload_paused or
                GzipTransport.receiveBlocked(connection)) return false;
            if (connection.phase == .free or connection.phase == .closing) {
                connection.receive_flags.paused = false;
                return false;
            }
            if (connection.receive_token != null) return error.StateInvariant;
            try self.operations.submitReceiveForPhase(self.storage, connection_index);
            connection_invariants.assertRecord(self.storage, connection_index);
            return true;
        }
        fn consumeReceive(
            self: *Self,
            connection_index: u16,
            bytes: []const u8,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[connection_index];
            if (connection.receive_flags.upload_paused) {
                connection_pipeline.append(self.storage, connection_index, bytes) catch |problem| {
                    return switch (problem) {
                        error.PipelineFull => self.beginClose(connection_index),
                        error.StateInvariant => error.StateInvariant,
                    };
                };
                return;
            }
            if (connection.receive_flags.gzip_rejecting) return;
            const reused_from_idle = connection.phase == .keepalive_idle;
            switch (connection.phase) {
                .closing => return,
                .responding => {
                    if (connection.close_after_response) return;
                    connection_pipeline.append(
                        self.storage,
                        connection_index,
                        bytes,
                    ) catch |problem| switch (problem) {
                        error.PipelineFull => try self.beginClose(connection_index),
                        error.StateInvariant => return error.StateInvariant,
                    };
                    return;
                },
                .receiving_body => return BodyTransport.consume(
                    self,
                    connection_index,
                    bytes,
                    .borrowed,
                    now_ns,
                ),
                .keepalive_idle => connection.phase = .reused_head,
                .reused_head => {},
                .first_head => {},
                .free => return error.InvalidConnectionState,
            }
            if (connection.proxy_protocol.pending()) {
                std.debug.assert(!reused_from_idle);
                return self.consumeProxyProtocol(connection_index, bytes, now_ns);
            }
            return self.consumeHead(connection_index, bytes, reused_from_idle, now_ns);
        }
        fn consumeProxyProtocol(
            self: *Self,
            connection_index: u16,
            bytes: []const u8,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[connection_index];
            const result = connection.proxy_protocol.feed(bytes);
            if (result.consumed > bytes.len) return error.StateInvariant;
            switch (result.state) {
                .need_more => {
                    if (result.consumed != bytes.len) return error.StateInvariant;
                    return;
                },
                .invalid => return self.beginClose(connection_index),
                .complete => |value| switch (value) {
                    .local => {
                        connection.connection_peer = connection.transport_peer;
                        connection.connection_source = .proxy_protocol_v2_local;
                        connection.proxy_destination = null;
                    },
                    .proxy => |proxied| {
                        connection.connection_peer = proxied.source.normalized();
                        connection.connection_source = .proxy_protocol_v2;
                        connection.proxy_destination = proxied.destination.normalized();
                    },
                },
            }
            return self.consumeHead(
                connection_index,
                bytes[result.consumed..],
                false,
                now_ns,
            );
        }
        fn consumeHead(
            self: *Self,
            connection_index: u16,
            bytes: []const u8,
            reused_from_idle: bool,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[connection_index];
            const result = connection.head_decoder.feed(bytes);
            if (reused_from_idle and std.meta.activeTag(result.state) == .need_more) {
                try self.operations.replaceTimeout(
                    self.storage,
                    connection_index,
                    now_ns,
                    runtime_limits.timeouts.reused_head_progress_ns,
                );
            }
            try connection_admission.finishHead(
                Error,
                self,
                connection_index,
                result.state,
                bytes[result.consumed..],
                .borrowed,
                now_ns,
            );
        }
        pub fn prepareResponse(
            self: *Self,
            connection_index: u16,
            head: request_head.Head,
            tail: []const u8,
            source: connection_body_transport.InputSource,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[connection_index];
            const gate = connection_admission.analyzeForwarded(
                App,
                runtime_limits.chunked.trailer_names_max,
                forwarding_limits,
                self.forwarding_profile,
                .{
                    .transport_peer = connection.transport_peer,
                    .connection_peer = connection.connection_peer,
                    .connection_source = connection.connection_source,
                },
                &self.storage.route_search_workspace,
                &connection.head_decoder,
                head,
                self.storage.decodedPath(connection_index),
                self.runtime_fields.date,
            ) catch {
                std.crypto.secureZero(u8, self.storage.decodedPath(connection_index));
                try self.beginClose(connection_index);
                return error.StateInvariant;
            };
            const admitted = switch (gate) {
                .admitted => |value| value,
                .rejected => |rejected| {
                    std.crypto.secureZero(
                        u8,
                        self.storage.decodedPath(connection_index)[0..rejected.decoded_path_used],
                    );
                    try self.startRejection(connection_index, rejected.response, now_ns);
                    return;
                },
                .silent_close => |closed| {
                    std.crypto.secureZero(
                        u8,
                        self.storage.decodedPath(connection_index)[0..closed.decoded_path_used],
                    );
                    try self.beginClose(connection_index);
                    return;
                },
            };
            try Prepare.prepareAdmitted(
                self,
                connection_index,
                admitted,
                tail,
                source,
                now_ns,
            );
        }
        pub const startRejection = Rejection.start;
        pub const startObservedFallback = ObservationFallback.start;
        fn handleSend(
            self: *Self,
            connection_index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const connection = &self.storage.connections[connection_index];
            const result = connection_send.handle(
                self.storage,
                connection_index,
                completion,
            ) catch |problem| {
                connection_send.abandon(self.storage, connection_index);
                try self.beginClose(connection_index);
                return problem;
            };
            try self.recordResponseWire(connection_index, completion, result);
            if (connection.phase == .closing and result != .stale) {
                if (try ResponseTransport.settleLiveStaticSendDuringClose(
                    self,
                    connection_index,
                    result == .buffer_complete,
                    now_ns,
                )) return;
                if (result == .buffer_complete and
                    (!ResponseTransport.streamActive(self, connection_index) or
                        ResponseTransport.streamBufferCompletionWinsClose(
                            self,
                            connection_index,
                        )))
                {
                    try ResponseTransport.complete(self, connection_index, now_ns);
                    return;
                }
                if (result == .partial) connection_send.abandon(self.storage, connection_index);
                try self.beginCloseWithOutcome(connection_index, .framework_canceled);
                return;
            }
            switch (result) {
                .stale => {},
                .failed => |problem| try self.beginCloseWithOutcome(
                    connection_index,
                    connection_transport_failure.outcome(problem),
                ),
                .partial => {
                    if (connection.phase == .closing) {
                        connection_send.abandon(self.storage, connection_index);
                        return;
                    }
                    try Operations.extendTimeoutDeadline(
                        self.storage,
                        connection_index,
                        now_ns,
                        runtime_limits.timeouts.write_stall_ns,
                    );
                    try self.operations.submitSend(
                        self.storage,
                        connection_index,
                        try connection_send.bytes(self.storage, connection_index),
                    );
                },
                .continue_complete => try BodyTransport.completeContinue(
                    self,
                    connection_index,
                    now_ns,
                ),
                .buffer_complete => try ResponseTransport.complete(self, connection_index, now_ns),
            }
        }
        const recordResponseWire = ObservationIo.recordResponseWire;
        pub fn maybeContinue(
            self: *Self,
            connection_index: u16,
            now_ns: u64,
        ) Error!void {
            return connection_pipeline.continueAfterResponse(
                Error,
                GzipTransport,
                runtime_limits,
                self,
                connection_index,
                connection_body_transport.InputSource.pipeline,
                now_ns,
            );
        }
        pub fn releaseRequest(
            self: *Self,
            connection_index: u16,
            request_index: u16,
        ) Error!void {
            if (self.storage.connections[connection_index]
                .receive_flags.response_fallback)
            {
                return error.StateInvariant;
            }
            if (!self.observation.releaseReady(request_index)) return error.StateInvariant;
            try MetricsTransport.releaseAtTerminal(self, request_index);
            try UploadBridge.retireRequest(self, request_index);
            self.storage.releaseRequest(connection_index, request_index);
        }
        pub fn retireAllRequests(self: *Self) Error!void {
            try UploadBridge.retireAllRequests(self);
        }
        const handleTimeout = Lifecycle.handleTimeout;
        const handleClose = Lifecycle.handleClose;
        pub const beginClose = Lifecycle.beginClose;
        pub const beginCloseWithOutcome = Lifecycle.beginCloseWithOutcome;
        pub const maybeRelease = Lifecycle.maybeRelease;
        pub const completeObservedFallback = ObservationFallback.complete;
        pub const completeResponse = ResponseTransport.complete;
        const submitCloseWhenStreamSettled = Lifecycle.submitCloseWhenStreamSettled;
        pub fn handleStreamReady(
            self: *Self,
            request_index: u16,
            now_ns: u64,
        ) Error!void {
            if (comptime metrics_enabled) {
                if (request_index < self.storage.requests.len) {
                    const phase = self.storage.requests[request_index].metrics.phase;
                    if (phase == .waiting or phase == .canceling) {
                        return MetricsTransport.handleReady(self, request_index, now_ns);
                    }
                }
            }
            return ResponseTransport.handleStreamReady(self, request_index, now_ns);
        }
        pub const cancelMetricsForClose = MetricsTransport.cancelForClose;
        pub const metricsRequestReleaseReady = MetricsTransport.requestReleaseReady;
        pub const prepareMetricsFatal = MetricsTransport.prepareFatal;
        pub const finishMetricsFatal = MetricsTransport.finishFatal;
        pub const beginUploadRegistry = UploadBridge.beginRegistry;
        pub const submitPausedUpload = UploadBridge.submitPaused;
        pub const abortUploadRequest = UploadBridge.abortRequest;
        pub const stopUploadRegistry = UploadBridge.stopRegistry;
        pub const handleUpload = UploadBridge.handle;
        pub const beginLiveStaticRoots = LiveStaticBridge.beginRoots;
        pub const beginLiveStaticStop = LiveStaticBridge.beginStop;
        pub const handleLiveStatic = LiveStaticBridge.handle;
        pub const liveStaticRootsReady = LiveStaticBridge.rootsReady;
        pub const liveStaticStopped = LiveStaticBridge.stopped;
        pub const liveStaticPending = LiveStaticBridge.pending;
        pub const liveStaticRequests = LiveStaticBridge.requests;
        pub const liveStaticStartupDiagnostic = LiveStaticBridge.startupDiagnostic;
        pub const abortLiveStatic = LiveStaticBridge.abort;
        pub const uploadRegistryReady = UploadBridge.registryReady;
        pub const uploadRegistryStopped = UploadBridge.registryStopped;
        pub const uploadPending = UploadBridge.pending;
        pub const uploadOwnershipProven = UploadBridge.ownershipProven;
        pub const uploadActiveHandles = UploadBridge.activeHandles;
        pub const uploadMetricsSnapshot = UploadBridge.metricsSnapshot;
        pub const uploadRouteMetricsSnapshot = UploadBridge.routeMetricsSnapshot;
        pub const uploadStartupDiagnostic = UploadBridge.startupDiagnostic;
        pub const recordUploadFinalization = UploadBridge.recordFinalization;
        fn getConnection(self: *Self, connection_index: u16) Error!*Storage.Connection {
            if (connection_index >= self.storage.connections.len)
                return error.InvalidConnectionIndex;
            return &self.storage.connections[connection_index];
        }
    };
}

fn isConnectionOperation(kind: reactor.OperationKind) bool {
    return switch (kind) {
        .receive, .send, .close, .timeout, .cancel => true,
        else => false,
    };
}

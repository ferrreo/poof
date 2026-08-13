const std = @import("std");
const multipart = @import("../../../multipart/upload.zig");
const upload_dispatch = @import("../../application/multipart_upload_dispatch.zig");
const upload_validation = @import("../upload/transport_validation.zig");
const support = @import("upload_request_support.zig");
const reactor = @import("../reactor.zig");
const upload_metrics = @import("upload_metrics.zig");
const request_cancel = @import("upload_request_cancel.zig");
const request_cleanup = @import("upload_request_cleanup.zig");
const request_failure = @import("upload_request_failure.zig");
const request_route = @import("upload_request_route.zig");
const observe = @import("upload_request_observe.zig");
const clearWindowFull = observe.clearWindowFull;
const elapsed = observe.elapsed;
const finishWindowFull = observe.finishWindowFull;
const identity = observe.identity;
const noteWindowFull = observe.noteWindowFull;
const syncInflight = observe.syncInflight;
pub const DeliveryMode = support.DeliveryMode;
pub const Cookie = support.Cookie;

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime Transport: type,
    comptime TransportCookie: type,
    comptime Event: type,
    comptime Error: type,
) type {
    const request_capacity: usize = Storage.runtime_limits.request_slots;
    const window: usize = App.upload_window_max;
    if (window == 0) @compileError("PLOOF-E3525 async upload window must be positive");
    const RequestStore = support.Store(request_capacity, window);
    const RequestState = RequestStore.Request;
    const RouteContext = request_route.Context(App, Storage, RequestStore);
    const RouteRecorder = RouteContext.Recorder;
    const RequestCleanup = request_cleanup.Handler(
        App,
        Error,
        TransportCookie,
        RequestStore,
        Event,
    );
    const ApplicationFailureResult = union(enum) { event: Event, continue_finalization };
    const FillResult = struct { submitted: u8, continue_finalization: bool };
    return struct {
        const Self = @This();
        store: RequestStore = .{},
        route_metrics: RouteContext = .{},
        failure_identity: ?upload_metrics.Identity = null,
        pub fn failureIdentity(self: *const Self) ?upload_metrics.Identity {
            return self.failure_identity;
        }
        pub fn observeTargetCompletion(
            self: *Self,
            token: reactor.OperationToken,
            now_ns: u64,
        ) Error!void {
            self.failure_identity = null;
            return self.store.observeTargetCompletion(token, now_ns) catch
                error.StateInvariant;
        }
        pub fn submitParserWork(
            self: *Self,
            transport: *Transport,
            aggregate: *upload_metrics.Metrics,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            now_ns: u64,
        ) Error!Event {
            self.failure_identity = null;
            self.route_metrics.resetFailure();
            const request = try support.liveRequest(storage, request_index);
            const state = try self.store.request(request_index, request.generation);
            var metrics = try self.route_metrics.recorder(
                aggregate,
                &request.workspace,
                state,
            );
            state.last_now_ns = now_ns;
            if (state.finalized or request.flags.upload_parser_paused) {
                return error.StateInvariant;
            }
            request.flags.upload_parser_paused = true;
            const event = self.afterApplicationCompletion(
                transport,
                &metrics,
                worker_index,
                storage,
                io,
                request_index,
                request,
                state,
                try support.bodyWorkspace(storage, request_index),
                now_ns,
            ) catch |problem| {
                request.flags.upload_parser_paused = false;
                return problem;
            };
            if (event == .none and state.active == 0) {
                request.flags.upload_parser_paused = false;
                return error.StateInvariant;
            }
            self.failure_identity = null;
            self.route_metrics.succeed();
            return event;
        }
        pub fn beginAbort(
            self: *Self,
            transport: *Transport,
            aggregate: *upload_metrics.Metrics,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            cause: upload_dispatch.UpstreamFailure,
        ) Error!Event {
            self.failure_identity = null;
            self.route_metrics.resetFailure();
            const request = try support.liveRequest(storage, request_index);
            if (request_route.bypassFinalization(&self.route_metrics, &request.workspace))
                return .none;
            const state = try self.store.request(request_index, request.generation);
            var metrics = try self.route_metrics.recorder(
                aggregate,
                &request.workspace,
                state,
            );
            if (state.finalized or request.flags.upload_finalizing or state.failure == .fatal) {
                return .none;
            }
            if (state.abort_cause == null) state.abort_cause = cause;
            request.flags.upload_cancel_requested = true;
            request.flags.upload_cancel_peer = cause == .peer_disconnect;
            clearWindowFull(state);
            try request_cancel.cancelApplicationTargets(
                Error,
                transport,
                &metrics,
                worker_index,
                io,
                request,
                state,
                &self.failure_identity,
            );
            const event = if (state.active != 0)
                Event.none
            else
                try self.startAbort(
                    transport,
                    &metrics,
                    worker_index,
                    storage,
                    io,
                    request_index,
                    request,
                    state,
                    state.last_now_ns,
                );
            self.failure_identity = null;
            self.route_metrics.succeed();
            return event;
        }

        pub fn complete(
            self: *Self,
            transport: *Transport,
            aggregate: *upload_metrics.Metrics,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            cookie: Cookie,
            completion: multipart.IoCompletion,
            now_ns: u64,
        ) Error!Event {
            self.route_metrics.resetFailure();
            self.failure_identity = .{
                .registry_index = cookie.registry_index,
                .instance_index = cookie.instance_index,
            };
            const request = try support.liveRequest(storage, cookie.request_index);
            if (request.generation != cookie.request_generation or
                request.connection_index != cookie.connection_index)
            {
                return error.StateInvariant;
            }
            const state = try self.store.request(cookie.request_index, request.generation);
            var metrics = try self.route_metrics.recorder(
                aggregate,
                &request.workspace,
                state,
            );
            state.last_now_ns = now_ns;
            const entry = try RequestStore.take(state, cookie);
            syncInflight(request, state);
            metrics.recordSinkOperation(
                entry.kind,
                elapsed(entry.submitted_ns, entry.completion_ns orelse now_ns),
            );
            const expected_cancel = entry.cancel_submitted and completion == .failure and
                completion.failure == .canceled;
            if (entry.cancel_submitted) metrics.recordCancellation(
                if (expected_cancel) .target_canceled else .target_completed,
            );
            if (completion == .failure and !expected_cancel) {
                metrics.recordRecoverableFailure(completion.failure, identity(entry));
            }
            const event = try self.dispatchCompletion(
                transport,
                &metrics,
                worker_index,
                storage,
                io,
                cookie,
                entry,
                completion,
                request,
                state,
                now_ns,
            );
            self.failure_identity = null;
            self.route_metrics.succeed();
            return event;
        }

        fn dispatchCompletion(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            cookie: Cookie,
            entry: RequestStore.Entry,
            completion: multipart.IoCompletion,
            request: *Storage.Request,
            state: *RequestState,
            now_ns: u64,
        ) Error!Event {
            switch (try RequestCleanup.route(
                self,
                transport,
                metrics,
                worker_index,
                storage,
                io,
                cookie,
                request,
                state,
                entry,
                completion,
                now_ns,
                &self.failure_identity,
            )) {
                .application => {},
                .event => |event| return event,
            }
            const workspace = try support.bodyWorkspace(storage, cookie.request_index);
            support.completeSubmission(
                App,
                &request.workspace,
                workspace,
                cookie.lane,
                entry,
                completion,
            ) catch |problem| {
                return switch (try self.applicationFailed(
                    transport,
                    metrics,
                    worker_index,
                    storage,
                    io,
                    cookie.request_index,
                    request,
                    state,
                    workspace,
                    problem,
                    now_ns,
                )) {
                    .event => |event| event,
                    .continue_finalization => self.afterApplicationCompletion(
                        transport,
                        metrics,
                        worker_index,
                        storage,
                        io,
                        cookie.request_index,
                        request,
                        state,
                        workspace,
                        now_ns,
                    ),
                };
            };
            return self.afterApplicationCompletion(
                transport,
                metrics,
                worker_index,
                storage,
                io,
                cookie.request_index,
                request,
                state,
                workspace,
                now_ns,
            );
        }

        fn afterApplicationCompletion(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            workspace: []u8,
            now_ns: u64,
        ) Error!Event {
            var rounds: u32 = 0;
            while (rounds <= App.upload_window_max) : (rounds += 1) {
                const aborting = state.abort_cause != null or state.failure == .sink;
                if (!request.flags.upload_finalizing and aborting) {
                    return request_failure.afterAbortRequested(
                        Error,
                        Event,
                        self,
                        transport,
                        metrics,
                        worker_index,
                        storage,
                        io,
                        request_index,
                        request,
                        state,
                        now_ns,
                        &self.failure_identity,
                    );
                }
                const filled = try self.fill(
                    transport,
                    metrics,
                    worker_index,
                    storage,
                    io,
                    request_index,
                    request,
                    state,
                    now_ns,
                );
                if (filled.continue_finalization) continue;
                if (state.failure != .none or
                    (filled.submitted != 0 and state.active == state.route_window)) return .none;
                if (request.flags.upload_finalizing) {
                    clearWindowFull(state);
                    return self.advanceFinalization(
                        transport,
                        metrics,
                        worker_index,
                        storage,
                        io,
                        request_index,
                        workspace,
                        request,
                        state,
                        null,
                        now_ns,
                    );
                }
                if (!request.flags.upload_parser_paused) return .none;
                return self.resumeParser(
                    transport,
                    metrics,
                    worker_index,
                    storage,
                    io,
                    request_index,
                    request,
                    state,
                    workspace,
                    now_ns,
                );
            }
            return error.StateInvariant;
        }

        fn resumeParser(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            workspace: []u8,
            now_ns: u64,
        ) Error!Event {
            const progress = App.__resumeMultipart(
                &request.workspace,
                workspace,
            ) catch |problem| return switch (try self.applicationFailed(
                transport,
                metrics,
                worker_index,
                storage,
                io,
                request_index,
                request,
                state,
                workspace,
                problem,
                now_ns,
            )) {
                .event => |event| event,
                .continue_finalization => error.StateInvariant,
            };
            if (progress.flow == .paused) {
                const filled = try self.fill(
                    transport,
                    metrics,
                    worker_index,
                    storage,
                    io,
                    request_index,
                    request,
                    state,
                    now_ns,
                );
                if (filled.continue_finalization) return error.StateInvariant;
                if (filled.submitted == 0 and state.active == 0) return error.StateInvariant;
                return .none;
            }
            finishWindowFull(metrics, state, now_ns);
            request.flags.upload_parser_paused = false;
            return .{ .request_resumed = .{
                .connection_index = request.connection_index,
                .request_index = request_index,
                .progress = progress,
            } };
        }

        fn fill(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            now_ns: u64,
        ) Error!FillResult {
            try request_route.requireAsyncWindow(state);
            var submitted: u8 = 0;
            var continue_finalization = false;
            while (state.active < state.route_window and state.failure != .fatal and
                (state.abort_cause == null or request.flags.upload_finalizing))
            {
                const workspace = try support.bodyWorkspace(storage, request_index);
                const queued = App.__peekUploadSubmission(
                    &request.workspace,
                    workspace,
                ) catch return error.ApplicationFailure;
                const submission = queued orelse break;
                try self.submitApplication(
                    transport,
                    worker_index,
                    io,
                    request_index,
                    request,
                    state,
                    submission,
                    now_ns,
                );
                submitted += 1;
                App.__markUploadSubmitted(
                    &request.workspace,
                    workspace,
                    submission.lane,
                ) catch |problem| {
                    switch (try self.applicationFailed(
                        transport,
                        metrics,
                        worker_index,
                        storage,
                        io,
                        request_index,
                        request,
                        state,
                        workspace,
                        problem,
                        now_ns,
                    )) {
                        .event => {},
                        .continue_finalization => continue_finalization = true,
                    }
                    break;
                };
                self.failure_identity = null;
            }
            if (!request.flags.upload_finalizing) noteWindowFull(state, now_ns);
            return .{
                .submitted = submitted,
                .continue_finalization = continue_finalization,
            };
        }

        fn submitApplication(
            self: *Self,
            transport: *Transport,
            worker_index: u16,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            submission: upload_dispatch.Submission,
            now_ns: u64,
        ) Error!void {
            self.failure_identity = .{
                .registry_index = submission.registry_index,
                .instance_index = submission.instance_index,
            };
            const slot = try RequestStore.vacant(state, submission.lane);
            const owner = support.requestOwner(worker_index, request_index, request, submission);
            const token = try support.requestToken(
                worker_index,
                request_index,
                request,
                upload_validation.expectedKind(std.meta.activeTag(submission.request)),
            );
            const cookie = Cookie{
                .lane = submission.lane,
                .connection_index = request.connection_index,
                .request_index = request_index,
                .request_generation = request.generation,
                .registry_index = submission.registry_index,
                .instance_index = submission.instance_index,
                .target = token,
            };
            try support.submitTarget(
                transport,
                io,
                owner,
                token,
                @as(TransportCookie, .{ .request = cookie }),
                submission.request,
            );
            request.sequence = reactor.nextSequence(request.sequence);
            state.entries[slot] = .{
                .lane = submission.lane,
                .target = token,
                .kind = std.meta.activeTag(submission.request),
                .submitted_ns = now_ns,
                .registry_index = submission.registry_index,
                .instance_index = submission.instance_index,
                .active = true,
            };
            state.active += 1;
            syncInflight(request, state);
        }

        fn applicationFailed(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            workspace: []u8,
            problem: anytype,
            now_ns: u64,
        ) Error!ApplicationFailureResult {
            const source = App.__multipartTerminalSource(&request.workspace, workspace) catch
                return error.ApplicationFailure;
            clearWindowFull(state);
            if (try request_failure.nonSink(
                Error,
                RequestCleanup,
                Event,
                source,
                problem,
                transport,
                metrics,
                worker_index,
                io,
                request_index,
                request,
                state,
                now_ns,
                &self.failure_identity,
            )) |event| return .{ .event = event };
            if (request.flags.upload_finalizing) return .continue_finalization;
            support.latchSinkFailure(request, state);
            try request_cancel.cancelApplicationTargets(
                Error,
                transport,
                metrics,
                worker_index,
                io,
                request,
                state,
                &self.failure_identity,
            );
            if (state.active != 0) return .{ .event = .none };
            return .{ .event = try self.startAbort(
                transport,
                metrics,
                worker_index,
                storage,
                io,
                request_index,
                request,
                state,
                now_ns,
            ) };
        }

        pub fn startAbort(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            request: *Storage.Request,
            state: *RequestState,
            now_ns: u64,
        ) Error!Event {
            if (state.active != 0 or state.abort_cause == null) return error.StateInvariant;
            const workspace = try support.bodyWorkspace(storage, request_index);
            clearWindowFull(state);
            request.flags.upload_parser_paused = false;
            request.flags.upload_cancel_requested = false;
            request.flags.upload_cancel_peer = false;
            request.flags.upload_finalizing = true;
            request.flags.upload_response_failed = true;
            App.__cancelMultipart(&request.workspace, state.abort_cause.?) catch
                return error.ApplicationFailure;
            const flow = App.__startMultipartFinalization(&request.workspace, workspace) catch
                return error.ApplicationFailure;
            return self.advanceFinalization(
                transport,
                metrics,
                worker_index,
                storage,
                io,
                request_index,
                workspace,
                request,
                state,
                flow,
                now_ns,
            );
        }

        pub fn advanceFinalization(
            self: *Self,
            transport: *Transport,
            metrics: *RouteRecorder,
            worker_index: u16,
            storage: *Storage,
            io: *Reactor,
            request_index: u16,
            workspace: []u8,
            request: *Storage.Request,
            state: *RequestState,
            initial: ?upload_dispatch.FinalizationFlow,
            now_ns: u64,
        ) Error!Event {
            var steps: u32 = 0;
            var flow = initial orelse App.__multipartFinalizationFlow(
                &request.workspace,
                workspace,
            ) catch return error.ApplicationFailure;
            while (true) : (steps += 1) {
                if (steps > App.upload_request_handles_max + App.upload_window_max) {
                    return error.StateInvariant;
                }
                switch (flow) {
                    .progress => flow = App.__multipartFinalizationFlow(
                        &request.workspace,
                        workspace,
                    ) catch return error.ApplicationFailure,
                    .paused => {
                        const filled = try self.fill(
                            transport,
                            metrics,
                            worker_index,
                            storage,
                            io,
                            request_index,
                            request,
                            state,
                            now_ns,
                        );
                        if (filled.continue_finalization) {
                            flow = App.__multipartFinalizationFlow(
                                &request.workspace,
                                workspace,
                            ) catch return error.ApplicationFailure;
                            continue;
                        }
                        return .none;
                    },
                    .complete => break,
                }
            }
            if (!try RequestCleanup.sweepOwned(
                transport,
                worker_index,
                io,
                request_index,
                request,
                state,
                now_ns,
                &self.failure_identity,
            )) return .none;
            return RequestCleanup.finishTerminal(
                metrics,
                request_index,
                request,
                state,
                workspace,
            );
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

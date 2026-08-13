const application = @import("../../../application.zig");
const connection_body_transport = @import("body_transport.zig");
const connection_stream_transport = @import("stream_transport.zig");
const reactor = @import("../reactor.zig");

/// Binds the pure stream state machine to one connection and its response staging.
pub fn Transport(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
) type {
    const enabled = if (@hasDecl(App, "stream_enabled")) App.stream_enabled else false;

    return struct {
        const Self = @This();
        const BodyTransport = connection_body_transport.Transport(
            App,
            Storage,
            DriverError,
        );
        const StreamState = connection_stream_transport.State(App);

        pub fn begin(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            prepared: application.Prepared,
            now_ns: u64,
        ) DriverError!void {
            if (comptime !enabled) return error.StateInvariant;
            const invoke = switch (prepared.transmission) {
                .finite => return error.StateInvariant,
                .stream => |stream| stream.framing.invoke_stream,
            };
            const wake = if (invoke)
                driver.storage.stream_wakes.activate(request_index) catch {
                    return failInitialization(driver, connection_index, request_index);
                }
            else
                null;
            const request = &driver.storage.requests[request_index];
            const action = request.stream_transport.state.init(
                &request.workspace,
                prepared,
                driver.storage.responseRegion(request_index),
                wake,
                request.workspace.pending.success_transport,
            ) catch {
                if (wake) |value| {
                    const result = driver.storage.stream_wakes.invalidateBeforeAbort(value);
                    if (result != .invalidated) return error.StateInvariant;
                }
                return failInitialization(driver, connection_index, request_index);
            };
            if (request.stream_transport.timeout_cancel_target_sequence != 0 or
                request.stream_transport.timeout_cancel_operation_sequence != 0)
            {
                return error.StateInvariant;
            }
            request.stream_transport.active = true;
            request.stream_transport.full_clear_required = false;
            try apply(driver, connection_index, request_index, action, now_ns, true);
        }

        pub fn completeBuffer(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!bool {
            if (comptime !enabled) return false;
            const request_index = activeRequest(driver, connection_index) orelse return false;
            const state = stateAt(driver, request_index);
            if (!state.bufferCompletionFinishesResponse()) {
                _ = driver.storage.responseWritable(request_index);
            }
            const action = state.sent() catch return error.StateInvariant;
            try apply(driver, connection_index, request_index, action, now_ns, false);
            return true;
        }

        pub fn handleReady(
            driver: anytype,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            if (comptime !enabled) return;
            if (request_index >= driver.storage.requests.len) return;
            const request = &driver.storage.requests[request_index];
            if (request.phase != .live or !request.stream_transport.active) return;
            const connection_index = request.connection_index;
            const connection = &driver.storage.connections[connection_index];
            if (connection.phase != .responding or connection.send_token != null) return;
            if (request.stream_transport.state.phase() != .waiting) return;
            if (timeoutCancellationPending(request)) {
                request.stream_transport.poll_ready = true;
                return;
            }
            request.stream_transport.poll_ready = false;
            const action = request.stream_transport.state.ready() catch {
                return error.StateInvariant;
            };
            try apply(driver, connection_index, request_index, action, now_ns, false);
        }

        /// Performs at most one immediate poll after a lost-wake interlock.
        pub fn pollDeferred(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!void {
            if (comptime !enabled) return;
            const request_index = activeRequest(driver, connection_index) orelse return;
            const request = &driver.storage.requests[request_index];
            if (!request.stream_transport.poll_ready) return;
            try handleReady(driver, request_index, now_ns);
        }

        /// Defers settlement until any submitted SEND no longer owns staging.
        pub fn cancelActive(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
            now_ns: u64,
        ) DriverError!void {
            if (comptime !enabled) return;
            const request_index = activeRequest(driver, connection_index) orelse return;
            const connection = &driver.storage.connections[connection_index];
            const request = &driver.storage.requests[request_index];
            if (request.stream_transport.cancel_outcome == null) {
                request.stream_transport.cancel_outcome = outcome;
            }
            request.stream_transport.poll_ready = false;
            if (connection.send_token != null) return;
            const selected = request.stream_transport.cancel_outcome.?;
            request.stream_transport.cancel_outcome = null;
            const action = request.stream_transport.state.cancel(selected) catch {
                return error.StateInvariant;
            };
            try apply(driver, connection_index, request_index, action, now_ns, false);
        }

        pub fn active(driver: anytype, connection_index: u16) bool {
            if (comptime !enabled) return false;
            return activeRequest(driver, connection_index) != null;
        }

        pub fn bufferCompletionWinsClose(
            driver: anytype,
            connection_index: u16,
        ) bool {
            if (comptime !enabled) return false;
            const request_index = activeRequest(driver, connection_index) orelse return false;
            return stateAt(driver, request_index).bufferCompletionFinishesResponse();
        }

        pub fn operationCompleted(
            driver: anytype,
            connection_index: u16,
            kind: reactor.OperationKind,
            sequence: u16,
        ) void {
            if (comptime !enabled) return;
            const request_index = activeRequest(driver, connection_index) orelse return;
            const stream = &driver.storage.requests[request_index].stream_transport;
            if (kind == .timeout and stream.timeout_cancel_target_sequence == sequence) {
                stream.timeout_cancel_target_sequence = 0;
            }
            if (kind == .cancel and stream.timeout_cancel_operation_sequence == sequence) {
                stream.timeout_cancel_operation_sequence = 0;
            }
        }

        fn apply(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            first: connection_stream_transport.Action,
            now_ns: u64,
            initial: bool,
        ) DriverError!void {
            var action = first;
            var invalidated = false;
            while (true) switch (action) {
                .send => |value| return stageSend(
                    driver,
                    connection_index,
                    request_index,
                    value,
                    now_ns,
                    initial,
                ),
                .pending => {
                    const request = &driver.storage.requests[request_index];
                    request.stream_transport.poll_ready = false;
                    request.stream_transport.full_clear_required = true;
                    try cancelTimeoutOnce(driver, connection_index, request_index);
                    return;
                },
                .poll_ready => {
                    const request = &driver.storage.requests[request_index];
                    request.stream_transport.poll_ready = true;
                    request.stream_transport.full_clear_required = true;
                    try cancelTimeoutOnce(driver, connection_index, request_index);
                    return;
                },
                .invalidate => {
                    if (invalidated) return error.StateInvariant;
                    invalidated = true;
                    const state = stateAt(driver, request_index);
                    const wake = state.wake() orelse return error.StateInvariant;
                    const result = driver.storage.stream_wakes.invalidateBeforeAbort(wake);
                    action = state.invalidated(result) catch return error.StateInvariant;
                },
                .finished => |outcome| return finish(
                    driver,
                    connection_index,
                    request_index,
                    outcome,
                    now_ns,
                ),
            };
        }

        fn stageSend(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            send: connection_stream_transport.Send,
            now_ns: u64,
            initial: bool,
        ) DriverError!void {
            const request = &driver.storage.requests[request_index];
            const committed = if (send.kind == .terminal or
                request.stream_transport.full_clear_required)
                driver.storage.commitResponsePreservingFullDirty(request_index, send.bytes)
            else
                driver.storage.commitResponse(request_index, send.bytes);
            if (!committed) {
                return error.StateInvariant;
            }
            if (initial) return BodyTransport.beginFinal(
                driver,
                connection_index,
                driver.storage.connections[connection_index].close_after_response,
                now_ns,
            );
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                Storage.runtime_limits.timeouts.write_stall_ns,
            );
            try driver.operations.submitSend(
                driver.storage,
                connection_index,
                send.bytes,
            );
        }

        fn finish(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            transport: application.TransportOutcome,
            now_ns: u64,
        ) DriverError!void {
            const request = &driver.storage.requests[request_index];
            const outcome = terminal: {
                if (success(transport)) {
                    break :terminal App.complete(&request.workspace) catch
                        return error.StateInvariant;
                }
                break :terminal App.__abortWithTransport(
                    &request.workspace,
                    transport,
                ) catch {
                    return error.StateInvariant;
                };
            };
            driver.observation.finish(request_index, outcome) catch
                return error.StateInvariant;
            request.stream_transport.active = false;
            request.stream_transport.poll_ready = false;
            request.stream_transport.full_clear_required = false;
            request.stream_transport.timeout_cancel_target_sequence = 0;
            request.stream_transport.timeout_cancel_operation_sequence = 0;
            request.stream_transport.cancel_outcome = null;
            const closing = driver.storage.connections[connection_index].phase == .closing;
            const close_after = driver.storage.connections[connection_index].close_after_response;
            try driver.releaseRequest(connection_index, request_index);
            if (closing) return;
            if (!success(transport) or close_after) return driver.beginClose(connection_index);
            try driver.operations.cancelTimeout(driver.storage, connection_index);
            try driver.maybeContinue(connection_index, now_ns);
        }

        fn failInitialization(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
        ) DriverError!void {
            const outcome = App.__abortWithTransport(
                &driver.storage.requests[request_index].workspace,
                .framework_canceled,
            ) catch return error.StateInvariant;
            driver.observation.finish(request_index, outcome) catch
                return error.StateInvariant;
            try driver.releaseRequest(connection_index, request_index);
            try driver.beginClose(connection_index);
            return error.StateInvariant;
        }

        fn activeRequest(driver: anytype, connection_index: u16) ?u16 {
            const request_index =
                driver.storage.connections[connection_index].active_request orelse return null;
            const request = &driver.storage.requests[request_index];
            if (!request.stream_transport.active) return null;
            return request_index;
        }

        fn stateAt(driver: anytype, request_index: u16) *StreamState {
            return &driver.storage.requests[request_index].stream_transport.state;
        }

        fn cancelTimeoutOnce(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
        ) DriverError!void {
            const request = &driver.storage.requests[request_index];
            if (timeoutCancellationPending(request)) return;
            const target = driver.storage.connections[connection_index].timeout_token orelse {
                return;
            };
            const target_sequence = target.fields() catch return error.StateInvariant;
            const cancel = try driver.operations.submitCancelTracked(
                driver.storage,
                connection_index,
                target,
            );
            const cancel_sequence = cancel.fields() catch return error.StateInvariant;
            request.stream_transport.timeout_cancel_target_sequence = target_sequence.sequence;
            request.stream_transport.timeout_cancel_operation_sequence = cancel_sequence.sequence;
        }

        fn timeoutCancellationPending(request: anytype) bool {
            return request.stream_transport.timeout_cancel_target_sequence != 0 or
                request.stream_transport.timeout_cancel_operation_sequence != 0;
        }
    };
}

fn success(outcome: application.TransportOutcome) bool {
    return outcome == .completed or outcome == .head_suppressed;
}

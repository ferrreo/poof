const application = @import("../../../application.zig");
const application_pipeline_support = @import("../../application/pipeline_support.zig");
const application_types = @import("../../application/types.zig");
const upload_finalizer = @import("../../upload/finalizer.zig");
const connection_body_finalization = @import("body_finalization.zig");
const connection_completion = @import("completion.zig");
const connection_invariants = @import("invariants.zig");
const reactor = @import("../reactor.zig");

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
    comptime BodyTransport: type,
    comptime GzipTransport: type,
    comptime ResponseTransport: type,
) type {
    return struct {
        pub fn handleTimeout(
            driver: anytype,
            connection_index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) DriverError!void {
            const connection = getConnection(driver, connection_index);
            const current = if (connection.timeout_token) |token|
                token.eql(completion.token)
            else
                false;
            if (!current) return;
            connection.timeout_token = null;
            const deadline_ns = connection.timeout_deadline_ns;
            connection.timeout_deadline_ns = 0;
            const timeout_extended = connection.receive_flags.timeout_extended;
            connection.receive_flags.timeout_extended = false;
            switch (completion.result) {
                .success => try handleTimeoutSuccess(
                    driver,
                    connection_index,
                    deadline_ns,
                    timeout_extended,
                    now_ns,
                ),
                .failure => |problem| if (problem != .canceled) {
                    try beginClose(driver, connection_index);
                } else if (connection.phase == .closing or
                    (connection.phase == .responding and connection.send_token == null))
                {
                    try driver.maybeContinue(connection_index, now_ns);
                } else {
                    try driver.operations.submitTimeoutAt(
                        driver.storage,
                        connection_index,
                        deadline_ns,
                    );
                },
            }
        }

        fn handleTimeoutSuccess(
            driver: anytype,
            connection_index: u16,
            deadline_ns: u64,
            timeout_extended: bool,
            now_ns: u64,
        ) DriverError!void {
            const connection = getConnection(driver, connection_index);
            if (timeout_extended and now_ns < deadline_ns) {
                try driver.operations.submitTimeoutAt(
                    driver.storage,
                    connection_index,
                    deadline_ns,
                );
                return;
            }
            if (try BodyTransport.handleTimeout(
                driver,
                connection_index,
                deadline_ns,
                now_ns,
            )) return;
            if (connection.phase == .responding and
                ResponseTransport.liveStaticActive(driver, connection_index))
            {
                try beginCloseWithOutcome(driver, connection_index, .write_stalled);
            } else if (connection.phase == .responding and connection.send_token == null) {
                try driver.maybeContinue(connection_index, now_ns);
            } else if (connection.phase == .responding and connection.send_token != null) {
                try beginCloseWithOutcome(driver, connection_index, .write_stalled);
            } else if (connection.proxy_protocol.pending()) {
                try beginClose(driver, connection_index);
            } else if (connection_invariants.headTimeoutResponseSafe(connection)) {
                try driver.startRejection(
                    connection_index,
                    .{ .status = .request_timeout },
                    now_ns,
                );
            } else {
                try beginClose(driver, connection_index);
            }
        }

        pub fn handleClose(
            driver: anytype,
            connection_index: u16,
            completion: reactor.Completion,
        ) DriverError!void {
            const connection = getConnection(driver, connection_index);
            const current = if (connection.close_token) |token|
                token.eql(completion.token)
            else
                false;
            if (!current) return;
            connection_completion.completeClose(connection, completion) catch {
                return error.BackendFailure;
            };
        }

        pub fn beginClose(driver: anytype, connection_index: u16) DriverError!void {
            return beginCloseWithOutcome(driver, connection_index, .framework_canceled);
        }

        pub fn beginCloseWithOutcome(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
        ) DriverError!void {
            const connection = getConnection(driver, connection_index);
            connection.proxy_protocol.abandon();
            if (connection.active_request != null and closeOutcome(connection) == null) {
                connection.receive_flags.close_outcome =
                    @intCast(@intFromEnum(outcome) + 1);
            }
            const selected_outcome = closeOutcome(connection) orelse outcome;
            if (connection.phase == .closing) {
                _ = try driver.cancelMetricsForClose(connection_index);
                try settleClosingUpload(driver, connection_index, selected_outcome);
                try ResponseTransport.cancelLiveStatic(
                    driver,
                    connection_index,
                    selected_outcome,
                );
                try ResponseTransport.cancelStream(
                    driver,
                    connection_index,
                    selected_outcome,
                    0,
                );
                try submitCloseWhenStreamSettled(driver, connection_index);
                try maybeRelease(driver, connection_index);
                return;
            }
            try latchSynchronousUploadAbort(driver, connection_index, selected_outcome);
            _ = try driver.cancelMetricsForClose(connection_index);
            try GzipTransport.cancelActive(driver, connection_index);
            try driver.abortUploadRequest(connection_index, selected_outcome);
            try ResponseTransport.cancelLiveStatic(
                driver,
                connection_index,
                selected_outcome,
            );
            connection.phase = .closing;
            connection.close_after_response = true;
            connection.receive_flags.paused = false;
            connection.receive_flags.gzip_rejecting = false;
            if (connection.receive_token == null) connection.receive_terminal_reaped = true;
            try ResponseTransport.cancelStream(
                driver,
                connection_index,
                selected_outcome,
                0,
            );
            try submitCloseWhenStreamSettled(driver, connection_index);
            try driver.operations.cancelReceive(driver.storage, connection_index);
            try driver.operations.cancelTimeout(driver.storage, connection_index);
            if (connection.send_token) |token| {
                try driver.operations.submitCancel(driver.storage, connection_index, token);
            }
            try maybeRelease(driver, connection_index);
        }

        pub fn maybeRelease(driver: anytype, connection_index: u16) DriverError!void {
            const connection = getConnection(driver, connection_index);
            if (connection.phase != .closing) return;
            if (ResponseTransport.streamActive(driver, connection_index) and
                connection.send_token == null)
            {
                try ResponseTransport.cancelStream(
                    driver,
                    connection_index,
                    .framework_canceled,
                    0,
                );
            }
            try submitCloseWhenStreamSettled(driver, connection_index);
            if (!ResponseTransport.streamActive(driver, connection_index) and
                !ResponseTransport.liveStaticActive(driver, connection_index) and
                GzipTransport.requestReleaseReady(driver, connection_index) and
                driver.metricsRequestReleaseReady(connection_index))
            {
                try settleClosingUpload(driver, connection_index, .framework_canceled);
                const request_index = connection.active_request.?;
                const request = &driver.storage.requests[request_index];
                if (request.flags.upload_inflight or
                    request.flags.upload_parser_paused or
                    request.flags.upload_finalizing or
                    request.flags.upload_cancel_requested)
                {
                    return;
                }
                if (!try driver.completeObservedFallback(connection_index)) {
                    const transport = closeOutcome(connection) orelse .framework_canceled;
                    const outcome = App.__abortWithTransport(
                        &request.workspace,
                        transport,
                    ) catch return error.StateInvariant;
                    driver.observation.finish(request_index, outcome) catch
                        return error.StateInvariant;
                    try driver.releaseRequest(connection_index, request_index);
                }
            }
            if (connection.receive_token == null and connection.send_token == null and
                connection.timeout_token == null and connection.close_token == null and
                connection.active_request == null and connection.inflight_operations == 0 and
                connection.receive_terminal_reaped)
            {
                driver.storage.releaseConnection(connection_index);
            }
        }

        fn closeOutcome(connection: anytype) ?application.TransportOutcome {
            const encoded = connection.receive_flags.close_outcome;
            if (encoded == 0) return null;
            return @enumFromInt(encoded - 1);
        }

        fn settleClosingUpload(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
        ) DriverError!void {
            if (!GzipTransport.requestReleaseReady(driver, connection_index)) return;
            const connection = getConnection(driver, connection_index);
            const request_index = connection.active_request orelse return;
            const request = &driver.storage.requests[request_index];
            if (request.flags.upload_rejection_pending) {
                if (comptime Storage.body_workspace_bytes_per_slot == 0) {
                    return error.StateInvariant;
                } else {
                    request.flags.upload_rejection_pending = false;
                    request.body.used = 0;
                }
            }
            try driver.abortUploadRequest(connection_index, outcome);
            try settleSynchronousUpload(driver, request_index);
        }

        fn latchSynchronousUploadAbort(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
        ) DriverError!void {
            if (comptime Storage.upload_async_enabled or
                !application_pipeline_support.multipartFinalizationEnabled(App.Workspace))
            {
                return;
            }
            const connection = getConnection(driver, connection_index);
            const request_index = connection.active_request orelse return;
            const request = &driver.storage.requests[request_index];
            if (!connection_body_finalization.required(request) or
                request.workspace.multipart_abort_cause != null)
            {
                return;
            }
            const cause: upload_finalizer.UpstreamFailure = if (outcome == .peer_aborted)
                .peer_disconnect
            else
                .framework_canceled;
            App.__cancelMultipart(&request.workspace, cause) catch {
                return error.StateInvariant;
            };
        }

        fn settleSynchronousUpload(
            driver: anytype,
            request_index: u16,
        ) DriverError!void {
            if (comptime Storage.upload_async_enabled or
                !application_pipeline_support.multipartFinalizationEnabled(App.Workspace))
            {
                return;
            }
            const request = &driver.storage.requests[request_index];
            if (!connection_body_finalization.required(request)) return;
            const cause = request.workspace.multipart_abort_cause orelse
                return error.StateInvariant;
            const finalized = connection_body_finalization.begin(
                App,
                driver.storage,
                request_index,
                .{ .consumed = 0, .event = .prepared, .close_connection = true },
                false,
                cause,
            ) catch |problem| {
                if (problem != error.ApplicationFailure or
                    application_types.multipartCleanupPending(&request.workspace))
                {
                    return switch (problem) {
                        error.ApplicationFailure => error.UploadFailure,
                        else => error.StateInvariant,
                    };
                }
                try driver.recordUploadFinalization(request_index);
                return;
            };
            if (finalized.event != .prepared) return error.StateInvariant;
            try driver.recordUploadFinalization(request_index);
        }

        pub fn submitCloseWhenStreamSettled(
            driver: anytype,
            connection_index: u16,
        ) DriverError!void {
            const connection = getConnection(driver, connection_index);
            if (connection.close_token != null or connection.socket_closed) return;
            if (ResponseTransport.streamActive(driver, connection_index)) return;
            try driver.operations.submitClose(driver.storage, connection_index);
        }

        fn getConnection(driver: anytype, connection_index: u16) *Storage.Connection {
            return &driver.storage.connections[connection_index];
        }
    };
}

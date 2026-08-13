const connection_body_runtime = @import("body_runtime.zig");
const connection_body_transitions = @import("body_transitions.zig");
const gzip_decoder_pool = @import("../gzip/decoder_pool.zig");
const gzip_request_jobs = @import("../gzip/request_jobs.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn Handler(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
    comptime InputTransport: type,
) type {
    return struct {
        const runtime_limits = Storage.runtime_limits;
        const BodyTransitions = connection_body_transitions.Transitions(
            App,
            Storage,
            DriverError,
        );
        const beginFinal = BodyTransitions.beginFinal;
        const handleRuntimeError = BodyTransitions.handleRuntimeError;

        pub fn handleGzipSignals(
            driver: anytype,
            slot_index: u16,
            signals: gzip_decoder_pool.Signals,
            now_ns: u64,
        ) DriverError!void {
            if (signals.output) {
                const output = gzip_request_jobs.consumeOutput(
                    driver.storage,
                    slot_index,
                    signals,
                ) catch return error.StateInvariant;
                if (output) |borrowed| {
                    driver.observation.addRequestDecoded(
                        borrowed.owner.request_index,
                        borrowed.bytes.len,
                    ) catch return error.StateInvariant;
                    try handleOutput(driver, borrowed, now_ns);
                }
            }
            const event = gzip_request_jobs.consumeSlot(
                driver.storage,
                slot_index,
                signals,
            ) catch return error.StateInvariant;
            switch (event) {
                .none => {},
                .space => |owner| try resumeForSpace(driver, owner, now_ns),
                .terminal => |terminal| try handleTerminal(driver, terminal, now_ns),
            }
        }

        fn handleOutput(
            driver: anytype,
            output: gzip_request_jobs.Output,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[output.owner.connection_index];
            if (connection.phase != .receiving_body) return error.StateInvariant;
            const request = &driver.storage.requests[output.owner.request_index];
            if (!request.body.multipart) return error.StateInvariant;
            if (comptime !Storage.upload_async_enabled) {
                return handleLegacyOutput(driver, output);
            }
            const offset: usize = request.body.used;
            if (offset > output.bytes.len) return error.StateInvariant;
            const result = connection_body_runtime.appendMultipartProgress(
                App,
                driver.storage,
                output.owner.request_index,
                output.bytes[offset..],
            ) catch |problem| {
                try handleRuntimeError(
                    driver,
                    output.owner.connection_index,
                    problem,
                    now_ns,
                );
                return;
            };
            if (result.consumed > output.bytes.len - offset) return error.StateInvariant;
            request.body.used = @intCast(offset + result.consumed);
            switch (result.event) {
                .need_more => {
                    if (request.body.used != output.bytes.len) {
                        return error.StateInvariant;
                    }
                    try acknowledgeOutput(driver, output);
                },
                .upload_paused => {
                    try pauseUpload(
                        driver,
                        output.owner.connection_index,
                        output.owner.request_index,
                        now_ns,
                    );
                },
                .invalid_input, .input_too_large, .unsupported_media => {
                    const rejection = outputRejection(result.event) orelse unreachable;
                    try acknowledgeOutput(driver, output);
                    gzip_request_jobs.rejectOutput(
                        driver.storage,
                        output,
                        rejection,
                    ) catch return error.StateInvariant;
                    connection.receive_flags.paused = false;
                    connection.receive_flags.gzip_paused = false;
                    connection.receive_flags.gzip_rejecting = true;
                },
                .prepared => try cancelForSelectedResponse(
                    driver,
                    output,
                    result.close_connection,
                ),
                .invalid_utf8 => return error.StateInvariant,
            }
        }

        fn handleLegacyOutput(
            driver: anytype,
            output: gzip_request_jobs.Output,
        ) DriverError!void {
            const result = connection_body_runtime.appendMultipartChunk(
                App,
                driver.storage,
                output.owner.request_index,
                output.bytes,
            ) catch return error.StateInvariant;
            if (result.consumed != output.bytes.len) return error.StateInvariant;
            switch (result.event) {
                .need_more => try acknowledgeOutput(driver, output),
                .prepared => try cancelForSelectedResponse(
                    driver,
                    output,
                    result.close_connection,
                ),
                .invalid_input, .input_too_large, .unsupported_media => {
                    const rejection = outputRejection(result.event) orelse unreachable;
                    gzip_request_jobs.rejectOutput(
                        driver.storage,
                        output,
                        rejection,
                    ) catch return error.StateInvariant;
                    const connection =
                        &driver.storage.connections[output.owner.connection_index];
                    connection.receive_flags.paused = false;
                    connection.receive_flags.gzip_paused = false;
                    connection.receive_flags.gzip_rejecting = true;
                },
                .upload_paused, .invalid_utf8 => return error.StateInvariant,
            }
        }

        fn cancelForSelectedResponse(
            driver: anytype,
            output: gzip_request_jobs.Output,
            close_connection: bool,
        ) DriverError!void {
            const connection = &driver.storage.connections[output.owner.connection_index];
            const request = &driver.storage.requests[output.owner.request_index];
            if (request.body.terminal_response_pending) return error.StateInvariant;
            try acknowledgeOutput(driver, output);
            request.body.terminal_response_pending = true;
            connection.close_after_response = close_connection;
            connection.receive_flags.paused = true;
            gzip_request_jobs.cancel(
                driver.storage,
                output.owner.connection_index,
                output.owner.request_index,
            ) catch return error.StateInvariant;
        }

        fn acknowledgeOutput(driver: anytype, output: gzip_request_jobs.Output) DriverError!void {
            gzip_request_jobs.acknowledgeOutput(
                driver.storage,
                output,
            ) catch return error.StateInvariant;
            driver.storage.requests[output.owner.request_index].body.used = 0;
        }

        fn pauseUpload(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            if (connection.receive_flags.upload_paused or
                connection.receive_flags.multishot)
            {
                return error.StateInvariant;
            }
            connection.receive_flags.paused = true;
            connection.receive_flags.upload_paused = true;
            try driver.submitPausedUpload(request_index, now_ns);
            try @TypeOf(driver.operations).extendTimeoutDeadline(
                driver.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.body_inactivity_ns,
            );
        }

        pub fn resumeUpload(
            driver: anytype,
            resumed: anytype,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[resumed.connection_index];
            if (connection.phase != .receiving_body or
                connection.active_request != resumed.request_index or
                !connection.receive_flags.upload_paused or
                !connection.receive_flags.paused or
                resumed.progress.consumed != 0 or
                resumed.progress.flow == .paused)
            {
                return error.StateInvariant;
            }
            connection.receive_flags.upload_paused = false;
            connection.receive_flags.paused = false;
            const output = (gzip_request_jobs.pendingOutput(
                driver.storage,
                resumed.connection_index,
                resumed.request_index,
            ) catch return error.StateInvariant) orelse return error.StateInvariant;
            const request = &driver.storage.requests[resumed.request_index];
            if (request.body.used == output.bytes.len) {
                try acknowledgeOutput(driver, output);
            } else {
                try handleOutput(driver, output, now_ns);
            }
            if (connection.receive_flags.upload_paused or
                connection.receive_flags.gzip_paused or
                connection.receive_flags.gzip_rejecting or
                connection.phase != .receiving_body)
            {
                return;
            }
            if (connection.pipeline_read < connection.pipeline_write) {
                if (connection.receive_token != null) return error.StateInvariant;
                const pipeline = driver.storage.pipeline(resumed.connection_index);
                return InputTransport.consume(
                    driver,
                    resumed.connection_index,
                    pipeline[connection.pipeline_read..connection.pipeline_write],
                    .pipeline,
                    now_ns,
                );
            }
            if (!inputComplete(driver.storage, resumed.request_index) and
                connection.receive_token == null)
            {
                try driver.operations.submitReceiveForPhase(
                    driver.storage,
                    resumed.connection_index,
                );
            }
        }

        fn outputRejection(
            event: connection_body_runtime.Event,
        ) ?gzip_decoder_pool.OutputRejection {
            return switch (event) {
                .need_more => null,
                .invalid_input => .invalid_input,
                .input_too_large => .input_too_large,
                .unsupported_media => .unsupported_media,
                .upload_paused, .invalid_utf8, .prepared => unreachable,
            };
        }

        pub fn rejectParser(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            status: request_head.Status,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request = &driver.storage.requests[request_index];
            if (connection.phase != .receiving_body or
                connection.active_request != request_index or
                !connection.receive_flags.upload_paused or
                !connection.receive_flags.paused or
                request.flags.upload_rejection_pending)
            {
                return error.StateInvariant;
            }
            const output = (gzip_request_jobs.pendingOutput(
                driver.storage,
                connection_index,
                request_index,
            ) catch return error.StateInvariant) orelse return error.StateInvariant;
            try acknowledgeOutput(driver, output);
            gzip_request_jobs.rejectOutput(
                driver.storage,
                output,
                parserRejection(status) orelse return error.StateInvariant,
            ) catch return error.StateInvariant;
            request.flags.upload_rejection_pending = true;
            request.body.used = @intFromEnum(status);
            connection.receive_flags.paused = false;
            connection.receive_flags.upload_paused = false;
            connection.receive_flags.gzip_paused = false;
            connection.receive_flags.gzip_rejecting = true;
        }

        pub fn settleGzipAfterBackend(
            driver: anytype,
            slot_index: u16,
            signals: gzip_decoder_pool.Signals,
        ) DriverError!void {
            if (!signals.terminal) return;
            const event = gzip_request_jobs.consumeSlot(
                driver.storage,
                slot_index,
                signals,
            ) catch return error.StateInvariant;
            if (event != .terminal) return error.StateInvariant;
        }

        fn resumeForSpace(
            driver: anytype,
            owner: gzip_decoder_pool.Owner,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[owner.connection_index];
            if (connection.phase == .closing) return;
            if (connection.phase != .receiving_body) return error.StateInvariant;
            if (connection.receive_flags.upload_paused) return;
            if (connection.receive_flags.gzip_rejecting or
                !connection.receive_flags.gzip_paused or
                inputComplete(driver.storage, owner.request_index)) return;
            if (connection.receive_token != null) return error.StateInvariant;
            connection.receive_flags.gzip_paused = false;
            if (connection.pipeline_read < connection.pipeline_write) {
                const pipeline = driver.storage.pipeline(owner.connection_index);
                const input = pipeline[connection.pipeline_read..connection.pipeline_write];
                try InputTransport.consume(
                    driver,
                    owner.connection_index,
                    input,
                    .pipeline,
                    now_ns,
                );
            }
            if (connection.phase == .receiving_body and
                !connection.receive_flags.gzip_paused and
                !connection.receive_flags.gzip_rejecting)
            {
                try driver.operations.submitReceiveForPhase(
                    driver.storage,
                    owner.connection_index,
                );
            }
        }

        fn inputComplete(storage: *Storage, request_index: u16) bool {
            const request = &storage.requests[request_index];
            if (request.chunked_workspace_index != null) {
                const state = storage.chunkedState(request_index) catch return false;
                return state.trailers() != null;
            }
            return request.body.receiver.complete();
        }

        fn handleTerminal(
            driver: anytype,
            terminal: anytype,
            now_ns: u64,
        ) DriverError!void {
            const connection_index = terminal.owner.connection_index;
            const connection = &driver.storage.connections[connection_index];
            connection.receive_flags.gzip_paused = false;
            connection.receive_flags.gzip_rejecting = false;
            const request = &driver.storage.requests[terminal.owner.request_index];
            switch (terminal.result) {
                .complete => |counts| if (!request.body.multipart) {
                    driver.observation.addRequestDecoded(
                        terminal.owner.request_index,
                        counts.decoded,
                    ) catch return error.StateInvariant;
                },
                else => {},
            }
            if (request.body.terminal_response_pending) {
                const canceled = switch (terminal.result) {
                    .canceled => true,
                    else => false,
                };
                if (connection.phase != .receiving_body or
                    !canceled or
                    terminal.rejection != null)
                {
                    return error.StateInvariant;
                }
                if (request.flags.upload_finalizing) return;
                request.body.terminal_response_pending = false;
                connection.receive_flags.paused = false;
                connection.receive_flags.upload_paused = false;
                return beginFinal(
                    driver,
                    connection_index,
                    connection.close_after_response,
                    now_ns,
                );
            }
            if (connection.phase == .closing) return driver.beginClose(connection_index);
            if (connection.phase != .receiving_body) return error.StateInvariant;
            if (terminal.rejection) |rejection| {
                return stageRejection(
                    driver,
                    connection_index,
                    rejectionStatus(rejection),
                    now_ns,
                );
            }
            if (InputTransport.pendingRejectionStatus(
                driver,
                terminal.owner.request_index,
            )) |status| {
                return stageRejection(driver, connection_index, status, now_ns);
            }
            return switch (terminal.result) {
                .complete => finishDecoded(
                    driver,
                    connection_index,
                    terminal.owner.request_index,
                    now_ns,
                ),
                .malformed, .read_failed => stageRejection(
                    driver,
                    connection_index,
                    .bad_request,
                    now_ns,
                ),
                .over_limit => stageRejection(
                    driver,
                    connection_index,
                    .payload_too_large,
                    now_ns,
                ),
                .canceled => driver.beginClose(connection_index),
            };
        }

        fn rejectionStatus(rejection: gzip_decoder_pool.OutputRejection) request_head.Status {
            return switch (rejection) {
                .invalid_input => .bad_request,
                .input_too_large => .payload_too_large,
                .unsupported_media => .unsupported_media_type,
            };
        }

        fn parserRejection(
            status: request_head.Status,
        ) ?gzip_decoder_pool.OutputRejection {
            return switch (status) {
                .bad_request => .invalid_input,
                .payload_too_large => .input_too_large,
                .unsupported_media_type => .unsupported_media,
                else => null,
            };
        }

        fn finishDecoded(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const result = finishRequest(driver.storage, request_index) catch |problem| {
                try handleRuntimeError(driver, connection_index, problem, now_ns);
                return;
            };
            if (result.consumed != 0) return error.StateInvariant;
            try driver.recordUploadFinalization(request_index);
            switch (result.event) {
                .need_more => return error.StateInvariant,
                .upload_paused => try pauseUpload(
                    driver,
                    connection_index,
                    request_index,
                    now_ns,
                ),
                .prepared => try beginFinal(
                    driver,
                    connection_index,
                    result.close_connection,
                    now_ns,
                ),
                .invalid_utf8 => try stageRejection(
                    driver,
                    connection_index,
                    .bad_request,
                    now_ns,
                ),
                .invalid_input => try stageRejection(
                    driver,
                    connection_index,
                    .bad_request,
                    now_ns,
                ),
                .input_too_large => try stageRejection(
                    driver,
                    connection_index,
                    .payload_too_large,
                    now_ns,
                ),
                .unsupported_media => try stageRejection(
                    driver,
                    connection_index,
                    .unsupported_media_type,
                    now_ns,
                ),
            }
        }

        fn finishRequest(
            storage: *Storage,
            request_index: u16,
        ) connection_body_runtime.Error!connection_body_runtime.FeedResult {
            const request = &storage.requests[request_index];
            if (request.chunked_workspace_index != null) {
                const state = storage.chunkedState(request_index) catch {
                    return error.StateInvariant;
                };
                const trailers = state.trailers() orelse return error.StateInvariant;
                return if (request.body.multipart)
                    connection_body_runtime.finishMultipartChunked(
                        App,
                        storage,
                        request_index,
                        trailers,
                    )
                else
                    connection_body_runtime.finishChunked(
                        App,
                        storage,
                        request_index,
                        trailers,
                    );
            }
            return if (request.body.multipart)
                connection_body_runtime.finishMultipartGzipFixed(App, storage, request_index)
            else
                connection_body_runtime.finishGzipFixed(App, storage, request_index);
        }

        fn stageRejection(
            driver: anytype,
            connection_index: u16,
            status: request_head.Status,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request_index = connection.active_request orelse return error.StateInvariant;
            const request = &driver.storage.requests[request_index];
            if (request.flags.upload_rejection_pending) {
                const pending = request_head.Status.fromInt(
                    @intCast(request.body.used),
                ) catch return error.StateInvariant;
                if (pending != status) return error.StateInvariant;
                if (request.flags.upload_cancel_requested or
                    request.flags.upload_finalizing)
                {
                    connection.receive_flags.paused = true;
                    connection.receive_flags.upload_paused = true;
                    connection.close_after_response = true;
                    return driver.submitPausedUpload(request_index, now_ns);
                }
                request.flags.upload_rejection_pending = false;
                request.body.used = 0;
            }
            const result = connection_body_runtime.stageRejection(
                App,
                driver.storage,
                request_index,
                status,
                driver.runtime_fields,
            ) catch |problem| {
                try driver.beginClose(connection_index);
                return switch (problem) {
                    error.ResponseSerializationFailed => error.ResponseSerializationFailed,
                    else => error.StateInvariant,
                };
            };
            try driver.recordUploadFinalization(request_index);
            switch (result.event) {
                .upload_paused => try pauseUpload(
                    driver,
                    connection_index,
                    request_index,
                    now_ns,
                ),
                .prepared => try beginFinal(driver, connection_index, true, now_ns),
                else => return error.StateInvariant,
            }
        }
    };
}

const connection_body_feed = @import("body_feed.zig");
const connection_body_runtime = @import("body_runtime.zig");

pub fn Bridge(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
    comptime InputSource: type,
    comptime GzipTransport: type,
    comptime Parent: type,
) type {
    const runtime_limits = Storage.runtime_limits;

    return struct {
        pub fn resumeUpload(
            driver: anytype,
            resumed: anytype,
            now_ns: u64,
        ) DriverError!void {
            if (GzipTransport.active(driver, resumed.connection_index)) {
                return GzipTransport.resumeUpload(driver, resumed, now_ns);
            }
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
            try continueUpload(
                driver,
                resumed.connection_index,
                resumed.request_index,
                now_ns,
            );
        }

        fn continueUpload(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request = &driver.storage.requests[request_index];
            if (request.body.used != 0) {
                return consumeDecodedTail(driver, connection_index, request_index, now_ns);
            }
            if (connection.pipeline_read < connection.pipeline_write) {
                return consumePipelineTail(
                    driver,
                    connection_index,
                    request_index,
                    now_ns,
                );
            }
            if (request.chunked_workspace_index) |_| {
                const state = driver.storage.chunkedState(request_index) catch {
                    return error.StateInvariant;
                };
                if (state.trailers() != null) {
                    return Parent.finishChunked(
                        driver,
                        connection_index,
                        request_index,
                        &.{},
                        .borrowed,
                        0,
                        state,
                        now_ns,
                    );
                }
            } else if (request.body.receiver.complete()) {
                const result = connection_body_runtime.finishMultipartFixed(
                    App,
                    driver.storage,
                    request_index,
                ) catch |problem| {
                    try Parent.handleRuntimeError(
                        driver,
                        connection_index,
                        problem,
                        now_ns,
                    );
                    return;
                };
                return Parent.applyResult(
                    driver,
                    connection_index,
                    &.{},
                    .borrowed,
                    result,
                    now_ns,
                );
            }
            if (connection.receive_token == null) {
                try driver.operations.submitReceiveForPhase(
                    driver.storage,
                    connection_index,
                );
            }
        }

        fn consumePipelineTail(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const pipeline = driver.storage.pipeline(connection_index);
            try Parent.consume(
                driver,
                connection_index,
                pipeline[connection.pipeline_read..connection.pipeline_write],
                .pipeline,
                now_ns,
            );
            if (connection.phase != .receiving_body or
                connection.active_request != request_index or
                connection.receive_flags.paused or
                connection.receive_flags.upload_paused)
            {
                return;
            }
            if (connection.pipeline_read != connection.pipeline_write) {
                return error.StateInvariant;
            }
            return continueUpload(driver, connection_index, request_index, now_ns);
        }

        fn consumeDecodedTail(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request = &driver.storage.requests[request_index];
            const count: usize = request.body.used;
            const unread = connection.pipeline_write - connection.pipeline_read;
            if (count == 0 or count > unread) return error.StateInvariant;
            const pipeline = driver.storage.pipeline(connection_index);
            const bytes = pipeline[connection.pipeline_read..][0..count];
            const result = connection_body_runtime.appendMultipartProgress(
                App,
                driver.storage,
                request_index,
                bytes,
            ) catch |problem| {
                try Parent.handleRuntimeError(driver, connection_index, problem, now_ns);
                return;
            };
            if (result.consumed > count) return error.StateInvariant;
            try connection_body_feed.advanceSource(
                DriverError,
                driver,
                connection_index,
                result.consumed,
                InputSource.pipeline,
            );
            request.body.used -= @intCast(result.consumed);
            switch (result.event) {
                .need_more => {
                    if (result.consumed != count) return error.StateInvariant;
                    return continueUpload(driver, connection_index, request_index, now_ns);
                },
                .upload_paused => return pauseUpload(
                    driver,
                    connection_index,
                    request_index,
                    now_ns,
                ),
                .invalid_utf8, .invalid_input => {
                    request.body.used = 0;
                    return Parent.reject(driver, connection_index, .bad_request, now_ns);
                },
                .input_too_large => {
                    request.body.used = 0;
                    return Parent.reject(
                        driver,
                        connection_index,
                        .payload_too_large,
                        now_ns,
                    );
                },
                .unsupported_media => {
                    request.body.used = 0;
                    return Parent.reject(
                        driver,
                        connection_index,
                        .unsupported_media_type,
                        now_ns,
                    );
                },
                .prepared => return error.StateInvariant,
            }
        }

        pub fn pauseUpload(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            if (connection.phase != .receiving_body or
                connection.receive_flags.upload_paused or
                connection.receive_flags.multishot)
            {
                return error.StateInvariant;
            }
            connection.receive_flags.paused = true;
            connection.receive_flags.upload_paused = true;
            try @TypeOf(driver.operations).extendTimeoutDeadline(
                driver.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.body_inactivity_ns,
            );
            try driver.submitPausedUpload(request_index, now_ns);
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

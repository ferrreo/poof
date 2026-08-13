const std = @import("std");
const connection_body_feed = @import("body_feed.zig");
const connection_body_runtime = @import("body_runtime.zig");
const connection_body_start = @import("body_start.zig");
const connection_body_transitions = @import("body_transitions.zig");
const connection_body_upload_finish = @import("body_upload_finish.zig");
const connection_body_upload_resume = @import("body_upload_resume.zig");
const connection_gzip_transport = @import("gzip_transport.zig");
const connection_pipeline = @import("pipeline.zig");
const connection_send = @import("send.zig");
const request_head = @import("../../http1/request_head.zig");

pub const InputSource = enum(u8) {
    borrowed,
    pipeline,
};

pub fn Transport(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
) type {
    return struct {
        const Self = @This();
        const runtime_limits = Storage.runtime_limits;
        const GzipTransport = connection_gzip_transport.Transport(App, Storage, DriverError);
        const BodyTransitions = connection_body_transitions.Transitions(
            App,
            Storage,
            DriverError,
        );
        const Start = connection_body_start.Bridge(
            App,
            Storage,
            DriverError,
            InputSource,
            GzipTransport,
            Self,
        );
        const UploadResume = connection_body_upload_resume.Bridge(
            App,
            Storage,
            DriverError,
            InputSource,
            GzipTransport,
            Self,
        );
        const UploadFinish = connection_body_upload_finish.Bridge(App, DriverError, Self);
        pub const beginAfterHead = Start.beginAfterHead;
        pub const begin = Start.begin;
        pub const resumeUpload = UploadResume.resumeUpload;
        pub const finishUploadFinalization = UploadFinish.finish;
        pub const gzipActive = GzipTransport.active;
        pub const beginContinue = BodyTransitions.beginContinue;
        pub const beginFinal = BodyTransitions.beginFinal;
        pub const handleRuntimeError = BodyTransitions.handleRuntimeError;
        const pauseUpload = UploadResume.pauseUpload;

        pub fn consume(
            driver: anytype,
            connection_index: u16,
            input: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request_index = connection.active_request orelse {
                return error.StateInvariant;
            };
            if (GzipTransport.active(driver, connection_index)) {
                return GzipTransport.consume(driver, connection_index, input, source, now_ns);
            }
            if (driver.storage.requests[request_index].chunked_workspace_index != null) {
                return consumeChunked(
                    driver,
                    connection_index,
                    request_index,
                    input,
                    source,
                    now_ns,
                );
            }
            return consumeFixed(
                driver,
                connection_index,
                request_index,
                input,
                source,
                now_ns,
            );
        }

        fn consumeFixed(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const pending = if (connection_body_feed.requestIsMultipart(
                driver.storage,
                request_index,
            ))
                connection_body_runtime.feedMultipartFixed(
                    App,
                    driver.storage,
                    request_index,
                    input,
                )
            else
                connection_body_runtime.feedFixed(
                    App,
                    driver.storage,
                    request_index,
                    input,
                );
            const result = pending catch |problem| {
                try handleRuntimeError(driver, connection_index, problem, now_ns);
                return;
            };
            driver.observation.addRequestDecoded(request_index, result.consumed) catch
                return error.StateInvariant;
            try applyResult(driver, connection_index, input, source, result, now_ns);
        }

        pub fn consumeChunked(
            driver: anytype,
            connection_index: u16,
            request: u16,
            input: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const state = driver.storage.chunkedState(request) catch return error.StateInvariant;
            var consumed: usize = 0;
            while (true) {
                const result = state.feed(input[consumed..]);
                if (result.consumed > input.len - consumed) return error.StateInvariant;
                consumed = std.math.add(usize, consumed, result.consumed) catch
                    return error.StateInvariant;
                switch (result.event) {
                    .data => |data| if (try consumeChunkData(
                        driver,
                        connection_index,
                        request,
                        input,
                        source,
                        consumed,
                        data,
                        result.consumed,
                        now_ns,
                    )) return,
                    .need_more => return applyChunkedResult(
                        driver,
                        connection_index,
                        input,
                        source,
                        consumed,
                        .{ .event = .need_more, .consumed = 0 },
                        now_ns,
                    ),
                    .ready => return finishChunked(
                        driver,
                        connection_index,
                        request,
                        input,
                        source,
                        consumed,
                        state,
                        now_ns,
                    ),
                    .rejected => |rejection| {
                        try connection_body_feed.consumeSource(
                            DriverError,
                            driver,
                            connection_index,
                            consumed,
                            source,
                        );
                        return reject(driver, connection_index, rejection.status, now_ns);
                    },
                }
            }
        }

        fn consumeChunkData(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: InputSource,
            wire_consumed: usize,
            data: []const u8,
            event_consumed: usize,
            now_ns: u64,
        ) DriverError!bool {
            if (data.len == 0 or event_consumed == 0) return error.StateInvariant;
            driver.observation.addRequestDecoded(request_index, data.len) catch
                return error.StateInvariant;
            if (comptime Storage.upload_async_enabled) {
                const multipart = connection_body_feed.requestIsMultipart(
                    driver.storage,
                    request_index,
                );
                if (multipart and try consumeMultipartChunkData(
                    driver,
                    connection_index,
                    request_index,
                    input,
                    source,
                    wire_consumed,
                    data,
                    now_ns,
                )) return true;
                if (multipart) return false;
            }
            const appended = try connection_body_feed.appendChunkData(
                App,
                DriverError,
                driver,
                request_index,
                data,
            );
            if (appended.consumed != data.len) return error.StateInvariant;
            return consumeSynchronousChunkResult(
                driver,
                connection_index,
                source,
                wire_consumed,
                appended,
                now_ns,
            );
        }

        fn consumeSynchronousChunkResult(
            driver: anytype,
            connection_index: u16,
            source: InputSource,
            wire_consumed: usize,
            result: connection_body_runtime.FeedResult,
            now_ns: u64,
        ) DriverError!bool {
            return switch (result.event) {
                .need_more => false,
                .prepared => preparedMultipartChunk(
                    driver,
                    connection_index,
                    source,
                    wire_consumed,
                    result.close_connection,
                    now_ns,
                ),
                .invalid_input, .input_too_large, .unsupported_media => {
                    const status = connection_body_feed.eventStatus(result.event) orelse
                        return error.StateInvariant;
                    return rejectMultipartChunk(
                        driver,
                        connection_index,
                        source,
                        wire_consumed,
                        status,
                        now_ns,
                    );
                },
                .upload_paused, .invalid_utf8 => error.StateInvariant,
            };
        }

        fn preparedMultipartChunk(
            driver: anytype,
            connection_index: u16,
            source: InputSource,
            wire_consumed: usize,
            close_connection: bool,
            now_ns: u64,
        ) DriverError!bool {
            try connection_body_feed.consumeSource(
                DriverError,
                driver,
                connection_index,
                wire_consumed,
                source,
            );
            try beginFinal(driver, connection_index, close_connection, now_ns);
            return true;
        }

        fn consumeMultipartChunkData(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: InputSource,
            wire_consumed: usize,
            data: []const u8,
            now_ns: u64,
        ) DriverError!bool {
            const parsed = connection_body_runtime.appendMultipartProgress(
                App,
                driver.storage,
                request_index,
                data,
            ) catch |problem| {
                try handleRuntimeError(driver, connection_index, problem, now_ns);
                return true;
            };
            if (parsed.consumed > data.len) return error.StateInvariant;
            switch (parsed.event) {
                .need_more => {
                    if (parsed.consumed != data.len) return error.StateInvariant;
                    return false;
                },
                .upload_paused => return pauseMultipartChunk(
                    driver,
                    connection_index,
                    request_index,
                    input,
                    source,
                    wire_consumed,
                    data[parsed.consumed..],
                    now_ns,
                ),
                .invalid_utf8, .invalid_input => return rejectMultipartChunk(
                    driver,
                    connection_index,
                    source,
                    wire_consumed,
                    .bad_request,
                    now_ns,
                ),
                .input_too_large => return rejectMultipartChunk(
                    driver,
                    connection_index,
                    source,
                    wire_consumed,
                    .payload_too_large,
                    now_ns,
                ),
                .unsupported_media => return rejectMultipartChunk(
                    driver,
                    connection_index,
                    source,
                    wire_consumed,
                    .unsupported_media_type,
                    now_ns,
                ),
                .prepared => return error.StateInvariant,
            }
        }

        fn pauseMultipartChunk(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: InputSource,
            wire_consumed: usize,
            decoded_tail: []const u8,
            now_ns: u64,
        ) DriverError!bool {
            try connection_body_feed.consumeSource(
                DriverError,
                driver,
                connection_index,
                wire_consumed,
                source,
            );
            connection_pipeline.prepend(
                driver.storage,
                connection_index,
                decoded_tail,
            ) catch |problem| switch (problem) {
                error.PipelineFull => {
                    try driver.beginClose(connection_index);
                    return true;
                },
                error.StateInvariant => return error.StateInvariant,
            };
            if (source == .borrowed and !try preserveTail(
                driver,
                connection_index,
                input[wire_consumed..],
                source,
            )) return true;
            driver.storage.requests[request_index].body.used = @intCast(decoded_tail.len);
            try pauseUpload(driver, connection_index, request_index, now_ns);
            return true;
        }

        fn rejectMultipartChunk(
            driver: anytype,
            connection_index: u16,
            source: InputSource,
            wire_consumed: usize,
            status: request_head.Status,
            now_ns: u64,
        ) DriverError!bool {
            try connection_body_feed.consumeSource(
                DriverError,
                driver,
                connection_index,
                wire_consumed,
                source,
            );
            try reject(driver, connection_index, status, now_ns);
            return true;
        }

        pub fn finishChunked(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: InputSource,
            consumed: usize,
            state: anytype,
            now_ns: u64,
        ) DriverError!void {
            const ready = state.trailers() orelse return error.StateInvariant;
            const pending = if (connection_body_feed.requestIsMultipart(
                driver.storage,
                request_index,
            ))
                connection_body_runtime.finishMultipartChunked(
                    App,
                    driver.storage,
                    request_index,
                    ready,
                )
            else
                connection_body_runtime.finishChunked(
                    App,
                    driver.storage,
                    request_index,
                    ready,
                );
            const finished = pending catch |problem| {
                try handleRuntimeError(driver, connection_index, problem, now_ns);
                return;
            };
            return applyChunkedResult(
                driver,
                connection_index,
                input,
                source,
                consumed,
                finished,
                now_ns,
            );
        }

        fn applyChunkedResult(
            driver: anytype,
            connection_index: u16,
            input: []const u8,
            source: InputSource,
            consumed: usize,
            result: connection_body_runtime.FeedResult,
            now_ns: u64,
        ) DriverError!void {
            return applyResult(driver, connection_index, input, source, .{
                .consumed = consumed,
                .event = result.event,
                .close_connection = result.close_connection,
            }, now_ns);
        }

        pub fn reject(
            driver: anytype,
            connection_index: u16,
            status: request_head.Status,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request_index = connection.active_request orelse {
                return error.StateInvariant;
            };
            if (GzipTransport.active(driver, connection_index)) {
                return driver.beginClose(connection_index);
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
                .upload_paused => {
                    connection.close_after_response = true;
                    try pauseUpload(driver, connection_index, request_index, now_ns);
                },
                .prepared => try beginFinal(driver, connection_index, true, now_ns),
                else => return error.StateInvariant,
            }
        }

        pub fn rejectParser(
            driver: anytype,
            connection_index: u16,
            status: request_head.Status,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            const request_index = connection.active_request orelse {
                return error.StateInvariant;
            };
            if (GzipTransport.active(driver, connection_index)) {
                return GzipTransport.rejectParser(
                    driver,
                    connection_index,
                    request_index,
                    status,
                );
            }
            connection.receive_flags.upload_paused = false;
            connection.receive_flags.paused = false;
            return reject(driver, connection_index, status, now_ns);
        }

        pub fn handleTimeout(
            driver: anytype,
            connection_index: u16,
            deadline_ns: u64,
            now_ns: u64,
        ) DriverError!bool {
            const connection = &driver.storage.connections[connection_index];
            if (connection.phase != .receiving_body) return false;
            if (GzipTransport.rejectionPending(driver, connection_index)) return true;
            if (now_ns < deadline_ns) {
                try driver.operations.submitTimeoutAt(
                    driver.storage,
                    connection_index,
                    deadline_ns,
                );
            } else if (connection.continue_cursor != 0) {
                try driver.beginClose(connection_index);
            } else {
                try reject(driver, connection_index, .request_timeout, now_ns);
            }
            return true;
        }

        pub fn completeContinue(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            if (connection.continue_cursor != 0) return error.StateInvariant;
            switch (connection.phase) {
                .closing => {},
                .receiving_body => try driver.operations.retargetTimeout(
                    driver.storage,
                    connection_index,
                    now_ns,
                    runtime_limits.timeouts.body_inactivity_ns,
                ),
                .responding => {
                    try @TypeOf(driver.operations).extendTimeoutDeadline(
                        driver.storage,
                        connection_index,
                        now_ns,
                        runtime_limits.timeouts.write_stall_ns,
                    );
                    try driver.operations.submitSend(
                        driver.storage,
                        connection_index,
                        try connection_send.bytes(driver.storage, connection_index),
                    );
                },
                else => return error.StateInvariant,
            }
        }

        pub fn preserveTail(
            driver: anytype,
            connection_index: u16,
            tail: []const u8,
            source: InputSource,
        ) DriverError!bool {
            return connection_body_feed.preserveTail(
                DriverError,
                driver,
                connection_index,
                tail,
                source,
            );
        }

        pub fn applyResult(
            driver: anytype,
            connection_index: u16,
            input: []const u8,
            source: InputSource,
            result: connection_body_runtime.FeedResult,
            now_ns: u64,
        ) DriverError!void {
            if (result.consumed > input.len) return error.StateInvariant;
            try connection_body_feed.consumeSource(
                DriverError,
                driver,
                connection_index,
                result.consumed,
                source,
            );
            const request_index = driver.storage.connections[connection_index]
                .active_request orelse return error.StateInvariant;
            try driver.recordUploadFinalization(request_index);
            const tail = input[result.consumed..];
            switch (result.event) {
                .need_more => {
                    if (tail.len != 0) return error.StateInvariant;
                    const connection = &driver.storage.connections[connection_index];
                    if (result.consumed != 0 and connection.continue_cursor == 0) {
                        try @TypeOf(driver.operations).extendTimeoutDeadline(
                            driver.storage,
                            connection_index,
                            now_ns,
                            runtime_limits.timeouts.body_inactivity_ns,
                        );
                    }
                },
                .upload_paused => {
                    if (!try preserveTail(driver, connection_index, tail, source)) return;
                    const connection = &driver.storage.connections[connection_index];
                    connection.close_after_response = result.close_connection;
                    try pauseUpload(driver, connection_index, request_index, now_ns);
                },
                .prepared => {
                    if (!result.close_connection) {
                        if (!try preserveTail(driver, connection_index, tail, source)) return;
                    }
                    try beginFinal(
                        driver,
                        connection_index,
                        result.close_connection,
                        now_ns,
                    );
                },
                .invalid_utf8,
                .invalid_input,
                .input_too_large,
                .unsupported_media,
                => try reject(
                    driver,
                    connection_index,
                    rejectionStatus(result.event),
                    now_ns,
                ),
            }
        }

        fn rejectionStatus(event: connection_body_runtime.Event) request_head.Status {
            return switch (event) {
                .invalid_utf8, .invalid_input => .bad_request,
                .input_too_large => .payload_too_large,
                .unsupported_media => .unsupported_media_type,
                else => unreachable,
            };
        }
    };
}

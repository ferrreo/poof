const std = @import("std");
const application = @import("../../../application.zig");
const body = @import("../../../body.zig");
const connection_body = @import("body.zig");
const connection_body_feed = @import("body_feed.zig");
const connection_body_runtime = @import("body_runtime.zig");
const connection_body_transitions = @import("body_transitions.zig");
const connection_chunked_body = @import("chunked_body.zig");
const connection_gzip_signals = @import("gzip_signals.zig");
const gzip_request_jobs = @import("../gzip/request_jobs.zig");
const request_framing = @import("../../http1/request_framing.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn Transport(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
) type {
    return struct {
        const Self = @This();
        const SignalHandler = connection_gzip_signals.Handler(
            App,
            Storage,
            DriverError,
            Self,
        );
        const BodyTransitions = connection_body_transitions.Transitions(
            App,
            Storage,
            DriverError,
        );
        const runtime_limits = Storage.runtime_limits;
        const ChunkedState = connection_chunked_body.Receiver(runtime_limits.chunked);
        const TrailerDeclarations = ChunkedState.TrailerDeclarations;
        const ChunkWindow = union(enum) {
            need_more: usize,
            ready: usize,
            rejected: struct { consumed: usize, status: request_head.Status },
        };
        pub const handleGzipSignals = SignalHandler.handleGzipSignals;
        pub const rejectParser = SignalHandler.rejectParser;
        pub const resumeUpload = SignalHandler.resumeUpload;
        pub const settleGzipAfterBackend = SignalHandler.settleGzipAfterBackend;
        const beginContinue = BodyTransitions.beginContinue;

        pub fn beginAfterHead(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            framing: request_framing.BodyFraming,
            declarations: TrailerDeclarations,
            head_bytes: []const u8,
            expect_continue: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            if (comptime Storage.gzip_decoder_thread_count == 0) {
                try driver.beginClose(connection_index);
                return error.StateInvariant;
            } else {
                if (!try acquireResources(
                    driver,
                    connection_index,
                    request_index,
                    plan,
                    framing == .chunked,
                    now_ns,
                )) return;
                return switch (framing) {
                    .none => beginFixed(
                        driver,
                        connection_index,
                        request_index,
                        plan,
                        multipart_boundary,
                        0,
                        expect_continue,
                        tail,
                        source,
                        now_ns,
                    ),
                    .fixed => |length| beginFixed(
                        driver,
                        connection_index,
                        request_index,
                        plan,
                        multipart_boundary,
                        length,
                        expect_continue,
                        tail,
                        source,
                        now_ns,
                    ),
                    .chunked => beginChunked(
                        driver,
                        connection_index,
                        request_index,
                        plan,
                        multipart_boundary,
                        declarations,
                        head_bytes,
                        expect_continue,
                        tail,
                        source,
                        now_ns,
                    ),
                };
            }
        }

        fn acquireResources(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            requires_chunked: bool,
            now_ns: u64,
        ) DriverError!bool {
            const body_resources = driver.storage.acquireBodyForPlan(
                request_index,
                plan,
                requires_chunked,
            );
            switch (body_resources) {
                .acquired => {},
                .body_workspace_exhausted, .chunked_workspace_exhausted => {
                    try rejectCapacity(driver, connection_index, request_index, now_ns);
                    return false;
                },
                .invalid_request => return failInvariant(driver, connection_index),
            }
            const encoded_max = std.math.cast(usize, plan.encoded_wire_bytes_max) orelse {
                return failInvariant(driver, connection_index);
            };
            const decoded_max = std.math.cast(usize, plan.decoded_bytes_max) orelse {
                return failInvariant(driver, connection_index);
            };
            const limits: gzip_request_jobs.Limits = .{
                .encoded_max = encoded_max,
                .decoded_max = decoded_max,
            };
            const acquired = if (multipartPlan(plan))
                gzip_request_jobs.acquireStreaming(
                    driver.storage,
                    connection_index,
                    request_index,
                    limits,
                ) catch return failInvariant(driver, connection_index)
            else
                gzip_request_jobs.acquire(
                    driver.storage,
                    connection_index,
                    request_index,
                    limits,
                ) catch return failInvariant(driver, connection_index);
            if (acquired == .exhausted) {
                try rejectCapacity(driver, connection_index, request_index, now_ns);
                return false;
            }
            return true;
        }

        fn beginFixed(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            length: u64,
            expect_continue: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            const receiver = switch (connection_body.FixedIdentity.init(
                length,
                plan.encoded_wire_bytes_max,
                plan.encoded_wire_bytes_max,
            )) {
                .accepted => |value| value,
                .over_limit => return failInvariant(driver, connection_index),
            };
            if (multipartPlan(plan)) {
                connection_body_runtime.startMultipartGzipFixed(
                    App,
                    driver.storage,
                    request_index,
                    receiver,
                    multipart_boundary orelse return failInvariant(driver, connection_index),
                ) catch return failInvariant(driver, connection_index);
            } else {
                const kind = bodyKind(plan) orelse {
                    return failInvariant(driver, connection_index);
                };
                connection_body_runtime.startGzipFixed(
                    driver.storage,
                    request_index,
                    receiver,
                    kind,
                ) catch return failInvariant(driver, connection_index);
            }
            const connection = &driver.storage.connections[connection_index];
            connection.phase = .receiving_body;
            if (receiver.complete()) return finishInput(
                driver,
                connection_index,
                request_index,
                tail,
                source,
            );
            if (expect_continue and tail.len < receiver.expected()) {
                try beginContinue(driver, connection_index, now_ns);
            } else {
                try driver.operations.retargetTimeout(
                    driver.storage,
                    connection_index,
                    now_ns,
                    runtime_limits.timeouts.body_inactivity_ns,
                );
            }
            if (tail.len != 0) {
                try consumeFixed(
                    driver,
                    connection_index,
                    request_index,
                    tail,
                    source,
                    now_ns,
                );
            }
        }

        fn beginChunked(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            declarations: TrailerDeclarations,
            head_bytes: []const u8,
            expect_continue: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            const state = driver.storage.chunkedState(request_index) catch {
                return failInvariant(driver, connection_index);
            };
            state.* = ChunkedState.init(
                plan.encoded_wire_bytes_max,
                plan.encoded_wire_bytes_max,
                declarations,
                head_bytes,
            );
            if (multipartPlan(plan)) {
                connection_body_runtime.startMultipartChunked(
                    App,
                    driver.storage,
                    request_index,
                    multipart_boundary orelse return failInvariant(driver, connection_index),
                ) catch return failInvariant(driver, connection_index);
            } else {
                const kind = bodyKind(plan) orelse {
                    return failInvariant(driver, connection_index);
                };
                connection_body_runtime.startChunked(
                    driver.storage,
                    request_index,
                    kind,
                ) catch return failInvariant(driver, connection_index);
            }
            driver.storage.connections[connection_index].phase = .receiving_body;
            if (expect_continue and tail.len == 0) {
                try beginContinue(driver, connection_index, now_ns);
                return;
            }
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.body_inactivity_ns,
            );
            if (tail.len != 0) {
                try consumeChunked(
                    driver,
                    connection_index,
                    request_index,
                    tail,
                    source,
                    now_ns,
                );
            }
            const connection = &driver.storage.connections[connection_index];
            if (expect_continue and connection.phase == .receiving_body and
                state.trailers() == null and state.rejectionStatus() == null)
            {
                try beginContinue(driver, connection_index, now_ns);
            }
        }

        fn bodyKind(plan: application.BodyPlan) ?body.Kind {
            return switch (plan.kind) {
                .bytes => .bytes,
                .text => .text,
                .structured => switch (plan.decoderKind() orelse return null) {
                    .text => .text,
                    .bytes, .json, .form => .bytes,
                    .multipart => null,
                },
                .none, .input => null,
            };
        }

        fn multipartPlan(plan: application.BodyPlan) bool {
            return plan.kind == .structured and plan.decoderKind() == .multipart;
        }

        pub fn consume(
            driver: anytype,
            connection_index: u16,
            input: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            if (comptime Storage.gzip_decoder_thread_count == 0) {
                return error.StateInvariant;
            } else {
                const request_index = driver.storage.connections[connection_index]
                    .active_request orelse return error.StateInvariant;
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
        }

        fn consumeFixed(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            var consumed: usize = 0;
            while (consumed < input.len) {
                const window_end = try inputWindow(source, input.len, consumed);
                const request = &driver.storage.requests[request_index];
                const result = request.body.receiver.feed(
                    input[consumed..window_end],
                ) catch return failInvariant(driver, connection_index);
                try feedJob(driver, connection_index, request_index, result.body);
                try connection_body_feed.consumeSource(
                    DriverError,
                    driver,
                    connection_index,
                    result.body.len,
                    source,
                );
                consumed = std.math.add(usize, consumed, result.body.len) catch {
                    return failInvariant(driver, connection_index);
                };
                if (result.complete) return finishInput(
                    driver,
                    connection_index,
                    request_index,
                    input[consumed..],
                    source,
                );
                if (consumed != window_end) return failInvariant(driver, connection_index);
                if (try pauseAfterInput(
                    driver,
                    connection_index,
                    request_index,
                    result.body.len,
                    now_ns,
                )) return;
            }
        }

        fn consumeChunked(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            var consumed: usize = 0;
            while (consumed < input.len) {
                const window_end = try inputWindow(source, input.len, consumed);
                const result = try consumeChunkWindow(
                    driver,
                    connection_index,
                    request_index,
                    input[consumed..window_end],
                );
                const used = switch (result) {
                    .need_more => |value| value,
                    .ready => |value| value,
                    .rejected => |value| value.consumed,
                };
                try connection_body_feed.consumeSource(
                    DriverError,
                    driver,
                    connection_index,
                    used,
                    source,
                );
                consumed = std.math.add(usize, consumed, used) catch {
                    return failInvariant(driver, connection_index);
                };
                switch (result) {
                    .need_more => {
                        if (consumed != window_end) {
                            return failInvariant(driver, connection_index);
                        }
                        if (try pauseAfterInput(
                            driver,
                            connection_index,
                            request_index,
                            used,
                            now_ns,
                        )) return;
                    },
                    .ready => return finishInput(
                        driver,
                        connection_index,
                        request_index,
                        input[consumed..],
                        source,
                    ),
                    .rejected => |rejection| return awaitRejectedInput(
                        driver,
                        connection_index,
                        request_index,
                        rejection.status,
                    ),
                }
            }
        }

        fn consumeChunkWindow(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            input: []const u8,
        ) DriverError!ChunkWindow {
            const state = driver.storage.chunkedState(request_index) catch {
                return failInvariant(driver, connection_index);
            };
            var consumed: usize = 0;
            while (true) {
                const result = state.feed(input[consumed..]);
                if (result.consumed > input.len - consumed) {
                    return failInvariant(driver, connection_index);
                }
                consumed = std.math.add(usize, consumed, result.consumed) catch {
                    return failInvariant(driver, connection_index);
                };
                switch (result.event) {
                    .data => |data| {
                        if (data.len == 0 or result.consumed == 0) {
                            return failInvariant(driver, connection_index);
                        }
                        try feedJob(driver, connection_index, request_index, data);
                    },
                    .need_more => return .{ .need_more = consumed },
                    .ready => return .{ .ready = consumed },
                    .rejected => |rejection| return .{ .rejected = .{
                        .consumed = consumed,
                        .status = rejection.status,
                    } },
                }
            }
        }

        fn inputWindow(source: anytype, input_len: usize, consumed: usize) DriverError!usize {
            if (consumed > input_len) return error.StateInvariant;
            const remaining = input_len - consumed;
            const receive_bytes: usize = runtime_limits.receive_buffer_bytes;
            if (source == .borrowed and remaining > receive_bytes) {
                return error.StateInvariant;
            }
            return consumed + @min(remaining, receive_bytes);
        }

        fn feedJob(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            bytes: []const u8,
        ) DriverError!void {
            return switch (gzip_request_jobs.feed(
                driver.storage,
                connection_index,
                request_index,
                bytes,
            ) catch return failInvariant(driver, connection_index)) {
                .written => {},
                .full => failInvariant(driver, connection_index),
            };
        }

        fn pauseAfterInput(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            progressed: usize,
            now_ns: u64,
        ) DriverError!bool {
            const connection = &driver.storage.connections[connection_index];
            if (progressed != 0 and connection.continue_cursor == 0) {
                try @TypeOf(driver.operations).extendTimeoutDeadline(
                    driver.storage,
                    connection_index,
                    now_ns,
                    runtime_limits.timeouts.body_inactivity_ns,
                );
            }
            const paused = gzip_request_jobs.shouldPause(
                driver.storage,
                connection_index,
                request_index,
            ) catch return failInvariant(driver, connection_index);
            connection.receive_flags.gzip_paused = paused;
            return paused;
        }

        fn finishInput(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            tail: []const u8,
            source: anytype,
        ) DriverError!void {
            if (!try connection_body_feed.preserveTail(
                DriverError,
                driver,
                connection_index,
                tail,
                source,
            )) return;
            gzip_request_jobs.finish(
                driver.storage,
                connection_index,
                request_index,
            ) catch return failInvariant(driver, connection_index);
            driver.storage.connections[connection_index].receive_flags.gzip_paused = true;
        }

        pub fn cancelActive(driver: anytype, connection_index: u16) DriverError!void {
            if (comptime Storage.gzip_decoder_thread_count != 0) {
                const connection = &driver.storage.connections[connection_index];
                const request_index = connection.active_request orelse return;
                if (driver.storage.requests[request_index].gzip_lease == null) return;
                gzip_request_jobs.cancel(
                    driver.storage,
                    connection_index,
                    request_index,
                ) catch return error.StateInvariant;
                connection.receive_flags.gzip_paused = false;
                connection.receive_flags.gzip_rejecting = false;
            }
        }

        pub fn active(driver: anytype, connection_index: u16) bool {
            if (comptime Storage.gzip_decoder_thread_count == 0) return false;
            const request_index = driver.storage.connections[connection_index]
                .active_request orelse return false;
            return driver.storage.requests[request_index].gzip_lease != null;
        }

        pub fn pendingRejectionStatus(
            driver: anytype,
            request_index: u16,
        ) ?request_head.Status {
            if (comptime Storage.gzip_decoder_thread_count == 0) return null;
            if (request_index >= driver.storage.requests.len) return null;
            if (driver.storage.requests[request_index].chunked_workspace_index == null) {
                return null;
            }
            const state = driver.storage.chunkedState(request_index) catch return null;
            return state.rejectionStatus();
        }

        pub fn rejectionPending(driver: anytype, connection_index: u16) bool {
            if (!active(driver, connection_index)) return false;
            const connection = &driver.storage.connections[connection_index];
            if (connection.receive_flags.gzip_rejecting) return true;
            const request_index = connection
                .active_request orelse return false;
            return pendingRejectionStatus(driver, request_index) != null;
        }

        pub fn pipelineMayReceive(connection: anytype) bool {
            return !connection.receive_flags.gzip_paused and
                !connection.receive_flags.gzip_rejecting and
                (connection.phase == .reused_head or connection.phase == .receiving_body);
        }

        pub fn receiveBlocked(connection: anytype) bool {
            return connection.receive_flags.gzip_paused or
                connection.receive_flags.gzip_rejecting or !connection.receive_flags.paused;
        }

        pub fn requestReleaseReady(driver: anytype, connection_index: u16) bool {
            const connection = &driver.storage.connections[connection_index];
            return connection.send_token == null and connection.active_request != null and
                !active(driver, connection_index);
        }

        fn rejectCapacity(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const outcome = App.abort(
                &driver.storage.requests[request_index].workspace,
            ) catch {
                try driver.beginClose(connection_index);
                return error.StateInvariant;
            };
            try driver.startObservedFallback(
                connection_index,
                request_index,
                outcome,
                .{ .status = .service_unavailable },
                now_ns,
            );
        }

        fn awaitRejectedInput(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            status: request_head.Status,
        ) DriverError!void {
            if (pendingRejectionStatus(driver, request_index) != status) {
                return failInvariant(driver, connection_index);
            }
            gzip_request_jobs.cancel(
                driver.storage,
                connection_index,
                request_index,
            ) catch return failInvariant(driver, connection_index);
            const connection = &driver.storage.connections[connection_index];
            if (connection.receive_token != null) return failInvariant(driver, connection_index);
            connection.receive_flags.gzip_paused = true;
        }

        fn failInvariant(driver: anytype, connection_index: u16) DriverError {
            driver.beginClose(connection_index) catch |problem| return problem;
            return error.StateInvariant;
        }
    };
}

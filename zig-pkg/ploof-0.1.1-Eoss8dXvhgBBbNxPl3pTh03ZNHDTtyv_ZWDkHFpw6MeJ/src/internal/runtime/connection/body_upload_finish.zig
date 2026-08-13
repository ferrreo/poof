const connection_body_runtime = @import("body_runtime.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn Bridge(
    comptime App: type,
    comptime DriverError: type,
    comptime Parent: type,
) type {
    return struct {
        pub fn finish(
            driver: anytype,
            finalized: anytype,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[finalized.connection_index];
            const request = &driver.storage.requests[finalized.request_index];
            if (request.flags.upload_rejection_pending and
                Parent.gzipActive(driver, finalized.connection_index)) return;
            if (selectedResponsePending(request) and
                Parent.gzipActive(driver, finalized.connection_index)) return;
            if (connection.active_request != finalized.request_index or
                !connection.receive_flags.upload_paused or
                !connection.receive_flags.paused)
            {
                return error.StateInvariant;
            }
            connection.receive_flags.upload_paused = false;
            connection.receive_flags.paused = false;
            if (connection.phase == .closing) return;
            if (connection.phase != .receiving_body) return error.StateInvariant;
            const rejection_pending = request.flags.upload_rejection_pending;
            const allowed = if (rejection_pending)
                connection_body_runtime.finalizationMatchesUpstream(
                    finalized.report,
                    .body,
                )
            else
                finalized.report.responseAllowed();
            if (!allowed or (finalized.response_failed and !rejection_pending)) {
                return fail(driver, finalized, request, now_ns);
            }
            if (rejection_pending) {
                return rejection(driver, finalized, request, now_ns);
            }
            clearSelectedResponsePending(request);
            return Parent.beginFinal(
                driver,
                finalized.connection_index,
                connection.close_after_response,
                now_ns,
            );
        }

        fn fail(
            driver: anytype,
            finalized: anytype,
            request: anytype,
            now_ns: u64,
        ) DriverError!void {
            clearSelectedResponsePending(request);
            request.flags.upload_rejection_pending = false;
            request.body.used = 0;
            const outcome = App.__abortWithTransport(
                &request.workspace,
                .aborted,
            ) catch return error.StateInvariant;
            return driver.startObservedFallback(
                finalized.connection_index,
                finalized.request_index,
                outcome,
                .{ .status = .internal_server_error },
                now_ns,
            );
        }

        fn selectedResponsePending(request: anytype) bool {
            const Body = @TypeOf(request.body);
            if (comptime @hasField(Body, "terminal_response_pending")) {
                return request.body.terminal_response_pending;
            }
            return false;
        }

        fn clearSelectedResponsePending(request: anytype) void {
            const Body = @TypeOf(request.body);
            if (comptime @hasField(Body, "terminal_response_pending")) {
                request.body.terminal_response_pending = false;
            }
        }

        fn rejection(
            driver: anytype,
            finalized: anytype,
            request: anytype,
            now_ns: u64,
        ) DriverError!void {
            const status = request_head.Status.fromInt(
                @intCast(request.body.used),
            ) catch return error.StateInvariant;
            request.flags.upload_rejection_pending = false;
            request.body.used = 0;
            connection_body_runtime.stageRejectionNow(
                App,
                driver.storage,
                finalized.request_index,
                status,
                driver.runtime_fields,
            ) catch |problem| return switch (problem) {
                error.ResponseSerializationFailed => error.ResponseSerializationFailed,
                else => error.StateInvariant,
            };
            request.flags.upload_rejection_pending = true;
            return Parent.beginFinal(
                driver,
                finalized.connection_index,
                true,
                now_ns,
            );
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

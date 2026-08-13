const application = @import("../../../application.zig");
const application_chunk_output = @import("../../application/chunk_output.zig");
const connection_admission = @import("admission.zig");

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
    comptime BodyTransport: type,
    comptime ResponseTransport: type,
    comptime MetricsTransport: type,
) type {
    const runtime_limits = Storage.runtime_limits;
    return struct {
        pub fn prepareAdmitted(
            driver: anytype,
            connection_index: u16,
            admitted: connection_admission.Gate(
                App,
                runtime_limits.chunked.trailer_names_max,
            ),
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            const framing = admitted.request.analysis.framing.body;
            const unread_body = connection_admission.hasUnreadBody(framing);
            const reservation = try connection_admission.reserveHeadWorkspace(
                DriverError,
                driver,
                connection_index,
                admitted.plan.body,
                admitted.request.decoded_path_used,
                now_ns,
            ) orelse return;
            const request_index = reservation.request_index;
            driver.storage.setFiniteOutput(request_index, admitted.plan.finite_output);
            driver.observation.admit(
                request_index,
                admitted.plan.input.method,
                routeId(admitted.plan),
                driver.storage.connections[connection_index].head_decoder.bytes().len,
            ) catch return error.StateInvariant;
            const result = prepareApplicationHead(
                driver,
                request_index,
                admitted,
                reservation.workspace,
                unread_body,
            ) catch {
                try driver.startObservedFallback(
                    connection_index,
                    request_index,
                    .{ .status = null, .mapped_error = false, .transport = .aborted },
                    .{ .status = .internal_server_error },
                    now_ns,
                );
                return;
            };
            if (comptime App.open_metrics_enabled) {
                try beginMetricsResult(
                    driver,
                    connection_index,
                    request_index,
                    result,
                    admitted,
                    framing,
                    unread_body,
                    tail,
                    source,
                    now_ns,
                );
            } else try beginStandardResult(
                driver,
                connection_index,
                request_index,
                result,
                admitted,
                framing,
                unread_body,
                tail,
                source,
                now_ns,
            );
        }

        fn beginMetricsResult(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            result: App.HeadResultType,
            admitted: anytype,
            framing: anytype,
            unread_body: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            switch (result) {
                .prepared => |prepared| try ResponseTransport.begin(
                    driver,
                    connection_index,
                    request_index,
                    prepared,
                    unread_body,
                    tail,
                    source,
                    now_ns,
                ),
                .receive_body => |body_plan| try beginBody(
                    driver,
                    connection_index,
                    request_index,
                    body_plan,
                    admitted,
                    framing,
                    tail,
                    source,
                    now_ns,
                ),
                .deferred_metrics => |deferred| try MetricsTransport.begin(
                    driver,
                    connection_index,
                    request_index,
                    deferred,
                    unread_body,
                    admitted.plan.input.connection_close or unread_body,
                    tail,
                    source,
                    now_ns,
                ),
            }
        }

        fn beginStandardResult(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            result: App.HeadResultType,
            admitted: anytype,
            framing: anytype,
            unread_body: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            switch (result) {
                .prepared => |prepared| try ResponseTransport.begin(
                    driver,
                    connection_index,
                    request_index,
                    prepared,
                    unread_body,
                    tail,
                    source,
                    now_ns,
                ),
                .receive_body => |body_plan| try beginBody(
                    driver,
                    connection_index,
                    request_index,
                    body_plan,
                    admitted,
                    framing,
                    tail,
                    source,
                    now_ns,
                ),
            }
        }

        fn beginBody(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            body_plan: application.BodyPlan,
            admitted: anytype,
            framing: anytype,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) DriverError!void {
            try BodyTransport.beginAfterHead(
                driver,
                connection_index,
                request_index,
                body_plan,
                admitted.coding,
                admitted.multipart_boundary.bytes(),
                framing,
                admitted.request.analysis.trailer_declarations,
                driver.storage.connections[connection_index].head_decoder.bytes(),
                admitted.request.expect_continue,
                tail,
                source,
                now_ns,
            );
        }

        fn prepareApplicationHead(
            driver: anytype,
            request_index: u16,
            admitted: connection_admission.Gate(
                App,
                runtime_limits.chunked.trailer_names_max,
            ),
            request_workspace: []u8,
            unread_body: bool,
        ) application.PrepareError!App.HeadResultType {
            const request = &driver.storage.requests[request_index];
            return switch (admitted.plan.finite_output) {
                .contiguous => App.__prepareHeadPlannedWithResponseGzip(
                    driver.state,
                    &request.workspace,
                    request_workspace,
                    driver.storage.responseWritable(request_index),
                    &admitted.plan,
                    .{ .close_if_prepared = unread_body },
                    &driver.storage.response_gzip_workspace,
                ),
                .chunks => |plan| chunks: {
                    var concrete = driver.storage.responseChunkWriter(plan.encoded_bytes_max);
                    defer concrete.abort();
                    var writer = application_chunk_output.bind(&concrete);
                    break :chunks App.__prepareHeadPlannedWithChunks(
                        driver.state,
                        &request.workspace,
                        request_workspace,
                        &request.workspace.response_head_bytes,
                        &admitted.plan,
                        .{ .close_if_prepared = unread_body },
                        &writer,
                        driver.storage.htmlJsonScratch(plan.json_scratch_bytes_max),
                        &driver.storage.response_gzip_workspace,
                    );
                },
            };
        }

        fn routeId(plan: anytype) ?u16 {
            return switch (plan.selection) {
                .selected => |selected| selected.route_id,
                .redirect => |redirect| redirect.route_id,
                else => null,
            };
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

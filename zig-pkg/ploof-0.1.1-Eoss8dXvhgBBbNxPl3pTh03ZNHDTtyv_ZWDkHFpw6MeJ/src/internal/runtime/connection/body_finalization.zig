const body_types = @import("body_types.zig");
const application_types = @import("../../application/types.zig");
const rejection_response = @import("../../http1/rejection_response.zig");
const request_head = @import("../../http1/request_head.zig");
const response_limits = @import("../../http1/limits.zig");
const response_transfer = @import("../../http1/response_transfer.zig");
const upload_finalizer = @import("../../upload/finalizer.zig");

const Error = body_types.Error;
const FeedResult = body_types.FeedResult;

pub fn failedResponse(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    storage.clearResponse(request_index);
    return begin(
        App,
        storage,
        request_index,
        .{ .consumed = 0, .event = .prepared, .close_connection = true },
        true,
        null,
    );
}

pub fn begin(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    prepared: FeedResult,
    response_failed: bool,
    expected_upstream: ?upload_finalizer.UpstreamFailure,
) Error!FeedResult {
    const request = &storage.requests[request_index];
    if (request.flags.upload_finalizing) return error.StateInvariant;
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    var flow = App.__startMultipartFinalization(
        &request.workspace,
        workspace,
    ) catch return error.ApplicationFailure;
    var steps: u32 = 0;
    while (flow == .progress) : (steps += 1) {
        if (steps > App.upload_request_handles_max + App.upload_window_max) {
            return error.StateInvariant;
        }
        flow = App.__multipartFinalizationFlow(
            &request.workspace,
            workspace,
        ) catch return error.ApplicationFailure;
    }
    if (flow == .paused) {
        if (comptime !asyncUploads(App)) return error.StateInvariant;
        request.flags.upload_finalizing = true;
        request.flags.upload_response_failed = response_failed;
        return .{
            .consumed = prepared.consumed,
            .event = .upload_paused,
            .close_connection = prepared.close_connection,
        };
    }
    const report = (App.__multipartFinalizationReport(
        &request.workspace,
        workspace,
    ) catch return error.ApplicationFailure) orelse return error.StateInvariant;
    if (response_failed or !allows(report, expected_upstream)) {
        return error.ApplicationFailure;
    }
    return prepared;
}

pub fn allows(
    report: anytype,
    expected_upstream: ?upload_finalizer.UpstreamFailure,
) bool {
    const expected = expected_upstream orelse return report.responseAllowed();
    return matchesUpstream(report, expected);
}

pub fn matchesUpstream(
    report: anytype,
    expected: upload_finalizer.UpstreamFailure,
) bool {
    if (report.cleanup_failure_count != 0 or report.outcome != .failed) return false;
    const primary = report.primary orelse return false;
    return switch (primary.class) {
        .upstream => |cause| cause == expected,
        .sink => false,
    };
}

pub fn required(request: anytype) bool {
    if (comptime !application_types.hasMultipartFinalization(
        @TypeOf(request.workspace),
    )) return false;
    return request.body.multipart and request.workspace.multipart_finalization == .required;
}

pub fn stageRejection(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    status: request_head.Status,
    runtime_fields: rejection_response.RuntimeFields,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        const prepared: FeedResult = .{
            .consumed = 0,
            .event = .prepared,
            .close_connection = true,
        };
        const requires_finalization = required(request);
        if (requires_finalization) {
            if (request.flags.upload_rejection_pending or request.body.used != 0) {
                return error.StateInvariant;
            }
            App.__cancelMultipart(&request.workspace, .body) catch {
                return error.StateInvariant;
            };
            const finalized = try begin(
                App,
                storage,
                request_index,
                prepared,
                false,
                .body,
            );
            if (finalized.event == .upload_paused) {
                request.flags.upload_rejection_pending = true;
                request.body.used = @intFromEnum(status);
                return finalized;
            }
            if (finalized.event != .prepared) return error.StateInvariant;
        }
        try stageRejectionNow(App, storage, request_index, status, runtime_fields);
        if (requires_finalization) request.flags.upload_rejection_pending = true;
        return prepared;
    }
    return error.StateInvariant;
}

pub fn stageRejectionNow(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    status: request_head.Status,
    runtime_fields: rejection_response.RuntimeFields,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        App.rejectBody(&request.workspace, status) catch return error.StateInvariant;
        const written = rejection_response.write(
            response_limits.standard_response_head_limits,
            response_transfer.standard_trailer_limits,
            storage.responseWritable(request_index),
            .{ .status = status },
            runtime_fields,
        ) catch return error.ResponseSerializationFailed;
        if (!storage.commitResponse(request_index, written.bytes)) {
            return error.StateInvariant;
        }
        return;
    }
    return error.StateInvariant;
}

fn asyncUploads(comptime App: type) bool {
    return @hasDecl(App, "upload_async_sink_present") and App.upload_async_sink_present;
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

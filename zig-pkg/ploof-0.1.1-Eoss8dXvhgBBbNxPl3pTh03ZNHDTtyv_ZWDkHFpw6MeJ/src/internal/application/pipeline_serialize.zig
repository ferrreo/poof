const std = @import("std");

const application_lifecycle = @import("lifecycle.zig");
const application_pipeline_support = @import("pipeline_support.zig");
const application_response_output = @import("response_output.zig");
const application_stream_output = @import("stream_output.zig");
const application_stream_pipeline = @import("stream_pipeline.zig");
const application_types = @import("types.zig");
const response = @import("../../response.zig");

pub fn finite(
    comptime ResponseOutput: type,
    comptime Outcome: type,
    comptime middleware: anytype,
    value: anytype,
    pending_route: anytype,
    comptime selected_limits: response.HeadLimits,
    workspace: anytype,
    input: anytype,
    output: []u8,
    mapped_error: bool,
    server_identity: anytype,
) !application_response_output.Prepared {
    const Context = @TypeOf(workspace.context);
    const selected_output = if (comptime @hasDecl(Context, "__finiteResponseOutput"))
        workspace.context.__finiteResponseOutput(value.bodyBytes(), output)
    else
        output;
    const prepared = ResponseOutput.serialize(
        selected_limits,
        value,
        workspace,
        input,
        workspace.cors_fields,
        selected_output,
        workspace.response_gzip.get(),
        server_identity,
    ) catch |problem| {
        if (application_pipeline_support.deferMultipartSerializationFailure(
            workspace,
            mapped_error,
        )) return problem;
        abort(middleware, workspace, mapped_error, Outcome);
        return problem;
    };
    markPending(workspace, pending_route, prepared, input, mapped_error, false);
    return prepared;
}

pub fn borrowed(
    comptime ResponseOutput: type,
    comptime Outcome: type,
    comptime middleware: anytype,
    value: anytype,
    pending_route: anytype,
    comptime selected_limits: response.HeadLimits,
    workspace: anytype,
    input: anytype,
    output: []u8,
    mapped_error: bool,
    server_identity: anytype,
) !application_response_output.Prepared {
    const prepared = ResponseOutput.serializeBorrowed(
        selected_limits,
        value,
        workspace,
        input,
        workspace.cors_fields,
        output,
        server_identity,
    ) catch |problem| {
        abort(middleware, workspace, mapped_error, Outcome);
        return problem;
    };
    markPending(workspace, pending_route, prepared, input, mapped_error, false);
    return prepared;
}

pub fn stream(
    comptime Outcome: type,
    comptime middleware: anytype,
    value: anytype,
    pending_route: anytype,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    workspace: anytype,
    input: anytype,
    output: []u8,
    mapped_error: bool,
    server_identity: anytype,
) !application_response_output.Prepared {
    workspace.stream.init(value.stream);
    const prepared = application_stream_output.serialize(
        selected_limits,
        framework_limits,
        value.*,
        &workspace.response,
        application_stream_pipeline.request(input, workspace.cors_fields),
        output,
        server_identity,
    ) catch |problem| {
        application_pipeline_support.abortAndJoinStream(workspace);
        if (application_pipeline_support.deferMultipartSerializationFailure(
            workspace,
            mapped_error,
        )) return problem;
        abort(middleware, workspace, mapped_error, Outcome);
        return problem;
    };
    const result = application_stream_pipeline.prepared(prepared);
    markPending(workspace, pending_route, result, input, mapped_error, true);
    return result;
}

fn markPending(
    workspace: anytype,
    pending_route: anytype,
    prepared: application_response_output.Prepared,
    input: anytype,
    mapped_error: bool,
    comptime stream_response: bool,
) void {
    const success_transport: application_types.TransportOutcome = if (std.mem.eql(
        u8,
        input.method,
        "HEAD",
    ))
        .head_suppressed
    else
        .completed;
    if (comptime @hasField(@TypeOf(workspace.pending), "transmission")) {
        workspace.pending = .{
            .route = pending_route,
            .status = prepared.status,
            .mapped_error = mapped_error,
            .success_transport = success_transport,
            .transmission = if (stream_response) .stream else .finite,
        };
    } else {
        std.debug.assert(!stream_response);
        workspace.pending = .{
            .route = pending_route,
            .status = prepared.status,
            .mapped_error = mapped_error,
            .success_transport = success_transport,
        };
    }
    workspace.lifecycle = .pending;
}

fn abort(
    comptime middleware: anytype,
    workspace: anytype,
    mapped_error: bool,
    comptime Outcome: type,
) void {
    application_lifecycle.runAfter(middleware, workspace, Outcome{
        .status = null,
        .mapped_error = mapped_error,
        .transport = .aborted,
    });
    workspace.lifecycle = .idle;
}

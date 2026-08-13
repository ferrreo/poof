const application_compile = @import("compile.zig");
const application_pipeline_support = @import("pipeline_support.zig");
const application_response_output = @import("response_output.zig");
const response = @import("../../response.zig");

pub fn runFinite(
    comptime Pipeline: type,
    comptime middleware: anytype,
    comptime handler: anytype,
    body_input: anytype,
    handler_state: anytype,
    multipart_summaries: anytype,
    pending_route: anytype,
    comptime selected_limits: response.HeadLimits,
    context: anytype,
    workspace: anytype,
    input: anytype,
    output: []u8,
    server_identity: anytype,
) !application_response_output.Prepared {
    const States = application_compile.StateTuple(middleware);
    const states: *States = @ptrCast(&workspace.middleware_state);
    const has_multipart = comptime application_pipeline_support
        .multipartFinalizationEnabled(@TypeOf(workspace.*));
    const multipart_commit = if (has_multipart) commit: {
        workspace.multipart_commit = false;
        workspace.multipart_abort_cause = null;
        break :commit &workspace.multipart_commit;
    } else null;
    var mapped_error = false;
    var value = Pipeline.runBodyPhases(
        middleware,
        handler,
        body_input,
        handler_state,
        multipart_summaries,
        multipart_commit,
        context,
        states,
        workspace.initialized_middleware,
        &mapped_error,
    );
    if (has_multipart and mapped_error) workspace.multipart_abort_cause = null;
    return Pipeline.prepareResponse(
        middleware,
        &value,
        pending_route,
        selected_limits,
        context,
        workspace,
        input,
        output,
        mapped_error,
        server_identity,
    );
}

pub fn runStream(
    comptime Pipeline: type,
    comptime middleware: anytype,
    comptime handler: anytype,
    body_input: anytype,
    handler_state: anytype,
    pending_route: anytype,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    context: anytype,
    workspace: anytype,
    input: anytype,
    output: []u8,
    server_identity: anytype,
) !application_response_output.Prepared {
    const States = application_compile.StateTuple(middleware);
    const states: *States = @ptrCast(&workspace.middleware_state);
    var mapped_error = false;
    var value = Pipeline.runStreamBodyPhases(
        middleware,
        handler,
        body_input,
        handler_state,
        context,
        states,
        workspace.initialized_middleware,
        &mapped_error,
    );
    return Pipeline.prepareRouteResult(
        middleware,
        &value,
        pending_route,
        selected_limits,
        framework_limits,
        context,
        workspace,
        input,
        output,
        mapped_error,
        server_identity,
    );
}

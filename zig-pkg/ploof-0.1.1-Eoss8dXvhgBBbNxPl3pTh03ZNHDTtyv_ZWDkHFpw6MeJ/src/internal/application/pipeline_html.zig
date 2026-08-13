const application_chunk_output = @import("chunk_output.zig");
const application_compile = @import("compile.zig");
const application_pipeline_support = @import("pipeline_support.zig");
const application_response_output = @import("response_output.zig");
const application_stream_pipeline = @import("stream_pipeline.zig");
const html_response = @import("../../html/response.zig");
const response = @import("../../response.zig");

pub fn run(
    comptime Pipeline: type,
    comptime Response: type,
    comptime mapper: anytype,
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
    const Staged = application_stream_pipeline.handlerPayload(handler);
    comptime if (!html_response.is(Staged)) unreachable;
    const States = application_compile.StateTuple(middleware);
    const states: *States = @ptrCast(&workspace.middleware_state);
    const is_multipart = comptime application_pipeline_support.multipartHandler(
        @TypeOf(handler),
    );
    const multipart_commit = if (is_multipart) commit: {
        workspace.multipart_commit = false;
        workspace.multipart_abort_cause = null;
        break :commit &workspace.multipart_commit;
    } else null;
    var mapped_error = false;
    const value = bodyResult(
        Response,
        mapper,
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
    if (is_multipart and mapped_error) workspace.multipart_abort_cause = null;
    var finite = switch (value) {
        .finite => |result| result,
        .staged => |staged| render(
            Response,
            mapper,
            staged,
            context,
            workspace,
            &mapped_error,
        ),
    };
    return Pipeline.prepareResponse(
        middleware,
        &finite,
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

fn bodyResult(
    comptime Response: type,
    comptime mapper: anytype,
    comptime middleware: anytype,
    comptime handler: anytype,
    body_input: anytype,
    handler_state: anytype,
    multipart_summaries: anytype,
    multipart_commit: ?*bool,
    context: anytype,
    states: anytype,
    initialized: u64,
    mapped_error: *bool,
) BodyResult(Response, application_stream_pipeline.handlerPayload(handler)) {
    if (initialized != application_pipeline_support.initializedMask(middleware.len)) {
        mapped_error.* = true;
        return .{ .finite = context.empty(.internal_server_error) };
    }
    inline for (middleware, 0..) |item, index| {
        if (@hasDecl(@TypeOf(item), "body")) {
            const value = invokeBody(
                item,
                context,
                &states[index],
                body_input,
                mapper,
                mapped_error,
            );
            if (value) |response_value| {
                return .{ .finite = response_value };
            }
        }
    }
    return invokeHandler(
        Response,
        mapper,
        handler,
        context,
        body_input,
        handler_state,
        multipart_summaries,
        multipart_commit,
        mapped_error,
    );
}

fn invokeHandler(
    comptime Response: type,
    comptime mapper: anytype,
    comptime handler: anytype,
    context: anytype,
    body_input: anytype,
    handler_state: anytype,
    multipart_summaries: anytype,
    multipart_commit: ?*bool,
    mapped_error: *bool,
) BodyResult(Response, application_stream_pipeline.handlerPayload(handler)) {
    const invoked = application_stream_pipeline.invoke(
        handler,
        context,
        body_input,
        handler_state,
        multipart_summaries,
    );
    if (comptime application_pipeline_support.multipartHandler(@TypeOf(handler))) {
        const decision = switch (@typeInfo(@TypeOf(invoked))) {
            .error_union => invoked catch |problem| {
                mapped_error.* = true;
                if (multipart_commit) |commit| commit.* = false;
                return .{ .finite = application_pipeline_support.mapError(
                    mapper,
                    context,
                    problem,
                ) };
            },
            else => invoked,
        };
        if (multipart_commit) |commit| commit.* = decision.commits();
        return .{ .staged = decision.response().* };
    }
    return switch (@typeInfo(@TypeOf(invoked))) {
        .error_union => .{ .staged = invoked catch |problem| {
            mapped_error.* = true;
            return .{ .finite = application_pipeline_support.mapError(
                mapper,
                context,
                problem,
            ) };
        } },
        else => .{ .staged = invoked },
    };
}

fn BodyResult(comptime Response: type, comptime Staged: type) type {
    return union(enum) {
        finite: Response,
        staged: Staged,
    };
}

fn invokeBody(
    comptime item: anytype,
    context: anytype,
    state: anytype,
    body_input: anytype,
    comptime mapper: anytype,
    mapped_error: *bool,
) ?@TypeOf(context.empty(.internal_server_error)) {
    const result = item.body(context, state, body_input);
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => result catch |problem| {
            mapped_error.* = true;
            return application_pipeline_support.mapError(mapper, context, problem);
        },
        else => result,
    };
}

fn render(
    comptime Response: type,
    comptime mapper: anytype,
    staged: anytype,
    context: anytype,
    workspace: anytype,
    mapped_error: *bool,
) Response {
    const Staged = @TypeOf(staged);
    const bound = workspace.finite_output.get() orelse {
        mapped_error.* = true;
        return context.empty(.internal_server_error);
    };
    if (bound.scratch.len < Staged.json_scratch_bytes_max) {
        bound.writer.abort();
        bound.failure = .rendering;
        mapped_error.* = true;
        return context.empty(.internal_server_error);
    }
    staged.render(
        bound.writer,
        bound.scratch[0..Staged.json_scratch_bytes_max],
    ) catch |problem| {
        if (chunkFailure(problem)) |failure| {
            bound.writer.abort();
            bound.failure = failure;
            mapped_error.* = true;
            return context.empty(.internal_server_error);
        }
        if (mapApplicationError(
            Staged.ApplicationError,
            mapper,
            context,
            problem,
        )) |mapped| {
            bound.writer.reset();
            mapped_error.* = true;
            return mapped;
        }
        bound.writer.abort();
        bound.failure = .rendering;
        mapped_error.* = true;
        return context.empty(.internal_server_error);
    };
    return Response.__renderedHtml(
        context.response_workspace,
        staged.status,
        bound.writer.bytesWritten(),
    ) catch {
        bound.writer.abort();
        bound.failure = .rendering;
        mapped_error.* = true;
        return context.empty(.internal_server_error);
    };
}

fn chunkFailure(problem: anyerror) ?application_chunk_output.Failure {
    return switch (problem) {
        error.ResponseChunksExhausted => .capacity,
        error.ResponseBodyTooLarge,
        error.SourceAliasesPool,
        error.WriterTerminal,
        error.RenderWorkExhausted,
        => .rendering,
        else => null,
    };
}

fn mapApplicationError(
    comptime ErrorSet: type,
    comptime mapper: anytype,
    context: anytype,
    problem: anyerror,
) ?@TypeOf(context.empty(.internal_server_error)) {
    const errors = @typeInfo(ErrorSet).error_set orelse unreachable;
    inline for (errors) |candidate| {
        const selected = @field(ErrorSet, candidate.name);
        if (problem == selected) {
            return application_pipeline_support.mapError(mapper, context, selected);
        }
    }
    return null;
}

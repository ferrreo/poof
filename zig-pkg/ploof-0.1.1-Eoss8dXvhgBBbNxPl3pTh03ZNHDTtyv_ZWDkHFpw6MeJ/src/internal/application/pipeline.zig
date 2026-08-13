const application_compile = @import("compile.zig");
const application_csrf = @import("csrf.zig");
const application_pipeline_serialize = @import("pipeline_serialize.zig");
const application_pipeline_support = @import("pipeline_support.zig");
const application_pipeline_html = @import("pipeline_html.zig");
const application_pipeline_selected_body = @import("pipeline_selected_body.zig");
const application_response_output = @import("response_output.zig");
const application_stream_pipeline = @import("stream_pipeline.zig");
const response = @import("../../response.zig");
const mapError = application_pipeline_support.mapError;
pub fn Pipeline(
    comptime Context: type,
    comptime Response: type,
    comptime AppError: type,
    comptime mapper: ?fn (*Context, AppError) Response,
    comptime Outcome: type,
    comptime ResponseOutput: type,
) type {
    return struct {
        const Self = @This();

        pub fn runWholeRequest(
            comptime middleware: anytype,
            handler: anytype,
            body_input: anytype,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            workspace.initialized_middleware = 0;
            var mapped_error = false;
            var value = runRequestPhases(
                middleware,
                handler,
                body_input,
                context,
                states,
                &workspace.initialized_middleware,
                &mapped_error,
            );
            return prepareResponse(
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
        pub fn runSelectedBodyResponse(
            comptime middleware: anytype,
            comptime handler: anytype,
            body_input: anytype,
            handler_state: anytype,
            multipart_summaries: anytype,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            comptime framework_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            const Payload = application_stream_pipeline.handlerPayload(handler);
            if (comptime Payload == Response) {
                return application_pipeline_selected_body.runFinite(
                    Self,
                    middleware,
                    handler,
                    body_input,
                    handler_state,
                    multipart_summaries,
                    pending_route,
                    selected_limits,
                    context,
                    workspace,
                    input,
                    output,
                    server_identity,
                );
            }
            if (comptime @import("../../html/response.zig").is(Payload)) {
                return application_pipeline_html.run(
                    Self,
                    Response,
                    mapper,
                    middleware,
                    handler,
                    body_input,
                    handler_state,
                    multipart_summaries,
                    pending_route,
                    selected_limits,
                    context,
                    workspace,
                    input,
                    output,
                    server_identity,
                );
            }
            return application_pipeline_selected_body.runStream(
                Self,
                middleware,
                handler,
                body_input,
                handler_state,
                pending_route,
                selected_limits,
                framework_limits,
                context,
                workspace,
                input,
                output,
                server_identity,
            );
        }
        pub fn prepareResponse(
            comptime middleware: anytype,
            value: *Response,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            initial_mapped_error: bool,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            var mapped_error = initial_mapped_error;
            const mapped_before_response = mapped_error;
            application_pipeline_support.ensureOwnedResponse(
                context,
                value,
                selected_limits,
                &mapped_error,
            );
            runResponsePhases(
                middleware,
                states,
                workspace.initialized_middleware,
                context,
                value,
                selected_limits,
                &mapped_error,
            );
            if (comptime application_pipeline_support.multipartFinalizationEnabled(
                @TypeOf(workspace.*),
            )) {
                if (mapped_error) workspace.multipart_commit = false;
                if (!mapped_before_response and mapped_error) {
                    workspace.multipart_abort_cause = null;
                }
            }
            return application_pipeline_serialize.finite(
                ResponseOutput,
                Outcome,
                middleware,
                value,
                pending_route,
                selected_limits,
                workspace,
                input,
                output,
                mapped_error,
                server_identity,
            );
        }
        pub fn prepareBorrowedResponse(
            comptime middleware: anytype,
            value: *Response,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            initial_mapped_error: bool,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            var mapped_error = initial_mapped_error;
            application_pipeline_support.ensureOwnedResponse(
                context,
                value,
                selected_limits,
                &mapped_error,
            );
            runResponsePhases(
                middleware,
                states,
                workspace.initialized_middleware,
                context,
                value,
                selected_limits,
                &mapped_error,
            );
            return application_pipeline_serialize.borrowed(
                ResponseOutput,
                Outcome,
                middleware,
                value,
                pending_route,
                selected_limits,
                workspace,
                input,
                output,
                mapped_error,
                server_identity,
            );
        }
        pub fn prepareRouteResult(
            comptime middleware: anytype,
            value: anytype,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            comptime framework_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            initial_mapped_error: bool,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            return switch (value.*) {
                .finite => |*finite| prepareResponse(
                    middleware,
                    finite,
                    pending_route,
                    selected_limits,
                    context,
                    workspace,
                    input,
                    output,
                    initial_mapped_error,
                    server_identity,
                ),
                .stream => |*stream| prepareStreamResponse(
                    middleware,
                    stream,
                    pending_route,
                    selected_limits,
                    framework_limits,
                    context,
                    workspace,
                    input,
                    output,
                    initial_mapped_error,
                    server_identity,
                ),
            };
        }
        fn prepareStreamResponse(
            comptime middleware: anytype,
            value: anytype,
            pending_route: anytype,
            comptime selected_limits: response.HeadLimits,
            comptime framework_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            input: anytype,
            output: []u8,
            initial_mapped_error: bool,
            server_identity: anytype,
        ) !application_response_output.Prepared {
            const StreamResponse = @TypeOf(value.*);
            var current = application_stream_pipeline.Result(Response, StreamResponse){
                .stream = value.*,
            };
            var mapped_error = initial_mapped_error;
            const mapped_before_response = mapped_error;
            ensureStreamResult(
                &current,
                selected_limits,
                context,
                workspace,
                &mapped_error,
            );
            runStreamResponsePhases(
                middleware,
                &current,
                selected_limits,
                context,
                workspace,
                &mapped_error,
            );
            if (comptime application_pipeline_support.multipartFinalizationEnabled(
                @TypeOf(workspace.*),
            )) {
                if (mapped_error) workspace.multipart_commit = false;
                if (!mapped_before_response and mapped_error) {
                    workspace.multipart_abort_cause = null;
                }
            }
            return switch (current) {
                .finite => |*finite| application_pipeline_serialize.finite(
                    ResponseOutput,
                    Outcome,
                    middleware,
                    finite,
                    pending_route,
                    selected_limits,
                    workspace,
                    input,
                    output,
                    mapped_error,
                    server_identity,
                ),
                .stream => |*stream| application_pipeline_serialize.stream(
                    Outcome,
                    middleware,
                    stream,
                    pending_route,
                    selected_limits,
                    framework_limits,
                    workspace,
                    input,
                    output,
                    mapped_error,
                    server_identity,
                ),
            };
        }
        pub fn runRequestPhases(
            comptime middleware: anytype,
            handler: anytype,
            body_input: anytype,
            context: *Context,
            states: anytype,
            initialized: *u64,
            mapped_error: *bool,
        ) Response {
            const head_result = runHeadPhases(
                middleware,
                context,
                states,
                initialized,
                mapped_error,
                .none,
            );
            return head_result orelse runBodyPhases(
                middleware,
                handler,
                body_input,
                {},
                {},
                null,
                context,
                states,
                initialized.*,
                mapped_error,
            );
        }
        pub fn runHeadPhases(
            comptime middleware: anytype,
            context: *Context,
            states: anytype,
            initialized: *u64,
            mapped_error: *bool,
            body_source: @import("../../csrf.zig").BodySource,
        ) ?Response {
            var result: ?Response = null;
            inline for (middleware, 0..) |item, index| {
                if (result == null) {
                    application_pipeline_support.initializeMiddleware(item, &states[index]);
                    application_csrf.bindBodySource(item, &states[index], body_source);
                    initialized.* |= @as(u64, 1) << @intCast(index);
                    if (@hasDecl(@TypeOf(item), "head")) {
                        result = invokeHead(item, context, &states[index], mapped_error);
                    }
                }
            }
            return result;
        }
        pub fn runBodyPhases(
            comptime middleware: anytype,
            handler: anytype,
            body_input: anytype,
            handler_state: anytype,
            multipart_summaries: anytype,
            multipart_commit: ?*bool,
            context: *Context,
            states: anytype,
            initialized: u64,
            mapped_error: *bool,
        ) Response {
            if (initialized != application_pipeline_support.initializedMask(middleware.len)) {
                mapped_error.* = true;
                return context.empty(.internal_server_error);
            }
            var result: ?Response = null;
            inline for (middleware, 0..) |item, index| {
                if (result == null and @hasDecl(@TypeOf(item), "body")) {
                    result = invokeBody(
                        item,
                        context,
                        &states[index],
                        body_input,
                        mapped_error,
                    );
                }
            }
            return result orelse invokeHandler(
                handler,
                context,
                body_input,
                handler_state,
                multipart_summaries,
                multipart_commit,
                mapped_error,
            );
        }
        pub fn runDeferredBodyPhases(
            comptime middleware: anytype,
            context: *Context,
            states: anytype,
            initialized: u64,
            mapped_error: *bool,
        ) ?Response {
            if (initialized != application_pipeline_support.initializedMask(middleware.len)) {
                mapped_error.* = true;
                return context.empty(.internal_server_error);
            }
            inline for (middleware, 0..) |item, index| {
                if (@hasDecl(@TypeOf(item), "body")) {
                    if (invokeBody(
                        item,
                        context,
                        &states[index],
                        @import("../../application/context.zig").Bodyless{},
                        mapped_error,
                    )) |value| return value;
                }
            }
            return null;
        }
        pub fn runStreamBodyPhases(
            comptime middleware: anytype,
            comptime handler: anytype,
            body_input: anytype,
            handler_state: anytype,
            context: *Context,
            states: anytype,
            initialized: u64,
            mapped_error: *bool,
        ) application_stream_pipeline.Result(
            Response,
            application_stream_pipeline.handlerPayload(handler),
        ) {
            const StreamResponse = application_stream_pipeline.handlerPayload(handler);
            if (initialized != application_pipeline_support.initializedMask(middleware.len)) {
                mapped_error.* = true;
                return .{ .finite = context.empty(.internal_server_error) };
            }
            inline for (middleware, 0..) |item, index| {
                if (@hasDecl(@TypeOf(item), "body")) {
                    if (invokeBody(
                        item,
                        context,
                        &states[index],
                        body_input,
                        mapped_error,
                    )) |finite| return .{ .finite = finite };
                }
            }
            const result = application_stream_pipeline.invoke(
                handler,
                context,
                body_input,
                handler_state,
                {},
            );
            return switch (@typeInfo(@TypeOf(result))) {
                .error_union => .{ .stream = result catch |problem| {
                    mapped_error.* = true;
                    return .{ .finite = mapError(mapper, context, problem) };
                } },
                else => .{ .stream = @as(StreamResponse, result) },
            };
        }

        pub fn runResponsePhases(
            comptime middleware: anytype,
            states: anytype,
            initialized: u64,
            context: *Context,
            value: *Response,
            comptime selected_limits: response.HeadLimits,
            mapped_error: *bool,
        ) void {
            inline for (0..middleware.len) |reverse| {
                const index = middleware.len - 1 - reverse;
                if (initialized & (@as(u64, 1) << @intCast(index)) != 0) {
                    const item = middleware[index];
                    if (@hasDecl(@TypeOf(item), "response")) {
                        const result = item.response(context, &states[index], value);
                        if (@typeInfo(@TypeOf(result)) == .error_union) {
                            result catch |problem| {
                                mapped_error.* = true;
                                value.* = mapError(mapper, context, problem);
                            };
                        }
                        application_pipeline_support.ensureOwnedResponse(
                            context,
                            value,
                            selected_limits,
                            mapped_error,
                        );
                    }
                }
            }
            if (!application_csrf.finalizeFinite(context, value)) {
                value.* = application_csrf.internalFailure(context);
                mapped_error.* = true;
            }
        }
        fn runStreamResponsePhases(
            comptime middleware: anytype,
            current: anytype,
            comptime selected_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            mapped_error: *bool,
        ) void {
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            inline for (0..middleware.len) |reverse| {
                const index = middleware.len - 1 - reverse;
                if (workspace.initialized_middleware &
                    (@as(u64, 1) << @intCast(index)) != 0)
                {
                    const item = middleware[index];
                    if (@hasDecl(@TypeOf(item), "response")) switch (current.*) {
                        .finite => |*finite| runFiniteResponseItem(
                            item,
                            context,
                            &states[index],
                            finite,
                            selected_limits,
                            mapped_error,
                        ),
                        .stream => |*stream| runStreamResponseItem(
                            item,
                            context,
                            &states[index],
                            current,
                            stream,
                            selected_limits,
                            workspace,
                            mapped_error,
                        ),
                    };
                }
            }
            if (!application_csrf.finalizeStreamResult(current, context, workspace)) {
                mapped_error.* = true;
            }
        }
        fn runFiniteResponseItem(
            comptime item: anytype,
            context: *Context,
            state: anytype,
            value: *Response,
            comptime selected_limits: response.HeadLimits,
            mapped_error: *bool,
        ) void {
            const result = item.response(context, state, value);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                result catch |problem| {
                    mapped_error.* = true;
                    value.* = mapError(mapper, context, problem);
                };
            }
            application_pipeline_support.ensureOwnedResponse(
                context,
                value,
                selected_limits,
                mapped_error,
            );
        }

        fn runStreamResponseItem(
            comptime item: anytype,
            context: *Context,
            state: anytype,
            current: anytype,
            value: anytype,
            comptime selected_limits: response.HeadLimits,
            workspace: anytype,
            mapped_error: *bool,
        ) void {
            const result = item.response(context, state, value);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                result catch |problem| {
                    application_pipeline_support.abandonStream(workspace, value);
                    var finite = mapError(mapper, context, problem);
                    mapped_error.* = true;
                    application_pipeline_support.ensureOwnedResponse(
                        context,
                        &finite,
                        selected_limits,
                        mapped_error,
                    );
                    current.* = .{ .finite = finite };
                    return;
                };
            }
            ensureStreamResult(
                current,
                selected_limits,
                context,
                workspace,
                mapped_error,
            );
        }

        fn ensureStreamResult(
            current: anytype,
            comptime selected_limits: response.HeadLimits,
            context: *Context,
            workspace: anytype,
            mapped_error: *bool,
        ) void {
            const value = switch (current.*) {
                .finite => return,
                .stream => |*stream| stream,
            };
            if (application_pipeline_support.streamResponseValid(
                context,
                value,
                selected_limits,
            )) return;
            application_pipeline_support.abandonStream(workspace, value);
            context.response_workspace.reset(selected_limits);
            current.* = .{ .finite = context.empty(.internal_server_error) };
            mapped_error.* = true;
        }

        fn invokeHead(
            comptime item: anytype,
            context: *Context,
            state: anytype,
            mapped_error: *bool,
        ) ?Response {
            const result = item.head(context, state);
            return unwrapOptionalResponse(result, context, mapped_error);
        }

        fn invokeBody(
            comptime item: anytype,
            context: *Context,
            state: anytype,
            body_input: anytype,
            mapped_error: *bool,
        ) ?Response {
            const result = item.body(context, state, body_input);
            return unwrapOptionalResponse(result, context, mapped_error);
        }

        fn unwrapOptionalResponse(
            value: anytype,
            context: *Context,
            mapped_error: *bool,
        ) ?Response {
            return switch (@typeInfo(@TypeOf(value))) {
                .error_union => value catch |problem| {
                    mapped_error.* = true;
                    return mapError(mapper, context, problem);
                },
                else => value,
            };
        }

        fn invokeHandler(
            handler: anytype,
            context: *Context,
            body_input: anytype,
            handler_state: anytype,
            multipart_summaries: anytype,
            multipart_commit: ?*bool,
            mapped_error: *bool,
        ) Response {
            const result = application_stream_pipeline.invoke(
                handler,
                context,
                body_input,
                handler_state,
                multipart_summaries,
            );
            if (comptime application_pipeline_support.multipartHandler(@TypeOf(handler))) {
                const decision = switch (@typeInfo(@TypeOf(result))) {
                    .error_union => result catch |problem| {
                        mapped_error.* = true;
                        if (multipart_commit) |value| value.* = false;
                        return mapError(mapper, context, problem);
                    },
                    else => result,
                };
                if (multipart_commit) |value| value.* = decision.commits();
                return decision.response().*;
            }
            return switch (@typeInfo(@TypeOf(result))) {
                .error_union => result catch |problem| {
                    mapped_error.* = true;
                    return mapError(mapper, context, problem);
                },
                else => result,
            };
        }
    };
}

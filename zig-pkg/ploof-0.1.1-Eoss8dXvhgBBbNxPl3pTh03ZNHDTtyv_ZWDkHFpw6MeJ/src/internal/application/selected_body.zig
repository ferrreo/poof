const body = @import("../../body.zig");
const route = @import("../../route.zig");
const application_body = @import("body.zig");
const application_compile = @import("compile.zig");
const application_csrf = @import("csrf.zig");
const application_endpoint_output = @import("endpoint_output.zig");
const application_finish = @import("finish.zig");
const application_json_response = @import("json_response.zig");
const application_multipart_dispatch = @import("multipart_combined_dispatch.zig");
const application_types = @import("types.zig");

pub fn Configured(
    comptime descriptors: anytype,
    comptime application_middleware: anytype,
    comptime Context: type,
    comptime Workspace: type,
    comptime AppError: type,
    comptime error_mapper: anytype,
    comptime Registry: type,
    comptime Input: type,
    comptime Pipeline: type,
    comptime Outcome: type,
    comptime PrepareError: type,
    comptime Prepared: type,
    comptime HeadResult: type,
    comptime BodyPlan: type,
    comptime logical: anytype,
    comptime maximum: anytype,
    comptime gzip_enabled: bool,
    comptime server_identity: anytype,
) type {
    const MultipartDispatch = application_multipart_dispatch.Configured(
        descriptors,
        Context,
        AppError,
        Registry,
    );

    return struct {
        pub fn continueAfterHead(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            selected_body_plan: BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            close_if_prepared: bool,
        ) PrepareError!HeadResult {
            const declared_body_plan = comptime application_body.plan(descriptor.handler);
            if (comptime declared_body_plan.kind != .none) {
                if (selected_body_plan.kind != declared_body_plan.kind) {
                    workspace.lifecycle = .idle;
                    return error.InvalidBodyInput;
                }
                context.json_response = null;
                workspace.request_data = .{
                    .awaiting = .{
                        .route_id = @intCast(route_id),
                        .selected_decoder = selected_body_plan.selected_decoder,
                        .multipart_phase = if (selected_body_plan.decoderKind() == .multipart)
                            .awaiting
                        else
                            .not_selected,
                        .input = input,
                    },
                };
                workspace.lifecycle = .awaiting_body;
                return .{ .receive_body = selected_body_plan };
            }
            var response_input = input;
            response_input.connection_close = input.connection_close or close_if_prepared;
            return .{ .prepared = try run(
                descriptor,
                route_id,
                middleware,
                context,
                workspace,
                input.body,
                null,
                &.{},
                [_]u8{0} ** 16,
                response_input,
                output,
            ) };
        }

        pub fn dispatch(
            target_route_id: u16,
            selected_decoder: ?u8,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            context: *Context,
            workspace: *Workspace,
            decoded: body.Decoded,
            input: Input,
            output: []u8,
        ) ?PrepareError!Prepared {
            return dispatchDescriptors(
                descriptors,
                .{},
                0,
                target_route_id,
                selected_decoder,
                request_workspace,
                json_hash_key,
                context,
                workspace,
                decoded,
                input,
                output,
            );
        }

        fn dispatchDescriptors(
            comptime current_descriptors: anytype,
            comptime inherited: anytype,
            comptime first_route_id: usize,
            target_route_id: u16,
            selected_decoder: ?u8,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            context: *Context,
            workspace: *Workspace,
            decoded: body.Decoded,
            input: Input,
            output: []u8,
        ) ?PrepareError!Prepared {
            comptime var route_id = first_route_id;
            inline for (current_descriptors) |descriptor| {
                const first = comptime route_id;
                const count = comptime switch (descriptor.kind) {
                    .route, .static_dir, .static_file => 1,
                    .group => application_compile.countRoutes(descriptor.children),
                };
                comptime {
                    route_id += count;
                }
                switch (descriptor.kind) {
                    .route => if (target_route_id == first) {
                        if (comptime route.isOpenMetricsHandler(descriptor.handler)) {
                            unreachable;
                        } else {
                            return run(
                                descriptor,
                                first,
                                application_middleware ++ inherited ++ descriptor.middleware,
                                context,
                                workspace,
                                decoded,
                                selected_decoder,
                                request_workspace,
                                json_hash_key,
                                input,
                                output,
                            );
                        }
                    },
                    .static_dir, .static_file => {},
                    .group => if (target_route_id >= first and target_route_id < first + count) {
                        return dispatchDescriptors(
                            descriptor.children,
                            inherited ++ descriptor.middleware,
                            first,
                            target_route_id,
                            selected_decoder,
                            request_workspace,
                            json_hash_key,
                            context,
                            workspace,
                            decoded,
                            input,
                            output,
                        );
                    },
                }
            }
            return null;
        }

        fn run(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            context: *Context,
            workspace: *Workspace,
            decoded: body.Decoded,
            selected_decoder: ?u8,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            input: Input,
            output: []u8,
        ) PrepareError!Prepared {
            if (comptime multipartHandler(@TypeOf(descriptor.handler))) {
                if (try prepareMultipartFailure(
                    descriptor,
                    route_id,
                    middleware,
                    selected_decoder,
                    request_workspace,
                    context,
                    workspace,
                    input,
                    output,
                )) |prepared| return prepared;
                if (try prepareMultipartRejection(
                    descriptor,
                    route_id,
                    middleware,
                    selected_decoder,
                    request_workspace,
                    context,
                    workspace,
                    input,
                    output,
                )) |prepared| return prepared;
            }
            const body_input = application_body.materializeSelectedCsrf(
                descriptor.handler,
                decoded,
                selected_decoder,
                input.raw_query,
                request_workspace,
                json_hash_key,
                context.csrf_request,
                application_csrf.formName(middleware),
            ) catch |problem| {
                if (problem == error.CsrfForbidden) return prepareCsrfRejection(
                    descriptor,
                    route_id,
                    middleware,
                    context,
                    workspace,
                    input,
                    output,
                );
                if (problem == error.InvalidRequestInput or
                    problem == error.RequestInputTooLarge)
                {
                    workspace.lifecycle = .awaiting_body;
                    return problem;
                }
                application_finish.abortInitialized(middleware, workspace, null, Outcome);
                return problem;
            };
            return runMaterialized(
                descriptor,
                route_id,
                middleware,
                body_input,
                selected_decoder,
                request_workspace,
                context,
                workspace,
                input,
                output,
            );
        }

        fn prepareCsrfRejection(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) PrepareError!Prepared {
            var value = application_csrf.forbidden(context);
            return Pipeline.prepareResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                descriptor.response_head_limits orelse logical,
                context,
                workspace,
                input,
                output,
                false,
                server_identity,
            );
        }

        fn prepareMultipartFailure(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            selected_decoder: ?u8,
            request_workspace: []u8,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) PrepareError!?Prepared {
            const failure = MultipartDispatch.applicationFailure(
                @TypeOf(descriptor.handler),
                selected_decoder,
                request_workspace,
            ) catch {
                application_finish.abortInitialized(middleware, workspace, null, Outcome);
                return error.InputInvariant;
            };
            const problem = failure orelse return null;
            workspace.multipart_commit = false;
            workspace.multipart_abort_cause = null;
            var value = if (error_mapper) |map|
                map(context, problem)
            else
                context.empty(.internal_server_error);
            return try Pipeline.prepareResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                descriptor.response_head_limits orelse logical,
                context,
                workspace,
                input,
                output,
                true,
                server_identity,
            );
        }

        fn prepareMultipartRejection(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            selected_decoder: ?u8,
            request_workspace: []u8,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) PrepareError!?Prepared {
            const rejection = MultipartDispatch.rejection(
                @TypeOf(descriptor.handler),
                selected_decoder,
                request_workspace,
            ) catch {
                application_finish.abortInitialized(middleware, workspace, null, Outcome);
                return error.InputInvariant;
            };
            var value = if (rejection) |selected| selected.* else blk: {
                const state = context.csrf_request orelse return null;
                if (state.status != .rejected) return null;
                break :blk switch (state.rejection) {
                    .forbidden => application_csrf.forbidden(context),
                    .misdirected_request => application_csrf.misdirected(context),
                };
            };
            workspace.multipart_commit = false;
            workspace.multipart_abort_cause = null;
            return try Pipeline.prepareResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                descriptor.response_head_limits orelse logical,
                context,
                workspace,
                input,
                output,
                false,
                server_identity,
            );
        }

        fn runMaterialized(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            body_input: anytype,
            selected_decoder: ?u8,
            request_workspace: []u8,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) PrepareError!Prepared {
            const Handler = @TypeOf(descriptor.handler);
            const is_multipart = comptime multipartHandler(Handler);
            bindJsonResponseWorkspace(
                Handler,
                context,
                workspace,
                request_workspace,
            ) catch |problem| {
                application_finish.abortInitialized(middleware, workspace, null, Outcome);
                return problem;
            };
            const handler_state = if (is_multipart)
                MultipartDispatch.statePointer(
                    Handler,
                    selected_decoder,
                    request_workspace,
                ) catch {
                    application_finish.abortInitialized(middleware, workspace, null, Outcome);
                    return error.InputInvariant;
                }
            else {};
            const multipart_summaries = if (is_multipart) MultipartDispatch.summaries(
                Handler,
                selected_decoder,
                request_workspace,
            ) catch {
                application_finish.abortInitialized(middleware, workspace, null, Outcome);
                return error.InputInvariant;
            } else {};
            return Pipeline.runSelectedBodyResponse(
                middleware,
                descriptor.handler,
                body_input,
                handler_state,
                multipart_summaries,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                descriptor.response_head_limits orelse logical,
                maximum,
                context,
                workspace,
                input,
                output,
                server_identity,
            );
        }

        pub fn bindJsonResponseWorkspace(
            comptime Handler: type,
            context: *Context,
            workspace: *Workspace,
            request_workspace: []u8,
        ) PrepareError!void {
            context.json_response = null;
            if (comptime !application_body.isEndpointType(Handler) or
                !@hasDecl(Handler, "ploof_input_endpoint")) return;
            var binding: application_json_response.Binding = undefined;
            try application_endpoint_output.bind(
                Handler,
                maximum,
                gzip_enabled,
                &binding,
                &workspace.json_response_written,
                request_workspace,
            );
            workspace.json_response_binding = binding;
            context.json_response = &workspace.json_response_binding;
        }
    };
}

fn multipartHandler(comptime Handler: type) bool {
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_multipart_endpoint") and
        Handler.ploof_multipart_endpoint;
}

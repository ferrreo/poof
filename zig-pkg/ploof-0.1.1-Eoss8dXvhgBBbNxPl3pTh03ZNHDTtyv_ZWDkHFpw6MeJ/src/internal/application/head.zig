const std = @import("std");
const application_compile = @import("compile.zig");
const application_static = @import("static.zig");
const application_types = @import("types.zig");
const response = @import("../../response.zig");
const route = @import("../../route.zig");
const route_graph = @import("../route_graph.zig");

const open_metrics_content_type = response.staticMediaType(
    "application/openmetrics-text; version=1.0.0; charset=utf-8",
);
const metrics_unavailable_body = "metrics unavailable\n";

pub fn Configured(
    comptime descriptors: anytype,
    comptime definitions: anytype,
    comptime application_middleware: anytype,
    comptime Context: type,
    comptime Response: type,
    comptime HeadResult: type,
    comptime Workspace: type,
    comptime Input: type,
    comptime Pipeline: type,
    comptime SelectedBody: type,
    comptime logical: anytype,
    comptime server_identity: anytype,
    comptime PrepareError: type,
) type {
    return struct {
        pub fn serve(
            matched: route_graph.RouteMatch,
            selected_body_plan: application_types.BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            request_workspace: []u8,
            output: []u8,
            policy: application_types.HeadPolicy,
        ) PrepareError!HeadResult {
            return dispatch(
                descriptors,
                .{},
                0,
                matched,
                selected_body_plan,
                context,
                workspace,
                input,
                request_workspace,
                output,
                policy,
            ) orelse unreachable;
        }

        pub fn resumeMetrics(
            workspace: *Workspace,
            target_route_id: u16,
            result: application_types.MetricsResult,
            output: []u8,
        ) ?PrepareError!application_types.Prepared {
            return resumeMetricsDispatch(
                descriptors,
                .{},
                0,
                workspace,
                target_route_id,
                result,
                output,
            );
        }

        fn resumeMetricsDispatch(
            comptime current: anytype,
            comptime inherited: anytype,
            comptime first_route_id: usize,
            workspace: *Workspace,
            target_route_id: u16,
            result: application_types.MetricsResult,
            output: []u8,
        ) ?PrepareError!application_types.Prepared {
            comptime var route_id = first_route_id;
            inline for (current) |descriptor| {
                const first = comptime route_id;
                const count = comptime switch (descriptor.kind) {
                    .route, .static_dir, .static_file => 1,
                    .group => application_compile.countRoutes(descriptor.children),
                };
                comptime route_id += count;
                switch (descriptor.kind) {
                    .route => if (target_route_id == first) {
                        if (comptime !route.isOpenMetricsHandler(descriptor.handler)) return null;
                        return prepareMetrics(
                            descriptor,
                            first,
                            application_middleware ++ inherited ++ descriptor.middleware,
                            workspace,
                            result,
                            output,
                        );
                    },
                    .static_dir, .static_file => {},
                    .group => if (target_route_id >= first and
                        target_route_id < first + count)
                    {
                        return resumeMetricsDispatch(
                            descriptor.children,
                            inherited ++ descriptor.middleware,
                            first,
                            workspace,
                            target_route_id,
                            result,
                            output,
                        );
                    },
                }
            }
            return null;
        }

        fn prepareMetrics(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            workspace: *Workspace,
            result: application_types.MetricsResult,
            output: []u8,
        ) PrepareError!application_types.Prepared {
            const selected_limits = descriptor.response_head_limits orelse logical;
            var value = switch (result) {
                .success => |body| Response.init(
                    &workspace.response,
                    .ok,
                    .{ .borrowed = body },
                    open_metrics_content_type,
                ) catch unreachable,
                .unavailable => Response.textStatic(
                    &workspace.response,
                    .service_unavailable,
                    metrics_unavailable_body,
                ),
            };
            return Pipeline.prepareBorrowedResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                selected_limits,
                &workspace.context,
                workspace,
                workspace.metrics.input,
                output,
                workspace.metrics.mapped_error,
                server_identity,
            );
        }

        fn dispatch(
            comptime current: anytype,
            comptime inherited: anytype,
            comptime first_route_id: usize,
            matched: route_graph.RouteMatch,
            selected_body_plan: application_types.BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            request_workspace: []u8,
            output: []u8,
            policy: application_types.HeadPolicy,
        ) ?PrepareError!HeadResult {
            comptime var route_id = first_route_id;
            inline for (current) |descriptor| {
                const first = comptime route_id;
                const count = comptime switch (descriptor.kind) {
                    .route, .static_dir, .static_file => 1,
                    .group => application_compile.countRoutes(descriptor.children),
                };
                comptime route_id += count;
                switch (descriptor.kind) {
                    .route => if (matched.route_id == first) return run(
                        descriptor,
                        first,
                        application_middleware ++ inherited ++ descriptor.middleware,
                        matched,
                        selected_body_plan,
                        context,
                        workspace,
                        input,
                        request_workspace,
                        output,
                        policy,
                    ),
                    .static_dir, .static_file => if (matched.route_id == first) {
                        return runStatic(
                            descriptor,
                            first,
                            application_middleware ++ inherited ++ descriptor.middleware,
                            matched,
                            selected_body_plan,
                            context,
                            workspace,
                            input,
                            output,
                            policy,
                        );
                    },
                    .group => if (matched.route_id >= first and matched.route_id < first + count) {
                        return dispatch(
                            descriptor.children,
                            inherited ++ descriptor.middleware,
                            first,
                            matched,
                            selected_body_plan,
                            context,
                            workspace,
                            input,
                            request_workspace,
                            output,
                            policy,
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
            matched: route_graph.RouteMatch,
            selected_body_plan: application_types.BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            request_workspace: []u8,
            output: []u8,
            policy: application_types.HeadPolicy,
        ) PrepareError!HeadResult {
            const selected_limits = descriptor.response_head_limits orelse logical;
            workspace.response.reset(selected_limits);
            context.request.route_pattern = definitions[route_id].path;
            context.request.captures = matched.captures;
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            workspace.initialized_middleware = 0;
            SelectedBody.bindJsonResponseWorkspace(
                @TypeOf(descriptor.handler),
                context,
                workspace,
                request_workspace,
            ) catch |problem| {
                workspace.lifecycle = .idle;
                return problem;
            };
            var mapped_error = false;
            if (Pipeline.runHeadPhases(
                middleware,
                context,
                states,
                &workspace.initialized_middleware,
                &mapped_error,
                @import("csrf.zig").bodySource(selected_body_plan),
            )) |head_value| {
                var value = head_value;
                var response_input = input;
                response_input.connection_close =
                    input.connection_close or policy.close_if_prepared;
                return .{ .prepared = try Pipeline.prepareResponse(
                    middleware,
                    &value,
                    application_types.PendingRoute{ .selected = @intCast(route_id) },
                    selected_limits,
                    context,
                    workspace,
                    response_input,
                    output,
                    mapped_error,
                    server_identity,
                ) };
            }
            if (comptime route.isOpenMetricsHandler(descriptor.handler)) {
                return continueOpenMetrics(
                    route_id,
                    middleware,
                    context,
                    states,
                    workspace,
                    selected_body_plan,
                    input,
                    output,
                    policy,
                    selected_limits,
                    &mapped_error,
                );
            }
            return SelectedBody.continueAfterHead(
                descriptor,
                route_id,
                middleware,
                selected_body_plan,
                context,
                workspace,
                input,
                output,
                policy.close_if_prepared,
            );
        }

        fn continueOpenMetrics(
            comptime route_id: usize,
            comptime middleware: anytype,
            context: *Context,
            states: anytype,
            workspace: *Workspace,
            selected_body_plan: application_types.BodyPlan,
            input: Input,
            output: []u8,
            policy: application_types.HeadPolicy,
            comptime selected_limits: anytype,
            mapped_error: *bool,
        ) PrepareError!HeadResult {
            if (selected_body_plan.kind != .none) {
                workspace.lifecycle = .idle;
                return error.InvalidBodyInput;
            }
            if (Pipeline.runDeferredBodyPhases(
                middleware,
                context,
                states,
                workspace.initialized_middleware,
                mapped_error,
            )) |body_value| {
                var value = body_value;
                var response_input = input;
                response_input.connection_close =
                    input.connection_close or policy.close_if_prepared;
                return .{ .prepared = try Pipeline.prepareResponse(
                    middleware,
                    &value,
                    application_types.PendingRoute{ .selected = @intCast(route_id) },
                    selected_limits,
                    context,
                    workspace,
                    response_input,
                    output,
                    mapped_error.*,
                    server_identity,
                ) };
            }
            workspace.metrics.route_id = @intCast(route_id);
            workspace.metrics.input = input;
            workspace.metrics.input.connection_close =
                input.connection_close or policy.close_if_prepared;
            workspace.metrics.mapped_error = mapped_error.*;
            workspace.lifecycle = .awaiting_metrics;
            return .{ .deferred_metrics = .{ .route_id = @intCast(route_id) } };
        }

        fn runStatic(
            comptime descriptor: anytype,
            comptime route_id: usize,
            comptime middleware: anytype,
            matched: route_graph.RouteMatch,
            selected_body_plan: application_types.BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            policy: application_types.HeadPolicy,
        ) PrepareError!HeadResult {
            const selected_limits = descriptor.response_head_limits orelse logical;
            var mapped_error = false;
            if (try runStaticHead(
                route_id,
                middleware,
                matched,
                selected_body_plan,
                context,
                workspace,
                input,
                output,
                policy,
                selected_limits,
                &mapped_error,
            )) |result| return result;
            const selected_path = selectStaticPath(descriptor, matched, input) orelse
                return staticNotFound(
                    route_id,
                    middleware,
                    selected_limits,
                    context,
                    workspace,
                    input,
                    output,
                    policy,
                    mapped_error,
                );
            var response_input = input;
            response_input.connection_close =
                input.connection_close or policy.close_if_prepared;
            workspace.live_static_route_id = @intCast(route_id);
            workspace.lifecycle = .awaiting_static;
            return .{ .prepared = .{
                .source = .{ .live_static = .{
                    .input = response_input,
                    .route_id = @intCast(route_id),
                    .root_index = application_static.routeRootIndex(
                        descriptors,
                        @intCast(route_id),
                    ).?,
                    .path = selected_path,
                } },
                .bytes = "",
                .status = .ok,
                .close_connection = response_input.connection_close,
                .coding_outcome = .identity_disabled,
            } };
        }

        fn runStaticHead(
            comptime route_id: usize,
            comptime middleware: anytype,
            matched: route_graph.RouteMatch,
            selected_body_plan: application_types.BodyPlan,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            policy: application_types.HeadPolicy,
            comptime selected_limits: anytype,
            mapped_error: *bool,
        ) PrepareError!?HeadResult {
            workspace.response.reset(selected_limits);
            context.request.route_pattern = definitions[route_id].path;
            context.request.captures = matched.captures;
            const States = application_compile.StateTuple(middleware);
            const states: *States = @ptrCast(&workspace.middleware_state);
            workspace.initialized_middleware = 0;
            const head_value = Pipeline.runHeadPhases(
                middleware,
                context,
                states,
                &workspace.initialized_middleware,
                mapped_error,
                @import("csrf.zig").bodySource(selected_body_plan),
            ) orelse return null;
            var value = head_value;
            var response_input = input;
            response_input.connection_close =
                input.connection_close or policy.close_if_prepared;
            return .{ .prepared = try Pipeline.prepareResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                selected_limits,
                context,
                workspace,
                response_input,
                output,
                mapped_error.*,
                server_identity,
            ) };
        }

        fn staticNotFound(
            comptime route_id: usize,
            comptime middleware: anytype,
            comptime selected_limits: anytype,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            policy: application_types.HeadPolicy,
            mapped_error: bool,
        ) PrepareError!HeadResult {
            var value = context.empty(.not_found);
            var response_input = input;
            response_input.connection_close =
                input.connection_close or policy.close_if_prepared;
            return .{ .prepared = try Pipeline.prepareResponse(
                middleware,
                &value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                selected_limits,
                context,
                workspace,
                response_input,
                output,
                mapped_error,
                server_identity,
            ) };
        }
    };
}

fn selectStaticPath(
    comptime descriptor: anytype,
    matched: route_graph.RouteMatch,
    input: anytype,
) ?application_types.LiveStaticPath {
    return switch (descriptor.kind) {
        .static_file => .{ .file = descriptor.relative_path },
        .static_dir => directory: {
            const capture = staticCapture(matched.captures) orelse return null;
            const raw_suffix = correspondingRawSuffix(
                input.raw_path,
                input.path,
                capture.start,
            ) orelse return null;
            break :directory switch (descriptor.selectPath(
                raw_suffix,
                capture.value(input.path),
            )) {
                .selected => |selected| .{ .directory = .{
                    .relative_path = selected.relative_path,
                    .trailing_slash = selected.trailing_slash,
                    .index_name = descriptor.index_name,
                } },
                .rejected => null,
            };
        },
        else => unreachable,
    };
}

fn staticCapture(captures: []const route_graph.Capture) ?route_graph.Capture {
    for (captures) |capture| {
        if (capture.kind == .catch_all and
            std.mem.eql(u8, capture.name, "__ploof_live_static_path")) return capture;
    }
    return null;
}

fn correspondingRawSuffix(
    raw_path: []const u8,
    decoded_path: []const u8,
    decoded_start: u32,
) ?[]const u8 {
    if (decoded_start > decoded_path.len) return null;
    var raw_index: usize = 0;
    var decoded_index: usize = 0;
    while (decoded_index < decoded_start) {
        if (raw_index >= raw_path.len) return null;
        const byte = if (raw_path[raw_index] == '%') blk: {
            if (raw_index + 2 >= raw_path.len) return null;
            const high = hexNibble(raw_path[raw_index + 1]) orelse return null;
            const low = hexNibble(raw_path[raw_index + 2]) orelse return null;
            raw_index += 3;
            break :blk high << 4 | low;
        } else blk: {
            const value = raw_path[raw_index];
            raw_index += 1;
            break :blk value;
        };
        if (byte != decoded_path[decoded_index]) return null;
        decoded_index += 1;
    }
    return raw_path[raw_index..];
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

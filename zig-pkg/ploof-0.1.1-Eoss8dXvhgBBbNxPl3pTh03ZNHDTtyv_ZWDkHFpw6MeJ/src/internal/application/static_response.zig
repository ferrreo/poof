const std = @import("std");
const application_compile = @import("compile.zig");
const application_runtime = @import("runtime.zig");
const application_types = @import("types.zig");
const static_file = @import("../../static_file.zig");

pub fn Configured(
    comptime descriptors: anytype,
    comptime application_middleware: anytype,
    comptime Workspace: type,
    comptime Response: type,
    comptime Pipeline: type,
    comptime logical: anytype,
    comptime server_identity: anytype,
    comptime PrepareError: type,
) type {
    return struct {
        pub fn prepare(
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            resolution: static_file.RuntimeResolution,
            output: []u8,
        ) PrepareError!application_types.Prepared {
            if (workspace.lifecycle != .awaiting_static or
                workspace.live_static_route_id != intent.route_id)
            {
                return error.NoPendingRequest;
            }
            return dispatch(
                descriptors,
                .{},
                0,
                workspace,
                intent,
                resolution,
                output,
            ) orelse error.NoPendingRequest;
        }

        fn dispatch(
            comptime current: anytype,
            comptime inherited: anytype,
            comptime first_route_id: usize,
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            resolution: static_file.RuntimeResolution,
            output: []u8,
        ) ?PrepareError!application_types.Prepared {
            comptime var route_id = first_route_id;
            inline for (current) |descriptor| {
                const first = comptime route_id;
                const route_count = comptime switch (descriptor.kind) {
                    .route, .static_dir, .static_file => 1,
                    .group => application_compile.countRoutes(descriptor.children),
                };
                comptime route_id += route_count;
                switch (descriptor.kind) {
                    .route => {},
                    .static_dir, .static_file => if (intent.route_id == first) {
                        return run(
                            descriptor,
                            first,
                            application_middleware ++ inherited ++ descriptor.middleware,
                            workspace,
                            intent,
                            resolution,
                            output,
                        );
                    },
                    .group => if (intent.route_id >= first and
                        intent.route_id < first + route_count)
                    {
                        return dispatch(
                            descriptor.children,
                            inherited ++ descriptor.middleware,
                            first,
                            workspace,
                            intent,
                            resolution,
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
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            resolution: static_file.RuntimeResolution,
            output: []u8,
        ) PrepareError!application_types.Prepared {
            const selected_limits = descriptor.response_head_limits orelse logical;
            var selected = try selectResponse(descriptor, workspace, intent, resolution);
            var prepared = try Pipeline.prepareResponse(
                middleware,
                &selected.value,
                application_types.PendingRoute{ .selected = @intCast(route_id) },
                selected_limits,
                &workspace.context,
                workspace,
                intent.input,
                output,
                false,
                server_identity,
            );
            if (!selected.value.body.isExternal()) return prepared;
            const span = selected.span orelse return error.InvalidResponse;
            const head = switch (prepared.source) {
                .contiguous_wire => |wire| wire,
                else => return error.InvalidResponse,
            };
            prepared.source = .{ .live_static_file = .{
                .head = head,
                .offset = span.offset,
                .length = span.length,
                .transfer_body = span.transfer_body,
            } };
            prepared.bytes = "";
            return prepared;
        }

        const Selected = struct {
            value: Response,
            span: ?static_file.Span = null,
        };

        fn selectResponse(
            comptime descriptor: anytype,
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            resolution: static_file.RuntimeResolution,
        ) PrepareError!Selected {
            return switch (resolution) {
                .not_found => .{ .value = workspace.context.empty(.not_found) },
                .unavailable => .{ .value = workspace.context.empty(.service_unavailable) },
                .internal_error => .{
                    .value = workspace.context.empty(.internal_server_error),
                },
                .redirect_directory => .{
                    .value = try redirectResponse(descriptor, workspace, intent),
                },
                .file => |file| fileResponse(descriptor, workspace, intent, file),
            };
        }

        fn redirectResponse(
            comptime descriptor: anytype,
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
        ) PrepareError!Response {
            if (descriptor.kind != .static_dir) return error.InvalidResponse;
            const location = application_runtime.buildRedirectLocation(
                workspace,
                intent.input,
                .{ .slash_change = .add },
            ) catch |problem| switch (problem) {
                error.RedirectLocationTooLarge => return error.ResponseHeadTooLarge,
                error.InvalidRoutePlan => return error.InvalidRoutePlan,
            };
            var value = workspace.context.empty(.permanent_redirect);
            try value.setHeader("Location", location);
            try value.setHeader("Cache-Control", descriptor.cache_control);
            return value;
        }

        fn fileResponse(
            comptime descriptor: anytype,
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            file: static_file.RuntimeFile,
        ) PrepareError!Selected {
            if (file.identity.size > std.math.maxInt(i64)) {
                return .{ .value = workspace.context.empty(.internal_server_error) };
            }
            var validators = static_file.buildValidators(
                file.identity,
                file.message_epoch_second,
            ) catch return .{ .value = workspace.context.empty(.internal_server_error) };
            const reference_year = static_file.referenceYear(file.message_epoch_second) orelse
                return .{ .value = workspace.context.empty(.internal_server_error) };
            const precondition = static_file.evaluateRequestPreconditions(
                &validators,
                intent.input.headers,
                reference_year,
            );
            var selected: Selected = switch (precondition) {
                .not_modified => .{ .value = workspace.context.empty(.not_modified) },
                .precondition_failed => .{
                    .value = workspace.context.empty(.precondition_failed),
                },
                .proceed => try rangedResponse(
                    descriptor,
                    workspace,
                    intent,
                    file,
                    &validators,
                ),
            };
            try selected.value.setHeader("Cache-Control", descriptor.cache_control);
            try selected.value.setHeader("ETag", validators.etag());
            try selected.value.setHeader("Last-Modified", validators.lastModified());
            try selected.value.setHeader("Accept-Ranges", "bytes");
            try selected.value.setHeader("X-Content-Type-Options", "nosniff");
            return selected;
        }

        fn rangedResponse(
            comptime descriptor: anytype,
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            file: static_file.RuntimeFile,
            validators: *const static_file.Validators,
        ) PrepareError!Selected {
            const method: static_file.Method = if (std.mem.eql(u8, intent.input.method, "HEAD"))
                .head
            else
                .get;
            return switch (static_file.evaluateRequestRange(
                method,
                validators,
                intent.input.headers,
            )) {
                .complete => |span| .{
                    .value = Response.__external(
                        &workspace.response,
                        .ok,
                        span.length,
                        mediaType(descriptor, file.filename),
                    ) catch return error.InvalidResponse,
                    .span = span,
                },
                .partial => |partial| partial: {
                    var content_range: [static_file.content_range_bytes_max]u8 = undefined;
                    const value = partial.content_range.write(&content_range) catch unreachable;
                    var response_value = Response.__external(
                        &workspace.response,
                        .partial_content,
                        partial.span.length,
                        mediaType(descriptor, file.filename),
                    ) catch return error.InvalidResponse;
                    try response_value.setHeader("Content-Range", value);
                    break :partial .{
                        .value = response_value,
                        .span = partial.span,
                    };
                },
                .unsatisfiable => |range| unsatisfied: {
                    var content_range: [static_file.content_range_bytes_max]u8 = undefined;
                    const value = range.write(&content_range) catch unreachable;
                    var response_value = workspace.context.empty(.range_not_satisfiable);
                    try response_value.setHeader("Content-Range", value);
                    break :unsatisfied .{ .value = response_value };
                },
            };
        }

        fn mediaType(comptime descriptor: anytype, filename: []const u8) static_file.MediaType {
            return switch (descriptor.kind) {
                .static_file => descriptor.media_type,
                .static_dir => static_file.mediaForFilename(filename),
                else => unreachable,
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

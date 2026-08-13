const application_compile = @import("compile.zig");
const application_response_output = @import("response_output.zig");
const application_runtime = @import("runtime.zig");
const route_graph = @import("../route_graph.zig");

pub fn Runtime(
    comptime descriptors: anytype,
    comptime logical: anytype,
    comptime app_middleware: anytype,
    comptime Context: type,
    comptime Workspace: type,
    comptime Input: type,
    comptime Pipeline: type,
    comptime Bodyless: type,
    comptime pending_route: anytype,
    comptime server_identity: anytype,
) type {
    return struct {
        pub fn prepare(
            selection: route_graph.Selection,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) !application_response_output.Prepared {
            if (selection == .redirect and selection.redirect.route_id != null) {
                return dispatchRedirect(
                    descriptors,
                    0,
                    selection.redirect.route_id.?,
                    selection,
                    context,
                    workspace,
                    input,
                    output,
                ) orelse unreachable;
            }
            return run(selection, logical, context, workspace, input, output);
        }

        fn dispatchRedirect(
            comptime children: anytype,
            comptime first_route_id: usize,
            target_route_id: u16,
            selection: route_graph.Selection,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) ?@TypeOf(run(selection, logical, context, workspace, input, output)) {
            comptime var route_id = first_route_id;
            inline for (children) |descriptor| {
                const first = comptime route_id;
                const count = comptime switch (descriptor.kind) {
                    .route, .static_dir, .static_file => 1,
                    .group => application_compile.countRoutes(descriptor.children),
                };
                comptime {
                    route_id += count;
                }
                switch (descriptor.kind) {
                    .route, .static_dir, .static_file => if (target_route_id == first) {
                        return run(
                            selection,
                            descriptor.response_head_limits orelse logical,
                            context,
                            workspace,
                            input,
                            output,
                        );
                    },
                    .group => if (target_route_id >= first and target_route_id < first + count) {
                        return dispatchRedirect(
                            descriptor.children,
                            first,
                            target_route_id,
                            selection,
                            context,
                            workspace,
                            input,
                            output,
                        );
                    },
                }
            }
            return null;
        }

        fn run(
            selection: route_graph.Selection,
            comptime selected_limits: anytype,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
        ) !application_response_output.Prepared {
            workspace.response.reset(selected_limits);
            const GeneratedHandler = Handler(Context, Workspace, Input, selected_limits);
            return Pipeline.runWholeRequest(
                app_middleware,
                GeneratedHandler{
                    .selection = selection,
                    .workspace = workspace,
                    .input = input,
                },
                Bodyless{},
                pending_route,
                selected_limits,
                context,
                workspace,
                input,
                output,
                server_identity,
            );
        }
    };
}

pub fn Handler(
    comptime Context: type,
    comptime Workspace: type,
    comptime Input: type,
    comptime logical: anytype,
) type {
    return struct {
        selection: route_graph.Selection,
        workspace: *Workspace,
        input: Input,

        pub fn handle(self: @This(), context: *Context) Context.ResponseType {
            return make(
                self.selection,
                context,
                self.workspace,
                self.input,
            ) catch {
                self.workspace.response.reset(logical);
                return context.empty(.internal_server_error);
            };
        }
    };
}

fn make(
    selection: route_graph.Selection,
    context: anytype,
    workspace: anytype,
    input: anytype,
) !@TypeOf(context.*).ResponseType {
    var generated = switch (selection) {
        .redirect => |redirect| switch (redirect.status) {
            .moved_permanently => context.empty(.moved_permanently),
            .temporary_redirect => context.empty(.temporary_redirect),
        },
        .options => context.empty(.no_content),
        .method_not_allowed => context.empty(.method_not_allowed),
        .not_implemented => context.empty(.not_implemented),
        .not_found => context.empty(.not_found),
        .selected => unreachable,
    };
    switch (selection) {
        .redirect => |redirect| {
            const location = try application_runtime.buildRedirectLocation(
                workspace,
                input,
                redirect,
            );
            try generated.setHeader("location", location);
        },
        .options, .method_not_allowed => |allow| {
            const value = allow.write(&workspace.allow) catch unreachable;
            try generated.setHeader("allow", value);
        },
        else => {},
    }
    return generated;
}

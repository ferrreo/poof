const application_types = @import("types.zig");

pub fn Configured(
    comptime App: type,
    comptime AssetRuntime: type,
    comptime Head: type,
    comptime ServeError: type,
    comptime ServeResult: type,
    comptime PrepareError: type,
    comptime HeadResult: type,
) type {
    return struct {
        pub fn serve(
            state: anytype,
            workspace: anytype,
            route_workspace: anytype,
            input: anytype,
            output: []u8,
        ) ServeError!ServeResult {
            var prepared = try App.prepare(state, workspace, route_workspace, input, output);
            if (application_types.isStream(prepared)) {
                _ = try App.__abortWithTransport(workspace, .aborted);
                return error.StreamingRequiresTransport;
            }
            AssetRuntime.materializeBorrowed(&prepared, output) catch |problem| {
                _ = App.__abortWithTransport(workspace, .aborted) catch unreachable;
                return problem;
            };
            const outcome = try App.complete(workspace);
            return application_types.serveResult(prepared, outcome);
        }

        pub fn selectedHead(
            matched: anytype,
            selected_body_plan: anytype,
            context: anytype,
            workspace: anytype,
            input: anytype,
            request_workspace: []u8,
            output: []u8,
            policy: anytype,
        ) PrepareError!HeadResult {
            return Head.serve(
                matched,
                selected_body_plan,
                context,
                workspace,
                input,
                request_workspace,
                output,
                policy,
            );
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

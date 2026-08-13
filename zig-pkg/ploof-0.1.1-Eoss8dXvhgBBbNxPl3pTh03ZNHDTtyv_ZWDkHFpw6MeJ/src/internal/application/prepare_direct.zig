const application_context = @import("../../application/context.zig");
const application_types = @import("types.zig");
const body = @import("../../body.zig");

pub fn Configured(
    comptime metrics_enabled: bool,
    comptime State: type,
    comptime Workspace: type,
    comptime RouteSearchWorkspace: type,
    comptime Input: type,
    comptime Plan: type,
    comptime PrepareError: type,
    comptime Prepared: type,
    comptime HeadResult: type,
    comptime plan: fn (Input, *RouteSearchWorkspace) Plan,
    comptime prepare_head: fn (
        *State,
        *Workspace,
        []u8,
        *const Plan,
        application_types.HeadPolicy,
    ) PrepareError!HeadResult,
    comptime prepare_head_in: fn (
        *State,
        *Workspace,
        []u8,
        []u8,
        *const Plan,
        application_types.HeadPolicy,
    ) PrepareError!HeadResult,
    comptime prepare_body: fn (
        *Workspace,
        body.Decoded,
        application_context.RequestTrailers,
        []u8,
    ) PrepareError!Prepared,
) type {
    return struct {
        /// Prepares routes whose head phases need no typed-endpoint workspace.
        /// Use `headIn` when `Context.json` can run before the body phase.
        pub fn head(
            state: *State,
            workspace: *Workspace,
            route_workspace: *RouteSearchWorkspace,
            input: Input,
            output: []u8,
        ) PrepareError!HeadResult {
            var request_plan = plan(input, route_workspace);
            return prepare_head(state, workspace, output, &request_plan, .{});
        }

        pub fn headIn(
            state: *State,
            workspace: *Workspace,
            route_workspace: *RouteSearchWorkspace,
            input: Input,
            request_workspace: []u8,
            output: []u8,
        ) PrepareError!HeadResult {
            var request_plan = plan(input, route_workspace);
            return prepare_head_in(
                state,
                workspace,
                request_workspace,
                output,
                &request_plan,
                .{},
            );
        }

        pub fn prepare(
            state: *State,
            workspace: *Workspace,
            route_workspace: *RouteSearchWorkspace,
            input: Input,
            output: []u8,
        ) PrepareError!Prepared {
            var request_plan = plan(input, route_workspace);
            return preparePlanned(state, workspace, output, &request_plan);
        }

        pub fn preparePlanned(
            state: *State,
            workspace: *Workspace,
            output: []u8,
            request_plan: *const Plan,
        ) PrepareError!Prepared {
            const input = request_plan.input;
            if (!bodyMatches(input.body, request_plan.body.kind)) {
                return error.InvalidBodyInput;
            }
            const decoded = input.body;
            var head_input = input;
            head_input.body = .none;
            var head_plan = request_plan.*;
            head_plan.input = head_input;
            const head_result = try prepare_head(
                state,
                workspace,
                output,
                &head_plan,
                .{},
            );
            if (comptime metrics_enabled) return switch (head_result) {
                .prepared => |prepared| requireDirect(prepared),
                .receive_body => prepare_body(workspace, decoded, input.trailers, output),
                .deferred_metrics => error.MetricsRequiresTransport,
            };
            return switch (head_result) {
                .prepared => |prepared| requireDirect(prepared),
                .receive_body => prepare_body(workspace, decoded, input.trailers, output),
            };
        }
    };
}

fn bodyMatches(decoded: body.Decoded, expected: anytype) bool {
    return switch (decoded) {
        .none => expected == .none,
        .bytes => expected == .bytes,
        .text => expected == .text,
    };
}

fn requireDirect(
    prepared: application_types.Prepared,
) error{LiveStaticRequiresTransport}!application_types.Prepared {
    if (prepared.source == .live_static) return error.LiveStaticRequiresTransport;
    return prepared;
}

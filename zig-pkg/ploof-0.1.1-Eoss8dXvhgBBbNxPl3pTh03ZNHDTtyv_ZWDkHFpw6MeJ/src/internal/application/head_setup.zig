const application_runtime = @import("runtime.zig");
const route_graph = @import("../route_graph.zig");

pub fn Configured(
    comptime multipart_enabled: bool,
    comptime logical: anytype,
    comptime Planner: type,
    comptime CorsRun: type,
    comptime State: type,
    comptime Input: type,
    comptime Plan: type,
    comptime Prepared: type,
    comptime Error: type,
) type {
    return struct {
        pub const Result = struct {
            input: Input,
            selection: route_graph.Selection,
            preflight: ?Prepared,
        };

        pub fn run(
            state: *State,
            workspace: anytype,
            input: Input,
            request_plan: *const Plan,
            output: []u8,
            close: bool,
        ) Error!Result {
            switch (input.body) {
                .none => {},
                .bytes, .text => return error.InvalidBodyInput,
            }
            if (workspace.lifecycle != .idle) return error.RequestAlreadyPending;
            const materialized = try Planner.materialize(
                request_plan,
                &workspace.captures,
            );
            const selection = materialized.selection;
            if (request_plan.finite_output == .chunks and
                workspace.finite_output.get() == null)
            {
                return error.HtmlRequiresTransport;
            }
            var head_input = input;
            head_input.trailers = .{};
            workspace.lifecycle = .preparing;
            if (comptime multipart_enabled) {
                workspace.multipart_commit = false;
                workspace.multipart_finalization = .not_required;
                workspace.multipart_abort_mapped_error = false;
                workspace.multipart_abort_cause = null;
            }
            workspace.response.reset(logical);
            workspace.json_response_written = false;
            workspace.context = .{
                .state = state,
                .request = application_runtime.requestFromInput(head_input),
                .response_workspace = &workspace.response,
                .response_body = &workspace.response_body,
            };
            const preflight = CorsRun.run(
                materialized.extension,
                workspace,
                &head_input,
                output,
                close,
            ) catch |err| {
                workspace.lifecycle = .idle;
                return err;
            };
            return .{ .input = head_input, .selection = selection, .preflight = preflight };
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

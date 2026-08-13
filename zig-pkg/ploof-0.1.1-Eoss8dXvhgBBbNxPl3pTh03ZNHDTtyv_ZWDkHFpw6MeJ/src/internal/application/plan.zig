const std = @import("std");
const application_body = @import("body.zig");
const application_finite_output = @import("finite_output.zig");
const route = @import("../../route.zig");
const route_graph = @import("../route_graph.zig");
const route_graph_method = @import("../route_graph/method.zig");

const input_seal_seed: u64 = 0x706c_6f6f_662e_706c;

/// Owns route selection across the request-workspace lease boundary.
pub fn Planner(
    comptime Router: type,
    comptime body_plans: []const application_body.Plan,
    comptime finite_output_plans: []const application_finite_output.Plan,
) type {
    const Configured = ConfiguredPlanner(
        Router,
        body_plans,
        finite_output_plans,
        route_graph.SelectInput,
        struct {},
    );
    return struct {
        pub const Plan = Configured.Plan;

        pub fn make(input: route_graph.SelectInput, workspace: *Router.SearchWorkspace) Plan {
            return Configured.make(input, input, .{}, workspace);
        }

        pub fn materialize(
            plan: *const Plan,
            captures: *Router.CaptureBuffer,
        ) Router.MaterializeError!route_graph.Selection {
            return Configured.materialize(
                plan,
                plan.input.method,
                plan.input,
                captures,
            );
        }
    };
}

pub fn ConfiguredPlanner(
    comptime Router: type,
    comptime body_plans: []const application_body.Plan,
    comptime finite_output_plans: []const application_finite_output.Plan,
    comptime Input: type,
    comptime Extension: type,
) type {
    const Types = PlannerTypes(Router, Input, Extension);
    return struct {
        pub const Plan = Types.Plan;
        pub const CaptureBuffer = Router.CaptureBuffer;
        pub const MaterializeError = Router.MaterializeError;
        pub const Selection = route_graph.Selection;

        pub fn make(
            input: Input,
            selection_input: route_graph.SelectInput,
            extension: Extension,
            workspace: *Router.SearchWorkspace,
        ) Plan {
            const planned_selection = Router.plan(selection_input, workspace);
            var result = Plan{
                .input = input,
                .input_seal = inputSeal(input),
                .configuration_seal = 0,
                .request_method = route_graph_method.parse(input.method),
                .routing_method = route_graph_method.parse(selection_input.method),
                .terminal_slash_is_literal = selection_input.terminal_slash_is_literal,
                .selection = planned_selection,
                .body = switch (planned_selection) {
                    .selected => |matched| body_plans[matched.route_id],
                    else => application_body.none_plan,
                },
                .finite_output = switch (planned_selection) {
                    .selected => |matched| finite_output_plans[matched.route_id],
                    else => .contiguous,
                },
                .extension = extension,
            };
            reseal(&result);
            return result;
        }

        pub fn reseal(plan: *Plan) void {
            plan.configuration_seal = configurationSeal(plan.*);
        }

        pub fn refineBody(plan: *Plan, body_plan: application_body.Plan) MaterializeError!void {
            try validate(plan, plan.input.method);
            if (!validBodyRefinement(plan.body, body_plan)) {
                return error.InvalidRoutePlan;
            }
            plan.body = body_plan;
            reseal(plan);
        }

        pub fn validate(plan: *const Plan, request_method: []const u8) MaterializeError!void {
            if (plan.input_seal != inputSeal(plan.input) or
                plan.configuration_seal != configurationSeal(plan.*) or
                plan.request_method != route_graph_method.parse(request_method))
            {
                return error.InvalidRoutePlan;
            }
        }

        pub fn materialize(
            plan: *const Plan,
            request_method: []const u8,
            selection_input: route_graph.SelectInput,
            captures: *Router.CaptureBuffer,
        ) Router.MaterializeError!route_graph.Selection {
            try validate(plan, request_method);
            return materializeValidated(plan, selection_input, captures);
        }

        pub fn materializeValidated(
            plan: *const Plan,
            selection_input: route_graph.SelectInput,
            captures: *Router.CaptureBuffer,
        ) Router.MaterializeError!route_graph.Selection {
            if (plan.routing_method != route_graph_method.parse(selection_input.method) or
                plan.terminal_slash_is_literal != selection_input.terminal_slash_is_literal)
            {
                return error.InvalidRoutePlan;
            }
            return Router.materialize(plan.selection, selection_input.path, captures);
        }
    };
}

fn PlannerTypes(comptime Router: type, comptime Input: type, comptime Extension: type) type {
    return struct {
        const Plan = struct {
            input: Input,
            input_seal: u64,
            configuration_seal: u64,
            request_method: ?route_graph_method.Parsed,
            routing_method: ?route_graph_method.Parsed,
            terminal_slash_is_literal: bool,
            selection: Router.PlannedSelection,
            body: application_body.Plan,
            finite_output: application_finite_output.Plan,
            extension: Extension,
        };
    };
}

fn configurationSeal(plan: anytype) u64 {
    var hash = std.hash.Wyhash.init(input_seal_seed ^ 0x7365_6c65_6374_696f);
    sealField(&hash, plan.input_seal);
    sealField(&hash, plan.request_method);
    sealField(&hash, plan.routing_method);
    sealField(&hash, plan.terminal_slash_is_literal);
    sealField(&hash, plan.selection);
    sealField(&hash, plan.body);
    sealField(&hash, plan.finite_output);
    sealField(&hash, plan.extension);
    return hash.final();
}

fn inputSeal(input: anytype) u64 {
    var hash = std.hash.Wyhash.init(input_seal_seed);
    if (comptime @hasField(@TypeOf(input), "raw_target")) {
        sealField(&hash, input.method);
        sealField(&hash, input.path);
        sealField(&hash, input.raw_target);
        sealField(&hash, input.raw_path);
        sealField(&hash, input.raw_query);
        sealField(&hash, input.date);
        sealField(&hash, input.connection_close);
        sealField(&hash, input.accept_encoding);
        sealField(&hash, input.accepts_response_trailers);
        sealField(&hash, input.headers);
        sealField(&hash, input.forwarding);
    } else {
        std.hash.autoHashStrat(&hash, input, .Shallow);
    }
    return hash.final();
}

inline fn sealField(hash: anytype, value: anytype) void {
    std.hash.autoHashStrat(hash, value, .Shallow);
}

fn validBodyRefinement(
    original: application_body.Plan,
    refined: application_body.Plan,
) bool {
    if (original.kind != refined.kind or
        !sameSlice(original.accepted_media, refined.accepted_media) or
        !sameSlice(original.media_decoder_indices, refined.media_decoder_indices) or
        !sameSlice(original.decoders, refined.decoders) or
        original.workspace_bytes_max != refined.workspace_bytes_max or
        original.workspace_alignment != refined.workspace_alignment or
        original.workspace_class != refined.workspace_class)
    {
        return false;
    }
    if (refined.selected_decoder == original.selected_decoder) {
        return refined.encoded_wire_bytes_max == original.encoded_wire_bytes_max and
            refined.decoded_bytes_max == original.decoded_bytes_max;
    }
    if (original.selected_decoder != null) return false;
    const decoder_index = refined.selected_decoder orelse return false;
    if (decoder_index >= original.decoders.len) return false;
    const decoder = original.decoders[decoder_index];
    return refined.encoded_wire_bytes_max == decoder.encoded_wire_bytes_max and
        refined.decoded_bytes_max == decoder.decoded_bytes_max;
}

fn sameSlice(left: anytype, right: @TypeOf(left)) bool {
    return left.len == right.len and @intFromPtr(left.ptr) == @intFromPtr(right.ptr);
}

test "body plan refinement changes only a declared decoder selection" {
    const decoders = [_]application_body.Decoder{.{
        .kind = .text,
        .encoded_wire_bytes_max = 11,
        .decoded_bytes_max = 7,
    }};
    const original = application_body.Plan{
        .kind = .structured,
        .encoded_wire_bytes_max = 17,
        .decoded_bytes_max = 13,
        .accepted_media = &.{},
        .media_decoder_indices = &.{},
        .decoders = &decoders,
        .selected_decoder = null,
        .workspace_bytes_max = 64,
        .workspace_alignment = 8,
        .workspace_class = 1,
    };
    var selected = original;
    selected.selected_decoder = 0;
    selected.encoded_wire_bytes_max = 11;
    selected.decoded_bytes_max = 7;
    try std.testing.expect(validBodyRefinement(original, selected));

    var forged = selected;
    forged.decoded_bytes_max += 1;
    try std.testing.expect(!validBodyRefinement(original, forged));
    forged = selected;
    forged.workspace_class += 1;
    try std.testing.expect(!validBodyRefinement(original, forged));
    forged = selected;
    forged.selected_decoder = 1;
    try std.testing.expect(!validBodyRefinement(original, forged));
}

const TestDefinition = struct {
    method: route.Method,
    path: []const u8,
    route_id: u16,
};
const test_definitions = [_]TestDefinition{
    .{ .method = .get, .path = "/items/:id", .route_id = 0 },
};
const TestRouter = route_graph.Graph(test_definitions, .{});
const test_body_plans = [_]application_body.Plan{application_body.plan(struct {
    fn handler(_: *u8) void {}
}.handler)};
const test_finite_output_plans = [_]application_finite_output.Plan{.{ .chunks = .{
    .encoded_bytes_max = 4096,
    .json_scratch_bytes_max = 128,
} }};

test "request plan survives route search workspace reuse before materialization" {
    const TestPlanner = Planner(TestRouter, &test_body_plans, &test_finite_output_plans);
    var route_workspace: TestRouter.SearchWorkspace = undefined;
    const made = TestPlanner.make(.{ .method = "GET", .path = "/items/42" }, &route_workspace);
    const moved = made;
    const missing = TestPlanner.make(.{ .method = "GET", .path = "/missing" }, &route_workspace);
    try std.testing.expectEqual(@as(u16, 0), moved.body.workspace_class);
    try std.testing.expectEqual(@as(u32, 4096), moved.finite_output.chunks.encoded_bytes_max);

    var destination: TestRouter.CaptureBuffer = undefined;
    const selection = try TestPlanner.materialize(&moved, &destination);
    const matched = switch (selection) {
        .selected => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u16, 0), matched.route_id);
    try std.testing.expectEqualStrings("42", matched.param("/items/42", "id").?);

    try std.testing.expect(
        try TestPlanner.materialize(&missing, &destination) == .not_found,
    );
    try std.testing.expect(missing.finite_output == .contiguous);

    const redirect = TestPlanner.make(
        .{ .method = "GET", .path = "/items/42/" },
        &route_workspace,
    );
    try std.testing.expect(
        try TestPlanner.materialize(&redirect, &destination) == .redirect,
    );
    try std.testing.expect(redirect.finite_output == .contiguous);
}

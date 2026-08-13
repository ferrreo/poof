const std = @import("std");
const cors = @import("../../cors.zig");
const application_body = @import("body.zig");
const application_assets = @import("assets.zig");
const application_finite_output = @import("finite_output.zig");
const application_plan = @import("plan.zig");
const application_response_output = @import("response_output.zig");
const application_runtime = @import("runtime.zig");
const application_types = @import("types.zig");
const request_cors = @import("../http1/request_cors.zig");
const response_cors_fields = @import("../http1/response_cors_fields.zig");
const route_graph = @import("../route_graph.zig");

pub fn Planner(
    comptime config: anytype,
    comptime Router: type,
    comptime body_plans: []const application_body.Plan,
    comptime finite_output_plans: []const application_finite_output.Plan,
    comptime Input: type,
    comptime logical: anytype,
) type {
    const CorsConfiguration = Configuration(config, logical);
    const BasePlanner = application_plan.ConfiguredPlanner(
        Router,
        body_plans,
        finite_output_plans,
        Input,
        CorsConfiguration.PlanExtension,
    );
    const Configured = Runtime(CorsConfiguration, BasePlanner, Input, Router.SearchWorkspace);
    return struct {
        pub const Plan = BasePlanner.Plan;
        pub const PreparedExtension = Configured.PreparedExtension;
        pub const cors_enabled = CorsConfiguration.enabled;
        pub const make = Configured.plan;
        pub const materialize = Configured.materialize;
        pub const refineBody = BasePlanner.refineBody;
    };
}

fn Configuration(comptime config: anytype, comptime logical: anytype) type {
    const Config = @TypeOf(config);
    const application_policy = if (@hasField(Config, "cors")) configured: {
        if (@TypeOf(config.cors) != cors.Policy) {
            @compileError("PLOOF-E3308 cors must be ploof.Cors.Policy");
        }
        break :configured cors.validate(config.cors);
    } else cors.disabled;
    const route_policies = application_assets.appendRepeated(
        config,
        policies(config.routes, application_policy),
        cors.disabled,
    );
    const route_field_line_limits = application_assets.appendRepeated(
        config,
        fieldLineLimits(config.routes, logical.field_line_bytes_max),
        logical.field_line_bytes_max,
    );
    const any_enabled = enabled: {
        if (application_policy.enabled()) break :enabled true;
        for (route_policies) |policy| {
            if (policy.enabled()) break :enabled true;
        }
        break :enabled false;
    };
    if (any_enabled) validateFieldLineLimits(
        logical.field_line_bytes_max,
        &route_policies,
        &route_field_line_limits,
    );

    return struct {
        pub const policy = application_policy;
        pub const routes = route_policies;
        pub const route_field_lines = route_field_line_limits;
        pub const application_field_line = logical.field_line_bytes_max;
        pub const enabled = any_enabled;
        pub const PlanExtension = if (enabled) struct {
            planned_preflight: bool,
        } else struct {};
        pub const PreparedExtension = if (enabled) struct {
            fields: response_cors_fields.Fields,
            preflight: ?response_cors_fields.PreflightStatus,
        } else struct {};
    };
}

fn validateFieldLineLimits(
    comptime application_limit: u32,
    comptime route_policies: []const cors.Policy,
    comptime route_limits: []const u32,
) void {
    if (application_limit < response_cors_fields.field_line_bytes_min) {
        @compileError("PLOOF-E3309 CORS application field line limit is below 77 bytes");
    }
    for (route_policies, route_limits) |policy, route_limit| {
        if (!policy.enabled()) continue;
        if (route_limit < response_cors_fields.field_line_bytes_min) {
            @compileError("PLOOF-E3310 CORS route field line limit is below 77 bytes");
        }
    }
}

fn Runtime(
    comptime ConfigurationType: type,
    comptime BasePlanner: type,
    comptime Input: type,
    comptime RouteSearchWorkspace: type,
) type {
    return struct {
        pub const PreparedExtension = ConfigurationType.PreparedExtension;
        pub const Materialized = struct {
            selection: route_graph.Selection,
            extension: PreparedExtension,
        };

        pub fn plan(input: Input, workspace: *RouteSearchWorkspace) BasePlanner.Plan {
            if (comptime !ConfigurationType.enabled) {
                return BasePlanner.make(input, selectionInput(input, input.method), .{}, workspace);
            }
            const request = requestForPlanning(input);
            const preflight = request.isPreflight(input.method);
            const selected_method = if (preflight)
                request.requested_method.get() orelse input.method
            else
                input.method;
            var result = BasePlanner.make(
                input,
                selectionInput(input, selected_method),
                .{ .planned_preflight = preflight },
                workspace,
            );
            if (preflight) {
                result.body = application_body.none_plan;
                result.finite_output = .contiguous;
                BasePlanner.reseal(&result);
            }
            return result;
        }

        pub fn materialize(
            request_plan: *const BasePlanner.Plan,
            captures: *BasePlanner.CaptureBuffer,
        ) BasePlanner.MaterializeError!Materialized {
            try BasePlanner.validate(request_plan, request_plan.input.method);
            if (comptime !ConfigurationType.enabled) return .{
                .selection = try BasePlanner.materializeValidated(
                    request_plan,
                    selectionInput(request_plan.input, request_plan.input.method),
                    captures,
                ),
                .extension = .{},
            };
            const request = request_cors.analyzeHeaders(request_plan.input.headers);
            const preflight = request.isPreflight(request_plan.input.method);
            if (preflight != request_plan.extension.planned_preflight) {
                return error.InvalidRoutePlan;
            }
            const selected_method = if (preflight)
                request.requested_method.get() orelse request_plan.input.method
            else
                request_plan.input.method;
            const selection = try BasePlanner.materializeValidated(
                request_plan,
                selectionInput(request_plan.input, selected_method),
                captures,
            );
            return .{
                .selection = selection,
                .extension = responseExtension(selection, request, preflight),
            };
        }

        fn responseExtension(
            selection: route_graph.Selection,
            request: request_cors.Request,
            preflight: bool,
        ) PreparedExtension {
            if (!preflight) return .{
                .fields = response_cors_fields.actualRequestBounded(
                    policyFor(selection),
                    request,
                    fieldLineLimitFor(selection),
                ),
                .preflight = null,
            };
            const route_selected = request.requested_method.get() != null and
                selection == .selected;
            const policy = if (route_selected)
                ConfigurationType.routes[selection.selected.route_id]
            else
                ConfigurationType.policy;
            const field_line_bytes_max = if (route_selected)
                @min(
                    ConfigurationType.application_field_line,
                    ConfigurationType.route_field_lines[
                        selection.selected.route_id
                    ],
                )
            else
                ConfigurationType.application_field_line;
            const decision = response_cors_fields.preflightRequestBounded(
                policy,
                request,
                route_selected,
                field_line_bytes_max,
            );
            return .{ .fields = decision.fields, .preflight = decision.status };
        }

        fn policyFor(selection: route_graph.Selection) cors.Policy {
            return switch (selection) {
                .selected => |selected| ConfigurationType.routes[selected.route_id],
                .redirect => |redirect| if (redirect.route_id) |route_id|
                    ConfigurationType.routes[route_id]
                else
                    ConfigurationType.policy,
                else => ConfigurationType.policy,
            };
        }

        fn fieldLineLimitFor(selection: route_graph.Selection) u32 {
            return switch (selection) {
                .selected => |selected| ConfigurationType.route_field_lines[selected.route_id],
                .redirect => |redirect| if (redirect.route_id) |route_id|
                    @min(
                        ConfigurationType.application_field_line,
                        ConfigurationType.route_field_lines[route_id],
                    )
                else
                    ConfigurationType.application_field_line,
                else => ConfigurationType.application_field_line,
            };
        }

        fn selectionInput(input: Input, method: []const u8) route_graph.SelectInput {
            return .{
                .method = method,
                .path = input.path,
                .terminal_slash_is_literal = application_runtime.terminalSlashIsLiteral(input),
            };
        }

        fn requestForPlanning(input: Input) request_cors.Request {
            if (!std.mem.eql(u8, input.method, "OPTIONS")) return .{};
            return request_cors.analyzeHeaders(input.headers);
        }
    };
}

pub fn Responder(
    comptime CorsPlanner: type,
    comptime Response: type,
    comptime ResponseOutput: type,
    comptime logical: anytype,
    comptime server_identity: anytype,
) type {
    return struct {
        pub fn run(
            extension: CorsPlanner.PreparedExtension,
            workspace: anytype,
            input: anytype,
            output: []u8,
            close_if_prepared: bool,
        ) application_response_output.Error!?application_types.Prepared {
            if (comptime CorsPlanner.cors_enabled) {
                workspace.cors_fields = extension.fields;
                const status = extension.preflight orelse return null;
                workspace.initialized_middleware = 0;
                var response_input = input.*;
                response_input.connection_close = input.connection_close or close_if_prepared;
                var value = switch (status) {
                    .no_content => Response.empty(&workspace.response, .no_content),
                    .forbidden => Response.empty(&workspace.response, .forbidden),
                };
                const prepared = try ResponseOutput.serialize(
                    logical,
                    &value,
                    workspace,
                    response_input,
                    workspace.cors_fields,
                    output,
                    workspace.response_gzip.get(),
                    server_identity,
                );
                workspace.pending = .{
                    .route = .{ .generated = {} },
                    .status = prepared.status,
                    .mapped_error = false,
                    .success_transport = .completed,
                };
                workspace.lifecycle = .pending;
                return prepared;
            }
            return null;
        }
    };
}

pub fn countRoutes(comptime descriptors: anytype) usize {
    var count: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => count += 1,
        .group => count += countRoutes(descriptor.children),
    };
    return count;
}

pub fn policies(
    comptime descriptors: anytype,
    comptime application_policy: cors.Policy,
) [countRoutes(descriptors)]cors.Policy {
    const root = cors.validate(application_policy);
    var result: [countRoutes(descriptors)]cors.Policy = undefined;
    var index: usize = 0;
    fillPolicies(descriptors, root, &result, &index);
    std.debug.assert(index == result.len);
    return result;
}

pub fn fieldLineLimits(
    comptime descriptors: anytype,
    comptime inherited: u32,
) [countRoutes(descriptors)]u32 {
    var result: [countRoutes(descriptors)]u32 = undefined;
    var index: usize = 0;
    fillFieldLineLimits(descriptors, inherited, &result, &index);
    std.debug.assert(index == result.len);
    return result;
}

fn fillFieldLineLimits(
    comptime descriptors: anytype,
    comptime inherited: u32,
    result: []u32,
    index: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => {
            result[index.*] = if (descriptor.response_head_limits) |selected|
                selected.field_line_bytes_max
            else
                inherited;
            index.* += 1;
        },
        .group => fillFieldLineLimits(descriptor.children, inherited, result, index),
    };
}

fn fillPolicies(
    comptime descriptors: anytype,
    comptime inherited: cors.Policy,
    result: []cors.Policy,
    index: *usize,
) void {
    inline for (descriptors) |descriptor| {
        const selected = cors.validate(descriptor.cors_policy orelse inherited);
        switch (descriptor.kind) {
            .route, .static_dir, .static_file => {
                result[index.*] = selected;
                index.* += 1;
            },
            .group => fillPolicies(descriptor.children, selected, result, index),
        }
    }
}

pub fn policyForRoute(
    comptime route_policies: []const cors.Policy,
    route_id: u16,
) cors.Policy {
    std.debug.assert(route_id < route_policies.len);
    return route_policies[route_id];
}

const route = @import("../../route.zig");

fn handler(_: u8) u8 {
    return 1;
}

test "CORS policy flattening uses nearest whole explicit scope" {
    const exact_policy = comptime cors.exact(&.{"https://app.example"}, .{
        .credentials = true,
        .max_age_seconds = 42,
    });
    const descriptors = comptime .{
        route.get("/root", handler),
        route.group("/v1", .{}, .{
            route.get("/inherited", handler),
            route.group("/nested", .{}, .{
                route.post("/also-inherited", handler),
                route.delete("/disabled", handler).withCors(cors.disabled),
            }),
        }).withCors(exact_policy),
        route.get("/application", handler),
    };
    const flattened = comptime policies(descriptors, cors.allow_any);

    try std.testing.expectEqual(@as(usize, 5), flattened.len);
    try std.testing.expect(flattened[0] == .allow_any);
    try std.testing.expect(flattened[1] == .allow_exact);
    try std.testing.expect(flattened[2] == .allow_exact);
    try std.testing.expect(flattened[2].sendsCredentials());
    try std.testing.expectEqual(@as(u32, 42), flattened[2].maxAgeSeconds());
    try std.testing.expect(flattened[3] == .disabled);
    try std.testing.expect(flattened[4] == .allow_any);
}

test "route policy lookup preserves closed route-id order" {
    const descriptors = comptime .{
        route.get("/one", handler),
        route.post("/two", handler).withCors(cors.allow_any_credentialed),
    };
    const flattened = comptime policies(descriptors, cors.disabled);
    try std.testing.expect(policyForRoute(&flattened, 0) == .disabled);
    try std.testing.expect(policyForRoute(&flattened, 1) == .allow_any_credentialed);
}

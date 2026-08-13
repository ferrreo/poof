const std = @import("std");
const application = @import("../../src/application.zig");
const request_body = @import("../../src/body.zig");
const cors = @import("../../src/cors.zig");
const http1_limits = @import("../../src/internal/http1/limits.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const State = struct { handler_calls: u8 = 0 };
const Context = application.Context(State, response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    context.state.handler_calls += 1;
    return context.empty(.no_content);
}

const App = application.Application(.{
    .State = State,
    .cors = cors.allow_any_credentialed,
    .routes = .{route.get("/resource", handler)},
});

const NetworkPathApp = application.Application(.{
    .State = State,
    .routes = .{
        route.get("//remove", handler),
        route.get("//add/", handler),
    },
});

const CaptureState = struct {
    body_saw_first: bool = false,
    handler_saw_first: bool = false,
    after_saw_first: bool = false,
};
const CaptureContext = application.Context(CaptureState, response.standard_head_limits);
const CaptureResponse = CaptureContext.ResponseType;

const CaptureMiddleware = struct {
    pub const State = void;

    pub fn body(
        _: CaptureMiddleware,
        context: *CaptureContext,
        _: *void,
        _: request_body.Bytes,
    ) ?CaptureResponse {
        context.state.body_saw_first = std.mem.eql(
            u8,
            context.request.param("id") orelse "",
            "first",
        );
        return null;
    }

    pub fn after(
        _: CaptureMiddleware,
        context: *const CaptureContext,
        _: *void,
        _: application.Outcome,
    ) void {
        context.state.after_saw_first = std.mem.eql(
            u8,
            context.request.param("id") orelse "",
            "first",
        );
    }
};

fn captureHandler(context: *CaptureContext, _: request_body.Bytes) CaptureResponse {
    context.state.handler_saw_first = std.mem.eql(
        u8,
        context.request.param("id") orelse "",
        "first",
    );
    return context.empty(.no_content);
}

const CaptureApp = application.Application(.{
    .State = CaptureState,
    .routes = .{route.configured(
        .post,
        "/items/:id",
        request_body.bytes(.{}, captureHandler),
        .{CaptureMiddleware{}},
        null,
    )},
});

const wire =
    "OPTIONS /resource HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Origin: https://first.example\r\n" ++
    "Access-Control-Request-Method: GET\r\n" ++
    "Access-Control-Request-Headers: X-First, X-Second\r\n" ++
    "\r\n";

test "planned prepare owns routing and CORS input" {
    const Decoder = request_head.Decoder(http1_limits.standard_request_head_limits);
    var decoder = Decoder.init();
    switch (decoder.feed(wire).state) {
        .ready => {},
        .need_more, .rejected => return error.TestUnexpectedResult,
    }
    var input = application.Input{
        .method = "OPTIONS",
        .path = "/resource",
        .raw_target = "/resource",
        .raw_path = "/resource",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        .headers = .{ .bytes = decoder.bytes(), .fields = decoder.fields() },
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(input, &route_workspace);

    input.method = "POST";
    input.path = "/missing";
    input.raw_target = "/missing";
    input.raw_path = "/missing";
    input.headers = .{};

    var state = State{};
    var workspace = App.Workspace{};
    var output: [1024]u8 = undefined;
    const result = try App.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &plan,
        .{},
    );
    const prepared = switch (result) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(response.Status.no_content, prepared.status);
    try expectContains(prepared.bytes, "access-control-allow-origin: https://first.example\r\n");
    try expectContains(prepared.bytes, "access-control-allow-methods: GET\r\n");
    try expectContains(
        prepared.bytes,
        "access-control-allow-headers: X-First, X-Second\r\n",
    );
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    _ = try App.complete(&workspace);
}

test "failed preflight serialization leaves workspace reusable" {
    const Decoder = request_head.Decoder(http1_limits.standard_request_head_limits);
    var decoder = Decoder.init();
    switch (decoder.feed(wire).state) {
        .ready => {},
        .need_more, .rejected => return error.TestUnexpectedResult,
    }
    const input = application.Input{
        .method = "OPTIONS",
        .path = "/resource",
        .raw_target = "/resource",
        .raw_path = "/resource",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        .headers = .{ .bytes = decoder.bytes(), .fields = decoder.fields() },
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    const plan = App.plan(input, &route_workspace);
    var state = State{};
    var workspace = App.Workspace{};
    var tiny_output: [1]u8 = undefined;

    try std.testing.expectError(
        error.OutputTooSmall,
        App.prepareHeadPlanned(&state, &workspace, &tiny_output, &plan, .{}),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);

    var output: [1024]u8 = undefined;
    const retried = try App.prepareHeadPlanned(&state, &workspace, &output, &plan, .{});
    const prepared = switch (retried) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(response.Status.no_content, prepared.status);
    _ = try App.complete(&workspace);
}

test "invalid planned path fails before lifecycle mutation" {
    const input = application.Input{
        .method = "GET",
        .path = "/resource",
        .raw_target = "/resource",
        .raw_path = "/resource",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    const valid = App.plan(input, &route_workspace);
    var forged = valid;
    forged.input.path = "/";
    forged.input.raw_target = "/";
    forged.input.raw_path = "/";

    var state = State{};
    var workspace = App.Workspace{};
    var output: [1024]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRoutePlan,
        App.prepareHeadPlanned(&state, &workspace, &output, &forged, .{}),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);

    const result = try App.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &valid,
        .{},
    );
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqual(@as(u8, 1), state.handler_calls);
    _ = try App.complete(&workspace);
}

test "planned POST method cannot change before protected request phases" {
    var route_workspace: CaptureApp.RouteSearchWorkspace = undefined;
    var plan = CaptureApp.plan(captureInput("/items/first"), &route_workspace);
    plan.input.method = "GET";
    var state = CaptureState{};
    var workspace = CaptureApp.Workspace{};
    var output: [1024]u8 = undefined;

    try std.testing.expectError(
        error.InvalidRoutePlan,
        CaptureApp.prepareHeadPlanned(&state, &workspace, &output, &plan, .{}),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);
    try std.testing.expect(!state.body_saw_first);
    try std.testing.expect(!state.handler_saw_first);
    try std.testing.expect(!state.after_saw_first);
}

test "planned CORS configuration rejects stale preflight and route selection" {
    const Decoder = request_head.Decoder(http1_limits.standard_request_head_limits);
    var decoder = Decoder.init();
    switch (decoder.feed(wire).state) {
        .ready => {},
        .need_more, .rejected => return error.TestUnexpectedResult,
    }
    const input = application.Input{
        .method = "OPTIONS",
        .path = "/resource",
        .raw_target = "/resource",
        .raw_path = "/resource",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        .headers = .{ .bytes = decoder.bytes(), .fields = decoder.fields() },
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    const valid = App.plan(input, &route_workspace);
    var stale_preflight = valid;
    stale_preflight.extension.planned_preflight = false;
    try expectInvalidPlan(&stale_preflight);

    var stale_selection = valid;
    stale_selection.selection = .not_found;
    try expectInvalidPlan(&stale_selection);
}

test "plan validation precedes dereferencing borrowed request headers" {
    const input = application.Input{
        .method = "GET",
        .path = "/resource",
        .raw_target = "/resource",
        .raw_path = "/resource",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(input, &route_workspace);
    const invalid_pointer: [*]const request_head.Field = @ptrFromInt(
        @alignOf(request_head.Field),
    );
    plan.input.headers.fields = invalid_pointer[0..1];
    try expectInvalidPlan(&plan);
}

test "body refinement rejects route-plan changes and undeclared limits" {
    var route_workspace: CaptureApp.RouteSearchWorkspace = undefined;
    const valid = CaptureApp.plan(captureInput("/items/first"), &route_workspace);
    var forged_body = valid.body;
    forged_body.decoded_bytes_max += 1;
    var plan = valid;
    try std.testing.expectError(
        error.InvalidRoutePlan,
        CaptureApp.__refinePlanBody(&plan, forged_body),
    );

    var forged_plan = valid;
    forged_plan.input.method = "GET";
    try std.testing.expectError(
        error.InvalidRoutePlan,
        CaptureApp.__refinePlanBody(&forged_plan, forged_plan.body),
    );
    try CaptureApp.__refinePlanBody(&plan, plan.body);

    var state = CaptureState{};
    var workspace = CaptureApp.Workspace{};
    var output: [1024]u8 = undefined;
    const prepared = try CaptureApp.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &plan,
        .{},
    );
    try std.testing.expect(prepared == .receive_body);
    _ = try CaptureApp.abort(&workspace);
}

test "application slash redirects remain same-origin for repeated leading slashes" {
    const cases = .{
        .{ "//remove/", "x=1", "/%2Fremove?x=1" },
        .{ "//add", "x=1", "/%2Fadd/?x=1" },
    };
    inline for (cases) |case| {
        const raw_target = case[0] ++ "?" ++ case[1];
        const input = application.Input{
            .method = "GET",
            .path = case[0],
            .raw_target = raw_target,
            .raw_path = case[0],
            .raw_query = case[1],
            .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        };
        var route_workspace: NetworkPathApp.RouteSearchWorkspace = undefined;
        const plan = NetworkPathApp.plan(input, &route_workspace);
        var state = State{};
        var workspace = NetworkPathApp.Workspace{};
        var output: [1024]u8 = undefined;
        const result = try NetworkPathApp.prepareHeadPlanned(
            &state,
            &workspace,
            &output,
            &plan,
            .{},
        );
        const prepared = switch (result) {
            .prepared => |value| value,
            .receive_body => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(response.Status.moved_permanently, prepared.status);
        var expected: [64]u8 = undefined;
        const location = try std.fmt.bufPrint(&expected, "location: {s}\r\n", .{case[2]});
        try expectContains(prepared.bytes, location);
        try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
        _ = try NetworkPathApp.complete(&workspace);
    }
}

test "busy prepare cannot overwrite captures retained by pending request" {
    var route_workspace: CaptureApp.RouteSearchWorkspace = undefined;
    const first_plan = CaptureApp.plan(captureInput("/items/first"), &route_workspace);
    const evil_plan = CaptureApp.plan(captureInput("/items/evil"), &route_workspace);
    var state = CaptureState{};
    var workspace = CaptureApp.Workspace{};
    var output: [1024]u8 = undefined;

    const head = try CaptureApp.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &first_plan,
        .{},
    );
    try std.testing.expect(head == .receive_body);
    try std.testing.expectError(
        error.RequestAlreadyPending,
        CaptureApp.prepareHeadPlanned(&state, &workspace, &output, &evil_plan, .{}),
    );

    const chunks = [_]request_body.Chunk{request_body.Chunk.init("body")};
    const decoded = try request_body.Bytes.init(&chunks);
    _ = try CaptureApp.prepareBody(&workspace, .{ .bytes = decoded }, .{}, &output);
    try std.testing.expect(state.body_saw_first);
    try std.testing.expect(state.handler_saw_first);
    _ = try CaptureApp.complete(&workspace);
    try std.testing.expect(state.after_saw_first);
}

fn captureInput(path: []const u8) application.Input {
    return .{
        .method = "POST",
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

fn expectInvalidPlan(plan: *const App.Plan) !void {
    var state = State{};
    var workspace = App.Workspace{};
    var output: [1024]u8 = undefined;
    try std.testing.expectError(
        error.InvalidRoutePlan,
        App.prepareHeadPlanned(&state, &workspace, &output, plan, .{}),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
}

fn expectContains(bytes: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

const std = @import("std");
const application = @import("../../src/application.zig");
const application_context = @import("../../src/application/context.zig");
const application_response_output = @import("../../src/internal/application/response_output.zig");
const request_accept_encoding = @import("../../src/internal/http1/request_accept_encoding.zig");
const response_module = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const limits = response_module.standard_head_limits;

fn input(preferences: request_accept_encoding.Preferences) application.Input {
    return .{
        .method = "GET",
        .path = "/",
        .raw_target = "/",
        .raw_path = "/",
        .date = fixed_date,
        .accept_encoding = preferences,
    };
}

const DisabledState = struct {};
const DisabledContext = application.Context(DisabledState, limits);

fn disabledHandler(context: *DisabledContext) DisabledContext.ResponseType {
    return context.textStatic(.ok, "plain");
}

const DisabledApplication = application.Application(.{
    .State = DisabledState,
    .routes = .{route.get("/", disabledHandler)},
});

const EnabledBareApplication = application.Application(.{
    .State = DisabledState,
    .routes = .{route.get("/", disabledHandler)},
    .response_gzip = application.ResponseGzip{},
});

test "response gzip defaults and disabled application stay zero sized" {
    const options = application.ResponseGzip{};
    const DisabledOutput = application_response_output.Configured(false, limits, options);
    try std.testing.expectEqual(@as(u64, 1024), options.minimum_bytes);
    try std.testing.expectEqual(application.ResponseGzip.Level.fastest, options.level);
    try std.testing.expect(!DisabledApplication.response_gzip_enabled);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledOutput.RequestBinding));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledApplication.ResponseGzipWorkspace));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledOutput.Binding));
    try std.testing.expectEqual(
        @sizeOf(?*u8),
        @sizeOf(EnabledBareApplication.Workspace) - @sizeOf(DisabledApplication.Workspace),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        DisabledApplication.response_gzip_framework_bytes_required,
    );
}

test "disabled application preserves exact identity bytes" {
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 5\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "plain";
    var state = DisabledState{};
    var workspace = DisabledApplication.Workspace{};
    var route_workspace = DisabledApplication.RouteSearchWorkspace{};
    var output: [expected.len]u8 = undefined;
    const prepared = try DisabledApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(.{}),
        &output,
    );
    try std.testing.expectEqualStrings(expected, prepared.bytes);
    try std.testing.expectEqual(
        application.CodingOutcome.identity_disabled,
        prepared.coding_outcome,
    );
    try std.testing.expect(prepared.transmission == .finite);
    _ = try DisabledApplication.complete(&workspace);
}

const payload = ("response middleware payload " ** 24) ++ "done";

const GzipState = struct {
    events: [4]u8 = undefined,
    events_len: usize = 0,
    after_status: ?response_module.Status = null,
    after_calls: u8 = 0,

    fn mark(state: *@This(), event: u8) void {
        state.events[state.events_len] = event;
        state.events_len += 1;
    }

    fn reset(state: *@This()) void {
        state.events_len = 0;
        state.after_status = null;
        state.after_calls = 0;
    }
};

const GzipContext = application.Context(GzipState, limits);
const GzipResponse = GzipContext.ResponseType;

const Transform = struct {
    pub const State = void;

    pub fn responsePhase(
        _: @This(),
        context: *GzipContext,
        _: *State,
        value: *GzipResponse,
    ) void {
        context.state.mark('R');
        value.setBodyStatic(payload, response_module.media.text) catch unreachable;
    }

    pub const response = responsePhase;

    pub fn after(
        _: @This(),
        context: *const GzipContext,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.mark('A');
        context.state.after_status = outcome.status;
        context.state.after_calls += 1;
    }
};

fn gzipHandler(context: *GzipContext) GzipResponse {
    context.state.mark('H');
    return context.textStatic(.ok, "handler");
}

const GzipApplication = application.Application(.{
    .State = GzipState,
    .middleware = .{Transform{}},
    .routes = .{route.get("/", gzipHandler)},
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0, .level = .fastest },
});

test "response middleware runs before gzip and after waits for completion" {
    var state = GzipState{};
    var workspace = GzipApplication.Workspace{};
    var gzip_workspace: GzipApplication.ResponseGzipWorkspace = undefined;
    var output: [limits.head_bytes_max + payload.len * 2]u8 = undefined;
    const request_input = input(.{ .gzip = 1000, .identity = 1000 });
    var route_workspace = GzipApplication.RouteSearchWorkspace{};
    var request_plan = GzipApplication.plan(request_input, &route_workspace);
    const head_result = try GzipApplication.__prepareHeadPlannedWithResponseGzip(
        &state,
        &workspace,
        &.{},
        &output,
        &request_plan,
        .{},
        &gzip_workspace,
    );
    const prepared = switch (head_result) {
        .prepared => |value| value,
        .receive_body => unreachable,
    };
    try std.testing.expect(GzipApplication.response_gzip_enabled);
    try std.testing.expect(@sizeOf(GzipApplication.ResponseGzipWorkspace) > 0);
    try std.testing.expect(GzipApplication.response_gzip_framework_bytes_required > 0);
    try std.testing.expectEqual(application.CodingOutcome.gzip, prepared.coding_outcome);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prepared.bytes,
        "content-encoding: gzip\r\n",
    ) != null);
    try std.testing.expectEqualStrings("HR", state.events[0..state.events_len]);
    _ = try GzipApplication.complete(&workspace);
    try std.testing.expectEqualStrings("HRA", state.events[0..state.events_len]);
    try std.testing.expectEqual(response_module.Status.ok, state.after_status.?);
}

test "framework 406 and 503 statuses reach after" {
    var state = GzipState{};
    var workspace = GzipApplication.Workspace{};
    var route_workspace = GzipApplication.RouteSearchWorkspace{};
    var ample: [limits.head_bytes_max + payload.len * 2]u8 = undefined;
    const rejected = try GzipApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(.{ .gzip = 0, .identity = 0 }),
        &ample,
    );
    try std.testing.expectEqual(response_module.Status.not_acceptable, rejected.status);
    _ = try GzipApplication.complete(&workspace);
    try std.testing.expectEqual(response_module.Status.not_acceptable, state.after_status.?);

    state.reset();
    var constrained: [512]u8 = undefined;
    const unavailable = try GzipApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(.{ .gzip = 1000, .identity = 0 }),
        &constrained,
    );
    try std.testing.expectEqual(response_module.Status.service_unavailable, unavailable.status);
    _ = try GzipApplication.complete(&workspace);
    try std.testing.expectEqual(response_module.Status.service_unavailable, state.after_status.?);
}

test "serialization error runs after once with no committed status" {
    var state = GzipState{};
    var workspace = GzipApplication.Workspace{};
    var route_workspace = GzipApplication.RouteSearchWorkspace{};
    var output: [8]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, GzipApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(.{ .gzip = 0, .identity = 1000 }),
        &output,
    ));
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(@as(?response_module.Status, null), state.after_status);
    try std.testing.expectEqualStrings("HRA", state.events[0..state.events_len]);
}

test "enabled output falls back safely without compressor workspace" {
    const Output = application_response_output.Configured(
        true,
        limits,
        application.ResponseGzip{ .minimum_bytes = 0 },
    );
    var response_workspace = response_module.Workspace(limits){};
    const value = response_module.Response(limits).textStatic(&response_workspace, .ok, payload);
    var unused: u8 = 0;
    const no_cors = struct {}{};
    var output: [limits.head_bytes_max + payload.len * 2]u8 = undefined;

    const identity = try Output.serialize(
        limits,
        &value,
        &unused,
        input(.{ .gzip = 1000, .identity = 1000 }),
        no_cors,
        &output,
        null,
        null,
    );
    try std.testing.expectEqual(
        application.CodingOutcome.identity_capacity_fallback,
        identity.coding_outcome,
    );

    const unavailable = try Output.serialize(
        limits,
        &value,
        &unused,
        input(.{ .gzip = 1000, .identity = 0 }),
        no_cors,
        &output,
        null,
        null,
    );
    try std.testing.expectEqual(response_module.Status.service_unavailable, unavailable.status);
    try std.testing.expectEqual(
        application.CodingOutcome.capacity_unavailable,
        unavailable.coding_outcome,
    );
}

const DynamicContext = application.Context(DisabledState, limits);

fn dynamicHandler(
    context: *DynamicContext,
) application_context.ResponseBodyError!DynamicContext.ResponseType {
    var local: [16]u8 = undefined;
    const rendered = std.fmt.bufPrint(&local, "request-{d}", .{@as(u8, 7)}) catch unreachable;
    const result = try context.text(.ok, rendered);
    @memset(&local, 'x');
    return result;
}

const DynamicApplication = application.Application(.{
    .State = DisabledState,
    .Error = application_context.ResponseBodyError,
    .response_body_bytes_max = 16,
    .routes = .{route.get("/", dynamicHandler)},
});

test "application binds dynamic response storage through serialization" {
    var state = DisabledState{};
    var workspace = DynamicApplication.Workspace{};
    var route_workspace = DynamicApplication.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;
    const prepared = try DynamicApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(.{}),
        &output,
    );
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "request-7"));
    _ = try DynamicApplication.complete(&workspace);
}

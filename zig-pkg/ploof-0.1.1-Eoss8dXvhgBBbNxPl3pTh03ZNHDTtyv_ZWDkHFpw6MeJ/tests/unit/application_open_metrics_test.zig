const std = @import("std");

const application = @import("../../src/application.zig");
const open_metrics = @import("../../src/open_metrics.zig");
const response = @import("../../src/response.zig");

const State = struct {
    authorized: bool = true,
    head_calls: u32 = 0,
    body_calls: u32 = 0,
    response_calls: u32 = 0,
    after_calls: u32 = 0,
    after_status: ?response.Status = null,
};
const Context = application.Context(State, response.standard_head_limits);

const Observe = struct {
    pub const State = void;

    pub fn head(_: Observe, context: *Context, _: *void) ?Context.ResponseType {
        context.state.head_calls += 1;
        if (!context.state.authorized) return context.empty(.unauthorized);
        return null;
    }

    pub fn body(
        _: Observe,
        context: *Context,
        _: *void,
        _: application.Bodyless,
    ) ?Context.ResponseType {
        context.state.body_calls += 1;
        return null;
    }

    pub fn responsePhase(
        _: Observe,
        context: *Context,
        _: *void,
        _: *Context.ResponseType,
    ) void {
        context.state.response_calls += 1;
    }

    pub const response = responsePhase;

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.after_status = outcome.status;
    }
};

const App = application.Application(.{
    .State = State,
    .routes = .{open_metrics.configured("/metrics", .{Observe{}}, null)},
});

test "OpenMetrics route defers every response byte then resumes ordinary phases" {
    var state = State{};
    var workspace: App.Workspace = .{};
    var route_workspace: App.RouteSearchWorkspace = .{};
    var output: [1024]u8 = [_]u8{0xa5} ** 1024;
    const head = try App.prepareHead(&state, &workspace, &route_workspace, input(), &output);
    const deferred = switch (head) {
        .deferred_metrics => |value| value,
        .prepared, .receive_body => return error.ExpectedDeferredMetrics,
    };
    try std.testing.expectEqual(@as(u32, 1), state.head_calls);
    try std.testing.expectEqual(@as(u32, 1), state.body_calls);
    try std.testing.expectEqual(@as(u32, 0), state.response_calls);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);

    const metrics_body = "# TYPE fixture counter\nfixture 1\n# EOF\n";
    const prepared = try App.__resumeMetrics(
        &workspace,
        deferred,
        .{ .success = metrics_body },
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expectEqual(@as(u32, 1), state.response_calls);
    const borrowed = switch (prepared.source) {
        .borrowed_static => |value| value,
        else => return error.ExpectedBorrowedMetrics,
    };
    try std.testing.expectEqualStrings(metrics_body, borrowed.body);
    try expectContains(borrowed.head, "application/openmetrics-text");
    _ = try App.complete(&workspace);
    try std.testing.expectEqual(@as(u32, 1), state.after_calls);
    try std.testing.expectEqual(response.Status.ok, state.after_status.?);
}

test "OpenMetrics unavailable and abort paths preserve middleware lifecycle" {
    var state = State{};
    var workspace: App.Workspace = .{};
    var route_workspace: App.RouteSearchWorkspace = .{};
    var output: [1024]u8 = undefined;
    const first = try App.prepareHead(&state, &workspace, &route_workspace, input(), &output);
    const deferred = first.deferred_metrics;
    const prepared = try App.__resumeMetrics(
        &workspace,
        deferred,
        .unavailable,
        &output,
    );
    try std.testing.expectEqual(response.Status.service_unavailable, prepared.status);
    try expectContains(prepared.source.borrowed_static.body, "metrics unavailable");
    _ = try App.complete(&workspace);
    const second = (try App.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input(),
        &output,
    )).deferred_metrics;
    _ = second;
    const outcome = try App.__abortWithTransport(&workspace, .peer_aborted);
    try std.testing.expectEqual(application.TransportOutcome.peer_aborted, outcome.transport);
    try std.testing.expectEqual(@as(u32, 2), state.after_calls);
}

test "OpenMetrics authorization short circuit never defers" {
    var state = State{ .authorized = false };
    var workspace: App.Workspace = .{};
    var route_workspace: App.RouteSearchWorkspace = .{};
    var output: [1024]u8 = undefined;
    const result = try App.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input(),
        &output,
    );
    const prepared = switch (result) {
        .prepared => |value| value,
        .receive_body, .deferred_metrics => return error.ExpectedAuthorizationResponse,
    };
    try std.testing.expectEqual(response.Status.unauthorized, prepared.status);
    try std.testing.expectEqual(@as(u32, 0), state.body_calls);
    try std.testing.expectEqual(@as(u32, 1), state.response_calls);
    _ = try App.complete(&workspace);
}

fn input() application.Input {
    return .{
        .method = "GET",
        .path = "/metrics",
        .raw_target = "/metrics",
        .raw_path = "/metrics",
        .date = "Thu, 16 Jul 2026 12:00:00 GMT",
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

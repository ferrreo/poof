const std = @import("std");
const builtin = @import("builtin");
const route = @import("../../../src/route.zig");

pub const BehaviorDefinition = struct {
    method: route.Method,
    path: []const u8,
    route_id: u16,
};

pub const behavior_definitions = [_]BehaviorDefinition{
    .{ .method = .get, .path = "/users/*rest", .route_id = 0 },
    .{ .method = .get, .path = "/users/:id", .route_id = 1 },
    .{ .method = .get, .path = "/users/new", .route_id = 2 },
    .{ .method = .post, .path = "/users/:id", .route_id = 3 },
    .{ .method = .get, .path = "/explicit", .route_id = 4 },
    .{ .method = .head, .path = "/explicit", .route_id = 5 },
    .{ .method = .get, .path = "/slash/", .route_id = 6 },
    .{ .method = .get, .path = "/Case/./x//", .route_id = 7 },
    .{ .method = .delete, .path = "/only-delete", .route_id = 8 },
    .{ .method = .get, .path = "/:first/:second", .route_id = 9 },
    .{ .method = .post, .path = "/literal/:x/end", .route_id = 10 },
    .{ .method = .post, .path = "/:a/:b/end", .route_id = 11 },
    .{ .method = .get, .path = "/assets/*path", .route_id = 12 },
};

pub const reversed_definitions = reverseDefinitions(behavior_definitions);
pub const maximum_capture_pattern = maximumCapturePattern();
pub const maximum_depth_pattern = maximumDepthPattern();

fn reverseDefinitions(comptime definitions: anytype) @TypeOf(definitions) {
    var reversed: @TypeOf(definitions) = undefined;
    for (definitions, 0..) |definition, index| {
        reversed[definitions.len - index - 1] = definition;
    }
    return reversed;
}

fn maximumCapturePattern() [route.captures_hard_max * 7]u8 {
    @setEvalBranchQuota(10_000);
    var pattern: [route.captures_hard_max * 7]u8 = undefined;
    for (0..route.captures_hard_max) |index| {
        const start = index * 7;
        pattern[start] = '/';
        pattern[start + 1] = ':';
        pattern[start + 2] = 'p';
        pattern[start + 3] = '0' + @as(u8, @intCast(index / 1000));
        pattern[start + 4] = '0' + @as(u8, @intCast(index / 100 % 10));
        pattern[start + 5] = '0' + @as(u8, @intCast(index / 10 % 10));
        pattern[start + 6] = '0' + @as(u8, @intCast(index % 10));
    }
    return pattern;
}

fn maximumDepthPattern() [route.segments_hard_max * 2]u8 {
    @setEvalBranchQuota(20_000);
    var pattern: [route.segments_hard_max * 2]u8 = undefined;
    for (0..route.segments_hard_max) |index| {
        pattern[index * 2] = '/';
        pattern[index * 2 + 1] = 'a';
    }
    return pattern;
}

pub fn run(comptime Graph: type, patternIssue: anytype) !void {
    try patternValidation(patternIssue);
    try precedenceAndCaptures(Graph);
    try methodsAndAllow(Graph);
    try redirectsAndExactPaths(Graph);
    try materializeRejectsInvalidRedirectRoute(Graph);
    try metadata(Graph);
}

pub fn plannedCapturesSurviveReuse(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    const first = Graph.plan(.{ .method = "GET", .path = "/users/42" }, &workspace);
    _ = Graph.plan(.{ .method = "GET", .path = "/users/a/b" }, &workspace);
    var captures: Graph.CaptureBuffer = undefined;
    const selection = try Graph.materialize(first, "/users/42", &captures);
    const matched = switch (selection) {
        .selected => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("42", matched.param("/users/42", "id").?);
}

pub fn materializeRejectsMismatchedPaths(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    const planned = Graph.plan(.{
        .method = "POST",
        .path = "/literal/value/end",
    }, &workspace);
    var captures: Graph.CaptureBuffer = undefined;
    const mismatches = [_][]const u8{
        "",
        "/x",
        "/different/value/end",
        "/literal//end",
        "/literal/value",
        "/literal/value/end/extra",
    };
    for (mismatches) |path| {
        try std.testing.expectError(
            error.InvalidRoutePlan,
            Graph.materialize(planned, path, &captures),
        );
    }
}

fn materializeRejectsInvalidRedirectRoute(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    var planned = Graph.plan(.{ .method = "GET", .path = "/slash" }, &workspace);
    if (planned != .redirect) return error.TestUnexpectedResult;
    planned.redirect.route_id = std.math.maxInt(u16);
    var captures: Graph.CaptureBuffer = undefined;
    try std.testing.expectError(
        error.InvalidRoutePlan,
        Graph.materialize(planned, "/slash", &captures),
    );
}

pub fn searchCountBound(comptime Graph: type, comptime Search: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    Search.TestAccess.beginVisitCount();
    const exact = Graph.plan(.{ .method = "HEAD", .path = "/users/x" }, &workspace);
    _ = Search.TestAccess.endVisitCount();
    try std.testing.expect(exact == .selected);
    try std.testing.expectEqual(@as(u64, 2), Search.TestAccess.searchCount());

    Search.TestAccess.beginVisitCount();
    const alternate_plan = Graph.plan(.{ .method = "HEAD", .path = "/slash" }, &workspace);
    _ = Search.TestAccess.endVisitCount();
    try std.testing.expect(alternate_plan == .redirect);
    try std.testing.expectEqual(@as(u64, 3), Search.TestAccess.searchCount());
    try std.testing.expectEqual(@as(u8, 3), Graph.select_searches_bound);
}

pub fn maximumDepthSmallStack(comptime Graph: type, comptime path: []const u8) !void {
    const Context = struct {
        workspace: *Graph.SearchWorkspace,
        selected: bool = false,

        fn run(context: *@This()) void {
            const planned = Graph.plan(.{ .method = "GET", .path = path }, context.workspace);
            context.selected = planned == .selected;
        }
    };
    var workspace: Graph.SearchWorkspace = undefined;
    var context = Context{ .workspace = &workspace };
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, Context.run, .{&context});
    thread.join();
    try std.testing.expect(context.selected);
    try std.testing.expect(Graph.search_workspace_bytes < 64 * 1024);
}

fn patternValidation(patternIssue: anytype) !void {
    const limits = route.GraphLimits{};
    try std.testing.expectEqual(.not_absolute, patternIssue("x", limits).?);
    try std.testing.expectEqual(.empty_capture_name, patternIssue("/:", limits).?);
    try std.testing.expectEqual(.empty_capture_name, patternIssue("/*", limits).?);
    try std.testing.expectEqual(.invalid_capture_name, patternIssue("/:0x", limits).?);
    try std.testing.expectEqual(.invalid_capture_name, patternIssue("/:a-b", limits).?);
    try std.testing.expectEqual(.nonterminal_catch_all, patternIssue("/*x/y", limits).?);
    try std.testing.expectEqual(.duplicate_capture_name, patternIssue("/:x/*x", limits).?);
    try std.testing.expect(patternIssue("/:x/*tail", limits) == null);
    try std.testing.expectEqual(.bytes_limit, patternIssue("/ab", .{
        .pattern_bytes_max = 2,
    }).?);
    try std.testing.expectEqual(.segments_limit, patternIssue("/a/b", .{
        .segments_max = 1,
    }).?);
    try std.testing.expectEqual(.captures_limit, patternIssue("/:a/:b", .{
        .captures_max = 1,
    }).?);
}

fn precedenceAndCaptures(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const literal = Graph.select(.{ .method = "GET", .path = "/users/new" }, &workspace, &captures);
    try expectRoute(literal, 2, false);

    const parameter = Graph.select(
        .{ .method = "GET", .path = "/users/42" },
        &workspace,
        &captures,
    );
    const parameter_match = try selected(parameter);
    try std.testing.expectEqual(@as(u16, 1), parameter_match.route_id);
    try std.testing.expectEqualStrings("42", parameter_match.param("/users/42", "id").?);
    try std.testing.expectEqual(.parameter, parameter_match.captures[0].kind);

    const catch_all = Graph.select(
        .{ .method = "GET", .path = "/users/a/b" },
        &workspace,
        &captures,
    );
    const catch_match = try selected(catch_all);
    try std.testing.expectEqual(@as(u16, 0), catch_match.route_id);
    try std.testing.expectEqualStrings("/a/b", catch_match.param("/users/a/b", "rest").?);
    try std.testing.expectEqual(.catch_all, catch_match.captures[0].kind);

    const two = Graph.select(
        .{ .method = "GET", .path = "/other/value" },
        &workspace,
        &captures,
    );
    const two_match = try selected(two);
    try std.testing.expectEqualStrings("other", two_match.param("/other/value", "first").?);
    try std.testing.expectEqualStrings("value", two_match.param("/other/value", "second").?);
}

fn methodsAndAllow(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const post = Graph.select(.{ .method = "POST", .path = "/users/x" }, &workspace, &captures);
    try expectRoute(post, 3, false);
    const fallback = Graph.select(.{ .method = "HEAD", .path = "/users/x" }, &workspace, &captures);
    try expectRoute(fallback, 1, true);
    const explicit = Graph.select(
        .{ .method = "HEAD", .path = "/explicit" },
        &workspace,
        &captures,
    );
    try expectRoute(explicit, 5, false);

    const disallowed = Graph.select(
        .{ .method = "PUT", .path = "/users/x" },
        &workspace,
        &captures,
    );
    const allow = switch (disallowed) {
        .method_not_allowed => |value| value,
        else => return error.ExpectedMethodNotAllowed,
    };
    try expectAllow(allow, "GET, HEAD, POST, OPTIONS");

    const options = Graph.select(
        .{ .method = "OPTIONS", .path = "/users/x" },
        &workspace,
        &captures,
    );
    try expectAllow(switch (options) {
        .options => |value| value,
        else => return error.ExpectedOptions,
    }, "GET, HEAD, POST, OPTIONS");
    const unknown = Graph.select(.{ .method = "TRACE", .path = "/users/x" }, &workspace, &captures);
    try std.testing.expect(unknown == .not_implemented);
    const missing = Graph.select(.{ .method = "GET", .path = "/missing" }, &workspace, &captures);
    try std.testing.expect(missing == .not_found);
}

fn redirectsAndExactPaths(comptime Graph: type) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const add = Graph.select(.{ .method = "GET", .path = "/slash" }, &workspace, &captures);
    try expectRedirect(add, 6, .moved_permanently, .add);
    const remove = Graph.select(.{ .method = "POST", .path = "/users/x/" }, &workspace, &captures);
    try expectRedirect(remove, 3, .temporary_redirect, .remove);
    const options = Graph.select(.{ .method = "OPTIONS", .path = "/slash" }, &workspace, &captures);
    try expectRedirect(options, null, .temporary_redirect, .add);
    const suppressed = Graph.select(.{
        .method = "GET",
        .path = "/explicit/",
        .terminal_slash_is_literal = false,
    }, &workspace, &captures);
    try std.testing.expect(suppressed == .not_found);
    const literal_terminal = Graph.select(
        .{ .method = "GET", .path = "/explicit/" },
        &workspace,
        &captures,
    );
    try expectRedirect(literal_terminal, 4, .moved_permanently, .remove);
    const exact = Graph.select(.{ .method = "GET", .path = "/Case/./x//" }, &workspace, &captures);
    try expectRoute(exact, 7, false);
    const wrong_case = Graph.select(
        .{ .method = "GET", .path = "/case/./x//" },
        &workspace,
        &captures,
    );
    try std.testing.expect(wrong_case == .not_found);
    const empty_tail = Graph.select(
        .{ .method = "GET", .path = "/assets/" },
        &workspace,
        &captures,
    );
    try expectRoute(empty_tail, 12, false);
}

fn metadata(comptime Graph: type) !void {
    try std.testing.expectEqual(@as(usize, 13), Graph.routes.len);
    try std.testing.expectEqual(@as(u16, 2), Graph.maximum_captures);
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const all = Graph.select(.{ .method = "OPTIONS", .path = "*" }, &workspace, &captures);
    const allow = switch (all) {
        .options => |value| value,
        else => return error.ExpectedOptions,
    };
    try expectAllow(allow, "GET, HEAD, POST, DELETE, OPTIONS");
}

fn selected(selection: anytype) !@TypeOf(selection.selected) {
    return switch (selection) {
        .selected => |match| match,
        else => error.ExpectedSelected,
    };
}

fn expectRoute(selection: anytype, route_id: u16, head_uses_get: bool) !void {
    const match = try selected(selection);
    try std.testing.expectEqual(route_id, match.route_id);
    try std.testing.expectEqual(head_uses_get, match.head_uses_get);
}

fn expectRedirect(
    selection: anytype,
    route_id: ?u16,
    status: anytype,
    change: anytype,
) !void {
    const redirect = switch (selection) {
        .redirect => |value| value,
        else => return error.ExpectedRedirect,
    };
    try std.testing.expectEqual(route_id, redirect.route_id);
    try std.testing.expectEqual(status, redirect.status);
    try std.testing.expectEqual(change, redirect.slash_change);
}

fn expectAllow(allow: anytype, expected: []const u8) !void {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try allow.write(&output));
    const before = output;
    try std.testing.expectError(error.NoSpace, allow.write(output[0 .. allow.wireLength() - 1]));
    try std.testing.expectEqualSlices(u8, &before, &output);
}

const route_graph = @import("../../../src/internal/route_graph.zig");
const route_graph_search = @import("../../../src/internal/route_graph/search.zig");
const route_graph_fuzz = @import("../../../fuzz/internal/route_graph_fuzz.zig");
const BehaviorGraph = route_graph.Graph(behavior_definitions, .{});
const BehaviorGraphReversed = route_graph.Graph(reversed_definitions, .{});
const MaximumCaptureGraph = route_graph.Graph([_]BehaviorDefinition{.{
    .method = .get,
    .path = &maximum_capture_pattern,
    .route_id = 0,
}}, .{
    .segments_max = route.captures_hard_max,
    .captures_max = route.captures_hard_max,
    .search_visits_max = route.captures_hard_max + 1,
});
const MaximumDepthGraph = route_graph.Graph([_]BehaviorDefinition{.{
    .method = .get,
    .path = &maximum_depth_pattern,
    .route_id = 0,
}}, .{
    .segments_max = route.segments_hard_max,
    .search_visits_max = route.segments_hard_max + 1,
});

test "route graph selection contract" {
    try run(BehaviorGraph, route_graph.patternIssue);
}

test "route graph bounded differential fuzz" {
    try route_graph_fuzz.run(BehaviorGraph, BehaviorGraphReversed);
}

test "route graph accepts hard maximum distinct captures" {
    try std.testing.expectEqual(route.captures_hard_max, MaximumCaptureGraph.maximum_captures);
}

test "planned captures survive route search workspace reuse" {
    try plannedCapturesSurviveReuse(BehaviorGraph);
}

test "planned route materialization rejects mismatched paths" {
    try materializeRejectsMismatchedPaths(BehaviorGraph);
}

test "HEAD fallback and slash alternate obey three-search select bound" {
    try searchCountBound(BehaviorGraph, route_graph_search);
}

test "maximum-depth route planning fits a 64 KiB child stack" {
    try maximumDepthSmallStack(MaximumDepthGraph, &maximum_depth_pattern);
}

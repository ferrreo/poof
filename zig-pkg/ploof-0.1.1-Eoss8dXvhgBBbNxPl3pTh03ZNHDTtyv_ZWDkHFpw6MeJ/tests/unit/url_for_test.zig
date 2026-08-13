const std = @import("std");
const application = @import("../../src/application.zig");
const cors = @import("../../src/cors.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const route_graph = @import("../../src/internal/route_graph.zig");
const target = @import("../../src/internal/http1/request_target.zig");
const url_for = @import("../../src/url_for.zig");

fn handler() void {}

const MountedState = struct {};
const MountedContext = application.Context(MountedState, response.standard_head_limits);
const mounted_route = route.get("/users/:user_id", mountedHandler);

fn mountedHandler(context: *MountedContext) MountedContext.ResponseType {
    return context.empty(.no_content);
}

const MountedApp = application.Application(.{
    .State = MountedState,
    .routes = .{
        route.get("/health", mountedHandler),
        route.group("/:tenant", .{}, .{
            route.group("/api/:version", .{}, .{
                mounted_route.withCors(cors.allow_any),
            }),
        }),
    },
});

test "urlFor builds a literal route without path or query values" {
    const descriptor = route.get("/health", handler);
    var output: [64]u8 = undefined;
    const built = try url_for.urlFor(descriptor, .{}, .{}, &output);
    try std.testing.expectEqualStrings("/health", built.bytes());
    _ = try built.validatedCopy();
}

test "urlFor encodes typed path values without changing route structure" {
    const Kind = enum { profile, settings };
    const Path = struct {
        id: u64,
        name: []const u8,
        active: bool,
        kind: Kind,
    };
    const descriptor = route.get("/users/:id/files/:name/:active/:kind", handler);
    var output: [256]u8 = undefined;
    const built = try url_for.urlFor(descriptor, Path{
        .id = 42,
        .name = "caf\xc3\xa9 ?",
        .active = true,
        .kind = .settings,
    }, .{}, &output);
    try std.testing.expectEqualStrings(
        "/users/42/files/caf%C3%A9%20%3F/true/settings",
        built.bytes(),
    );
}

test "urlFor encodes route literals as decoded router bytes" {
    const descriptor = route.get("/literal space/%/:value", handler);
    var output: [128]u8 = undefined;
    const built = try url_for.urlFor(descriptor, .{ .value = "ok" }, .{}, &output);
    try std.testing.expectEqualStrings("/literal%20space/%25/ok", built.bytes());
}

test "urlFor accepts comptime integer and float literals without runtime formatting state" {
    const descriptor = route.get("/items/:id", handler);
    var output: [128]u8 = undefined;
    const built = try url_for.urlFor(
        descriptor,
        .{ .id = 42 },
        .{ .page = 3, .ratio = 1.5 },
        &output,
    );
    try std.testing.expectEqualStrings("/items/42?page=3&ratio=1.5", built.bytes());
}

test "urlFor writes query fields and repetitions in declared order" {
    const Choice = enum { newest, oldest };
    const Query = struct {
        search: []const u8,
        page: u16,
        enabled: bool,
        ratio: f64,
        tags: []const []const u8,
        exact: [2]i8,
        absent: ?u8 = null,
        present: ?u8 = null,
        choice: Choice,

        pub const ploof_flat_fields = .{ .search = "search[]" };
    };
    const tags = [_][]const u8{ "zig lang", "a&b" };
    const descriptor = route.get("/find", handler);
    var output: [512]u8 = undefined;
    const built = try url_for.urlFor(descriptor, .{}, Query{
        .search = "caf\xc3\xa9",
        .page = 7,
        .enabled = false,
        .ratio = 1.25,
        .tags = &tags,
        .exact = .{ -1, 2 },
        .present = 9,
        .choice = .newest,
    }, &output);
    try std.testing.expectEqualStrings(
        "/find?search%5B%5D=caf%C3%A9&page=7&enabled=false&ratio=1.25" ++
            "&tags=zig%20lang&tags=a%26b&exact=-1&exact=2&present=9&choice=newest",
        built.bytes(),
    );
}

test "urlFor output selects its descriptor and preserves typed captures" {
    const descriptor = route.get("/users/:id/:name", handler);
    const Graph = route_graph.Graph(&.{.{
        .method = descriptor.method,
        .path = descriptor.path,
        .route_id = 0,
    }}, .{});
    var encoded: [128]u8 = undefined;
    const built = try url_for.urlFor(
        descriptor,
        .{ .id = @as(u16, 42), .name = "caf\xc3\xa9" },
        .{},
        &encoded,
    );
    var decoded: [128]u8 = undefined;
    const parsed = target.parse("GET", built.bytes(), &decoded);
    const ready = switch (parsed) {
        .ready => |value| value,
        .rejected => return error.UnexpectedTargetRejection,
    };
    const path = switch (ready) {
        .origin => |origin| origin.decoded_path,
        else => return error.UnexpectedTargetForm,
    };
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const selected = Graph.select(.{ .method = "GET", .path = path }, &workspace, &captures);
    const matched = switch (selected) {
        .selected => |value| value,
        else => return error.UnexpectedRouteSelection,
    };
    try std.testing.expectEqualStrings("42", matched.param(path, "id").?);
    try std.testing.expectEqualStrings("caf\xc3\xa9", matched.param(path, "name").?);
}

test "urlFor uses nested composed target with prefix and child parameters" {
    const composed = comptime MountedApp.routeTarget(mounted_route);
    try std.testing.expectEqual(route.Method.get, composed.method());
    try std.testing.expectEqual(@as(u16, 1), composed.routeId());
    try std.testing.expectEqualStrings(
        "/:tenant/api/:version/users/:user_id",
        composed.path(),
    );
    try std.testing.expect(composed.matches(mounted_route));
    try std.testing.expect(composed.matches(mounted_route.withCors(cors.allow_any)));
    const altered = comptime blk: {
        var copy = mounted_route;
        copy.path = "/other/:user_id";
        break :blk copy;
    };
    try std.testing.expect(!composed.matches(altered));

    var encoded: [256]u8 = undefined;
    const built = try url_for.urlFor(composed, .{
        .tenant = "caf\xc3\xa9 shop",
        .version = @as(u8, 2),
        .user_id = @as(u64, 42),
    }, .{}, &encoded);
    try expectMountedSelection(composed, built.bytes());
}

fn expectMountedSelection(composed: *const route.RouteTarget, encoded: []const u8) !void {
    const Graph = route_graph.Graph(MountedApp.route_definitions, .{});
    var decoded: [256]u8 = undefined;
    const parsed = target.parse(composed.method().wire(), encoded, &decoded);
    const ready = switch (parsed) {
        .ready => |value| value,
        .rejected => return error.UnexpectedTargetRejection,
    };
    const path = switch (ready) {
        .origin => |origin| origin.decoded_path,
        else => return error.UnexpectedTargetForm,
    };
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const selected = Graph.select(
        .{ .method = composed.method().wire(), .path = path },
        &workspace,
        &captures,
    );
    const matched = switch (selected) {
        .selected => |value| value,
        else => return error.UnexpectedRouteSelection,
    };
    try std.testing.expectEqual(composed.routeId(), matched.route_id);
    try std.testing.expectEqualStrings("caf\xc3\xa9 shop", matched.param(path, "tenant").?);
    try std.testing.expectEqualStrings("2", matched.param(path, "version").?);
    try std.testing.expectEqualStrings("42", matched.param(path, "user_id").?);
}

test "urlFor rejects path bytes that browsers or routing could reinterpret" {
    const descriptor = route.get("/users/:id", handler);
    const cases = [_][]const u8{ "", "/", "a/b", "\\", ".", "..", "\xff" };
    var output: [128]u8 = undefined;
    for (cases) |value| {
        try std.testing.expectError(
            error.InvalidPathParameter,
            url_for.urlFor(descriptor, .{ .id = value }, .{}, &output),
        );
    }
}

test "urlFor closes capacity byte query count and scalar failures" {
    const descriptor = route.get("/items/:id", handler);
    var tiny: [7]u8 = undefined;
    try std.testing.expectError(
        error.NoSpace,
        url_for.urlFor(descriptor, .{ .id = @as(u8, 1) }, .{}, &tiny),
    );

    var output: [128]u8 = undefined;
    try std.testing.expectError(
        error.TooLong,
        url_for.urlForWith(
            descriptor,
            .{ .id = @as(u8, 1) },
            .{},
            &output,
            .{ .bytes_max = 7 },
        ),
    );
    const values = [_]u16{ 1, 2 };
    const values_slice: []const u16 = &values;
    try std.testing.expectError(
        error.QueryPairLimit,
        url_for.urlForWith(
            descriptor,
            .{ .id = @as(u8, 1) },
            .{ .value = values_slice },
            &output,
            .{ .query_pairs_max = 1 },
        ),
    );
    try std.testing.expectError(
        error.InvalidQueryValue,
        url_for.urlFor(descriptor, .{ .id = @as(u8, 1) }, .{ .value = "\xff" }, &output),
    );
    try std.testing.expectError(
        error.InvalidQueryValue,
        url_for.urlFor(descriptor, .{ .id = @as(u8, 1) }, .{ .value = "\\" }, &output),
    );
    try std.testing.expectError(
        error.InvalidQueryValue,
        url_for.urlFor(descriptor, .{ .id = @as(u8, 1) }, .{ .value = std.math.nan(f64) }, &output),
    );
}

test "urlFor accepts exact output and configured query boundaries" {
    const descriptor = route.get("/:value", handler);
    var exact: [6]u8 = undefined;
    const built = try url_for.urlFor(descriptor, .{ .value = "a b" }, .{}, &exact);
    try std.testing.expectEqualStrings("/a%20b", built.bytes());

    const values = [_]u16{ 1, 2, 3 };
    const values_slice: []const u16 = &values;
    var output: [64]u8 = undefined;
    const queried = try url_for.urlForWith(
        descriptor,
        .{ .value = "x" },
        .{ .v = values_slice },
        &output,
        .{ .query_pairs_max = 3 },
    );
    try std.testing.expectEqualStrings("/x?v=1&v=2&v=3", queried.bytes());
}

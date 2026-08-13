const std = @import("std");
const application = @import("../../src/application.zig");
const asset_fixture = @import("asset_test.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const Assets = asset_fixture.Assets;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const AppState = struct { calls: u8 = 0 };
const TestContext = application.Context(AppState, response.standard_head_limits);

const CountMiddleware = struct {
    pub const State = void;

    pub fn init(_: CountMiddleware) State {}

    pub fn head(
        _: CountMiddleware,
        context: *TestContext,
        _: *State,
    ) ?TestContext.ResponseType {
        context.state.calls += 1;
        return null;
    }

    pub fn after(
        _: CountMiddleware,
        context: *const TestContext,
        _: *State,
        _: application.Outcome,
    ) void {
        context.state.calls += 1;
    }
};

fn applicationHandler(context: *TestContext) TestContext.ResponseType {
    context.state.calls += 1;
    return context.empty(.no_content);
}

const App = application.Application(.{
    .State = AppState,
    .assets = Assets,
    .middleware = .{CountMiddleware{}},
    .routes = .{route.get("/application", applicationHandler)},
});

const AssetOnlyApp = application.Application(.{
    .State = void,
    .assets = Assets,
    .routes = .{},
});

test "application may contain only generated asset routes" {
    var state: void = {};
    var workspace = AssetOnlyApp.Workspace{};
    var route_workspace: AssetOnlyApp.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const prepared = try AssetOnlyApp.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("GET", asset_fixture.Generated.assets[0].path, .{}),
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expectEqualStrings(
        asset_fixture.Generated.assets[0].identity.bytes,
        prepared.source.borrowed_static.body,
    );
    _ = try AssetOnlyApp.complete(&workspace);
}

test "embedded asset GET is a public borrowed-static application route" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const prepared = try App.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("GET", asset_fixture.Generated.assets[0].path, .{}),
        &output,
    );
    const borrowed = switch (prepared.source) {
        .borrowed_static => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(
        asset_fixture.Generated.assets[0].identity.bytes,
        borrowed.body,
    );
    try std.testing.expectEqual(
        @intFromPtr(asset_fixture.Generated.assets[0].identity.bytes.ptr),
        @intFromPtr(borrowed.body.ptr),
    );
    try expectContains(borrowed.head, "HTTP/1.1 200 OK\r\n");
    try expectContains(borrowed.head, "cache-control: public, max-age=31536000, immutable");
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    _ = try App.complete(&workspace);
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

test "failed asset serialization leaves workspace reusable" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    const request_input = input("GET", asset_fixture.Generated.assets[0].path, .{});
    var tiny_output: [1]u8 = undefined;

    try std.testing.expectError(
        error.OutputTooSmall,
        App.prepare(
            &state,
            &workspace,
            &route_workspace,
            request_input,
            &tiny_output,
        ),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);

    var output: [2048]u8 = undefined;
    const prepared = try App.prepare(
        &state,
        &workspace,
        &route_workspace,
        request_input,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    _ = try App.complete(&workspace);
}

test "asset preparation rejects forged coding weights in every build mode" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    const path = asset_fixture.Generated.assets[0].path;
    var request_input = input("GET", path, .{});
    var output: [2048]u8 = undefined;

    request_input.accept_encoding.gzip = 1001;
    try std.testing.expectError(
        error.InvalidResponse,
        App.prepare(&state, &workspace, &route_workspace, request_input, &output),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);

    request_input.accept_encoding = .{ .identity = 1001 };
    try std.testing.expectError(
        error.InvalidResponse,
        App.prepare(&state, &workspace, &route_workspace, request_input, &output),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);

    request_input.accept_encoding = .{};
    const prepared = try App.prepare(
        &state,
        &workspace,
        &route_workspace,
        request_input,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    _ = try App.complete(&workspace);
}

test "asset HEAD and conditional GET retain metadata without body" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const head = try App.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("HEAD", asset_fixture.Generated.assets[0].path, .{}),
        &output,
    );
    try std.testing.expectEqualStrings("", head.source.borrowed_static.body);
    try expectContains(head.source.borrowed_static.head, "content-length: 6\r\n");
    _ = try App.complete(&workspace);

    const condition = asset_fixture.Generated.assets[0].identity.etag;
    var header_storage = HeaderStorage.init("If-None-Match", condition);
    const conditional = try App.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("GET", asset_fixture.Generated.assets[0].path, header_storage.view()),
        &output,
    );
    try std.testing.expectEqual(response.Status.not_modified, conditional.status);
    try std.testing.expectEqualStrings("", conditional.source.borrowed_static.body);
    try expectContains(conditional.source.borrowed_static.head, "HTTP/1.1 304 Not Modified");
    _ = try App.complete(&workspace);
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

test "direct serve materializes borrowed asset only for caller convenience" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const result = try App.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", asset_fixture.Generated.assets[1].path, .{}),
        &output,
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        result.bytes,
        asset_fixture.Generated.assets[1].identity.bytes,
    ));
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

test "asset OPTIONS and method rejection use unified router without middleware" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const path = asset_fixture.Generated.assets[0].path;
    const options = try App.serve(
        &state,
        &workspace,
        &route_workspace,
        input("OPTIONS", path, .{}),
        &output,
    );
    try std.testing.expectEqual(response.Status.no_content, options.status);
    try expectContains(options.bytes, "allow: GET, HEAD, OPTIONS\r\n");
    try std.testing.expectEqual(@as(u8, 0), state.calls);

    const rejected = try App.serve(
        &state,
        &workspace,
        &route_workspace,
        input("POST", path, .{}),
        &output,
    );
    try std.testing.expectEqual(response.Status.method_not_allowed, rejected.status);
    try expectContains(rejected.bytes, "allow: GET, HEAD, OPTIONS\r\n");
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

test "asset slash redirect remains public and preserves generated location" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const path = asset_fixture.Generated.assets[0].path ++ "/";
    const redirected = try App.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", path, .{}),
        &output,
    );
    try std.testing.expectEqual(response.Status.moved_permanently, redirected.status);
    try expectContains(
        redirected.bytes,
        "location: " ++ asset_fixture.Generated.assets[0].path ++ "\r\n",
    );
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

fn input(
    method: []const u8,
    path: []const u8,
    headers: application.RequestHeaders,
) application.Input {
    return .{
        .method = method,
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = fixed_date,
        .headers = headers,
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

const HeaderStorage = struct {
    bytes: [160]u8 = undefined,
    field: request_head.Field,
    used: usize,

    fn init(name: []const u8, value: []const u8) HeaderStorage {
        var result: HeaderStorage = undefined;
        @memcpy(result.bytes[0..name.len], name);
        @memcpy(result.bytes[name.len..][0..value.len], value);
        result.used = name.len + value.len;
        result.field = .{
            .name = span(0, name.len),
            .raw_value = span(name.len, value.len),
            .value = span(name.len, value.len),
        };
        return result;
    }

    fn view(storage: *const HeaderStorage) application.RequestHeaders {
        return .{ .bytes = storage.bytes[0..storage.used], .fields = @as(
            *const [1]request_head.Field,
            &storage.field,
        ) };
    }
};

fn span(offset: usize, length: usize) request_head.Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

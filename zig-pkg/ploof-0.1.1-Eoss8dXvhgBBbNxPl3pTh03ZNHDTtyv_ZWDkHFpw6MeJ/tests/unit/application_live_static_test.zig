const std = @import("std");
const application = @import("../../src/application.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const response = @import("../../src/response.zig");
const static_file = @import("../../src/static_file.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const fixed_second: i64 = 1_784_030_400;

const State = struct {
    head_calls: u8 = 0,
    response_calls: u8 = 0,
    after_calls: u8 = 0,
};

const TestContext = application.Context(State, response.standard_head_limits);

const Trace = struct {
    pub const State = void;

    pub fn init(_: Trace) void {}

    pub fn head(_: Trace, context: *TestContext, _: *void) ?TestContext.ResponseType {
        context.state.head_calls += 1;
        return null;
    }

    pub fn response(
        _: Trace,
        context: *TestContext,
        _: *void,
        _: *TestContext.ResponseType,
    ) void {
        context.state.response_calls += 1;
    }

    pub fn after(
        _: Trace,
        context: *const TestContext,
        _: *void,
        _: application.Outcome,
    ) void {
        context.state.after_calls += 1;
    }
};

const App = application.Application(.{
    .State = State,
    .routes = .{
        static_file.StaticDir.configured(
            "/assets",
            "/srv/assets",
            .{},
            .{Trace{}},
            null,
        ),
    },
});

test "live static route resolves metadata after head middleware without copying body" {
    var state = State{};
    var workspace = App.Workspace{};
    var route_workspace = App.RouteSearchWorkspace{};
    var output: [2048]u8 = undefined;
    const head = try App.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/assets/app.js", .{}),
        &output,
    );
    const intent = switch (head) {
        .prepared => |prepared| prepared.source.live_static,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), state.head_calls);
    try std.testing.expectEqualStrings("app.js", intent.path.directory.relative_path);

    const prepared = try App.__prepareLiveStatic(
        &workspace,
        intent,
        fileResolution("app.js", 12),
        &output,
    );
    const file = prepared.source.live_static_file;
    try std.testing.expectEqual(@as(u64, 0), file.offset);
    try std.testing.expectEqual(@as(u64, 12), file.length);
    try std.testing.expect(file.transfer_body);
    try expectContains(file.head, "HTTP/1.1 200 OK\r\n");
    try expectContains(file.head, "content-length: 12\r\n");
    try expectContains(file.head, "content-type: text/javascript; charset=utf-8\r\n");
    try expectContains(file.head, "accept-ranges: bytes\r\n");
    try expectContains(file.head, "x-content-type-options: nosniff\r\n");
    try std.testing.expectEqual(@as(u8, 1), state.response_calls);
    _ = try App.complete(&workspace);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
}

test "live static range and directory redirect retain exact wire semantics" {
    var state = State{};
    var workspace = App.Workspace{};
    var route_workspace = App.RouteSearchWorkspace{};
    var output: [2048]u8 = undefined;
    var range = HeaderStorage.init("Range", "bytes=2-4");
    const ranged_head = try App.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/assets/app.js", range.view()),
        &output,
    );
    const ranged_intent = ranged_head.prepared.source.live_static;
    const ranged = try App.__prepareLiveStatic(
        &workspace,
        ranged_intent,
        fileResolution("app.js", 12),
        &output,
    );
    try std.testing.expectEqual(response.Status.partial_content, ranged.status);
    try std.testing.expectEqual(@as(u64, 2), ranged.source.live_static_file.offset);
    try std.testing.expectEqual(@as(u64, 3), ranged.source.live_static_file.length);
    try expectContains(ranged.source.live_static_file.head, "content-range: bytes 2-4/12\r\n");
    _ = try App.complete(&workspace);

    const redirect_head = try App.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/assets/docs", .{}),
        &output,
    );
    const redirect_intent = redirect_head.prepared.source.live_static;
    const redirected = try App.__prepareLiveStatic(
        &workspace,
        redirect_intent,
        .redirect_directory,
        &output,
    );
    try std.testing.expectEqual(response.Status.permanent_redirect, redirected.status);
    try expectContains(redirected.source.contiguous_wire, "location: /assets/docs/\r\n");
    _ = try App.complete(&workspace);
}

fn fileResolution(filename: []const u8, size: u64) static_file.RuntimeResolution {
    return .{ .file = .{
        .identity = .{
            .device_major = 8,
            .device_minor = 1,
            .inode = 42,
            .size = size,
            .mtime_seconds = fixed_second - 60,
            .mtime_nanoseconds = 123,
        },
        .message_epoch_second = fixed_second,
        .filename = filename,
    } };
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
        return .{
            .bytes = storage.bytes[0..storage.used],
            .fields = @as(*const [1]request_head.Field, &storage.field),
        };
    }
};

fn span(offset: usize, length: usize) request_head.Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

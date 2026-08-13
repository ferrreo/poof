const std = @import("std");
const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const limits = @import("../../src/internal/http1/limits.zig");
const request_analysis = @import("../../src/internal/http1/request_analysis.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const request_target = @import("../../src/internal/http1/request_target.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const State = struct { calls: u32 = 0 };
const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;

const CountMiddleware = struct {
    pub const State = void;

    pub fn head(
        _: CountMiddleware,
        context: *Context,
        _: *void,
    ) ?Response {
        context.state.calls += 1;
        return null;
    }
};

fn handler(context: *Context) Response {
    return context.textBorrowed(
        .ok,
        context.request.param("name") orelse unreachable,
    );
}

const App = application.Application(.{
    .State = State,
    .middleware = .{CountMiddleware{}},
    .routes = .{route.get("/hello/:name", handler)},
});

const Decoder = request_head.Decoder(limits.standard_request_head_limits);
const Accepted = struct {
    analysis: request_analysis.Analysis(4),
    method: []const u8,
};

fn accepted(
    decoder: *Decoder,
    wire: []const u8,
    path_output: []u8,
) !Accepted {
    const decoded = decoder.feed(wire);
    const head = switch (decoded.state) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const analysis = switch (request_analysis.analyze(
        16,
        4,
        head,
        decoder.fields(),
        decoder.bytes(),
        path_output,
    )) {
        .accepted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    return .{
        .analysis = analysis,
        .method = head.method.slice(decoder.bytes()),
    };
}

fn inputFromTarget(
    method: []const u8,
    target: request_target.Target,
) application.Input {
    return switch (target) {
        .origin => |origin| .{
            .method = method,
            .path = origin.decoded_path,
            .raw_target = origin.raw_target,
            .raw_path = origin.raw_path,
            .raw_query = origin.raw_query,
            .date = fixed_date,
        },
        .absolute => |absolute| .{
            .method = method,
            .path = absolute.decoded_path,
            .raw_target = absolute.raw_target,
            .raw_path = absolute.raw_path,
            .raw_query = absolute.raw_query,
            .date = fixed_date,
        },
        .asterisk => |raw| .{
            .method = method,
            .path = raw,
            .raw_target = raw,
            .raw_path = raw,
            .date = fixed_date,
        },
    };
}

test "raw GET parses analyzes routes and serializes exactly" {
    const wire =
        "GET /hello/zig?x=1 HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "\r\n";
    var decoder = Decoder.init();
    var path_output: [wire.len]u8 = undefined;
    const parsed = try accepted(&decoder, wire, &path_output);

    var state = State{};
    var workspace = App.Workspace{};
    var route_workspace = App.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;
    const result = try App.serve(
        &state,
        &workspace,
        &route_workspace,
        inputFromTarget(parsed.method, parsed.analysis.target),
        &output,
    );
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 3\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "\r\n" ++
        "zig";
    try std.testing.expectEqualStrings(expected, result.bytes);
    try std.testing.expectEqual(@as(u32, 1), state.calls);
}

test "semantic parser rejection never enters application middleware" {
    const wire = "GET /% HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var decoder = Decoder.init();
    const decoded = decoder.feed(wire);
    const head = switch (decoded.state) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var path_output: [wire.len]u8 = undefined;
    const rejected = switch (request_analysis.analyze(
        16,
        4,
        head,
        decoder.fields(),
        decoder.bytes(),
        &path_output,
    )) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |value| value,
    };
    try std.testing.expectEqual(response.Status.bad_request, rejected.status);

    const state = State{};
    try std.testing.expectEqual(@as(u32, 0), state.calls);
}

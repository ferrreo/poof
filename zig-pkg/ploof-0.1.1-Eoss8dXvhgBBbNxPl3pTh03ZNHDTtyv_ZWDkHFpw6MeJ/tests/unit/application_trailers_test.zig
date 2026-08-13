const std = @import("std");
const application = @import("../../src/application.zig");
const application_context = @import("../../src/application/context.zig");
const application_runtime = @import("../../src/internal/application/runtime.zig");
const request_body = @import("../../src/body.zig");
const limits = @import("../../src/internal/http1/limits.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const request_trailers = @import("../../src/internal/http1/request_trailers.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const trailer_head =
    "POST /upload HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n" ++
    "\r\n";
const trailer_section =
    "X-Check:  first \t\r\n" ++
    "x-CHECK:\tsecond\r\n" ++
    "\r\n";

fn input(method: []const u8, path: []const u8) application.Input {
    return .{
        .method = method,
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = fixed_date,
    };
}

fn decodeTrailers() !request_trailers.StandardDecoder {
    const HeadDecoder = request_head.Decoder(limits.standard_request_head_limits);
    var head_decoder = HeadDecoder.init();
    switch (head_decoder.feed(trailer_head).state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    const declarations = try request_trailers.StandardDeclarations.parse(
        head_decoder.fields(),
        trailer_head,
    );
    var decoder = request_trailers.StandardDecoder.init(
        declarations,
        trailer_head,
        trailer_section.len,
    );
    switch (decoder.feed(trailer_section).event) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    return decoder;
}

fn trailerView(decoder: *const request_trailers.StandardDecoder) application.RequestTrailers {
    return .{ .section = decoder.bytes() };
}

test "nonchunked input has an empty trailer view" {
    const request = application_runtime.requestFromInput(input("GET", "/plain"));
    try std.testing.expect(!request.accepts_response_trailers);
    try std.testing.expectEqual(@as(usize, 0), request.trailers.raw().count());
    try std.testing.expectEqual(@as(usize, 0), request.trailers.all("x-check").count());
    try std.testing.expectEqual(@as(?[]const u8, null), request.trailers.all("x").first());
}

test "forged malformed trailer sections fail closed without unsafe spans" {
    const cases = [_][]const u8{
        "X-Check: value",
        ": value\r\n\r\n",
        "malformed\r\nX-Check: hidden\r\n\r\n",
        "X-Check: prefix\r\nmalformed",
        "\r\ntrailing",
        "Bad Name: value\r\n\r\n",
        "X-Check: bad\x00value\r\n\r\n",
        " folded: value\r\n\r\n",
    };
    for (cases) |section| {
        const trailers = application.RequestTrailers{ .section = section };
        try std.testing.expectEqual(@as(usize, 0), trailers.raw().count());
        try std.testing.expectEqual(@as(usize, 0), trailers.all("x-check").count());
        try std.testing.expectError(error.Missing, trailers.all("x-check").one());
    }
    const forged = application_context.TrailerValues{
        .section = "",
        .name = "x-check",
        .matches_count = 1,
    };
    try std.testing.expectError(error.Missing, forged.one());
}

test "input copies ordered trimmed and raw request trailers" {
    var decoder = try decodeTrailers();
    var request_input = input("POST", "/upload");
    request_input.accepts_response_trailers = true;
    request_input.trailers = trailerView(&decoder);
    const request = application_runtime.requestFromInput(request_input);
    try std.testing.expect(request.accepts_response_trailers);

    const values = request.trailers.all("x-cHeCk");
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectEqualStrings("first", values.first().?);
    try std.testing.expectError(error.Multiple, values.one());
    var iterator = values.iterator();
    try std.testing.expectEqualStrings("first", iterator.next().?);
    try std.testing.expectEqualStrings("second", iterator.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());

    const raw = request.trailers.raw();
    try std.testing.expectEqual(@as(usize, 2), raw.count());
    var raw_iterator = raw.iterator();
    const first = raw_iterator.next().?;
    try std.testing.expectEqualStrings("X-Check", first.name);
    try std.testing.expectEqualStrings("  first \t", first.value);
    const second = raw_iterator.next().?;
    try std.testing.expectEqualStrings("x-CHECK", second.name);
    try std.testing.expectEqualStrings("\tsecond", second.value);
    try std.testing.expectEqual(@as(?@TypeOf(first), null), raw_iterator.next());
}

const TestState = struct {
    head_empty: bool = false,
    body_saw_trailers: bool = false,
    handler_saw_trailers: bool = false,
    response_saw_trailers: bool = false,
    after_saw_trailers: bool = false,
    plain_empty: bool = false,
};

const TestContext = application.Context(TestState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;

fn viewIsEmpty(trailers: application.RequestTrailers) bool {
    if (trailers.raw().count() != 0) return false;
    return trailers.all("x-check").count() == 0;
}

fn viewHasExpectedValues(trailers: application.RequestTrailers) bool {
    const values = trailers.all("X-CHECK");
    if (values.count() != 2) return false;
    var iterator = values.iterator();
    const first = iterator.next() orelse return false;
    if (!std.mem.eql(u8, first, "first")) return false;
    const second = iterator.next() orelse return false;
    if (!std.mem.eql(u8, second, "second")) return false;
    return iterator.next() == null;
}

const ObserveTrailers = struct {
    pub const State = void;

    pub fn head(
        _: ObserveTrailers,
        context: *TestContext,
        _: *State,
    ) ?TestResponse {
        context.state.head_empty = viewIsEmpty(context.request.trailers);
        return null;
    }

    pub fn bodyPhase(
        _: ObserveTrailers,
        context: *TestContext,
        _: *State,
        _: request_body.Bytes,
    ) ?TestResponse {
        context.state.body_saw_trailers = viewHasExpectedValues(context.request.trailers);
        return null;
    }

    pub const body = bodyPhase;

    pub fn responsePhase(
        _: ObserveTrailers,
        context: *TestContext,
        _: *State,
        _: *TestResponse,
    ) void {
        context.state.response_saw_trailers = viewHasExpectedValues(
            context.request.trailers,
        );
    }

    pub const response = responsePhase;

    pub fn after(
        _: ObserveTrailers,
        context: *const TestContext,
        _: *State,
        _: application.Outcome,
    ) void {
        context.state.after_saw_trailers = viewHasExpectedValues(context.request.trailers);
    }
};

fn uploadHandler(context: *TestContext, value: request_body.Bytes) TestResponse {
    context.state.handler_saw_trailers = viewHasExpectedValues(context.request.trailers);
    return context.textBorrowed(.ok, value.single().?);
}

fn plainHandler(context: *TestContext) TestResponse {
    context.state.plain_empty = viewIsEmpty(context.request.trailers);
    return context.empty(.no_content);
}

const TestApplication = application.Application(.{
    .State = TestState,
    .routes = .{
        route.configured(
            .post,
            "/upload",
            request_body.bytes(.{}, uploadHandler),
            .{ObserveTrailers{}},
            null,
        ),
        route.get("/plain", plainHandler),
    },
});

test "final trailers begin at body phase and remain through after" {
    var decoder = try decodeTrailers();
    const trailers = trailerView(&decoder);
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace = TestApplication.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;
    var head_input = input("POST", "/upload");
    head_input.trailers = trailers;

    const head_result = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        head_input,
        &output,
    );
    switch (head_result) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.head_empty);
    try std.testing.expect(!state.body_saw_trailers);

    const chunks = [_]request_body.Chunk{request_body.Chunk.init("data")};
    const decoded = try request_body.Bytes.init(&chunks);
    _ = try TestApplication.prepareBody(
        &workspace,
        .{ .bytes = decoded },
        trailers,
        &output,
    );
    try std.testing.expect(state.body_saw_trailers);
    try std.testing.expect(state.handler_saw_trailers);
    try std.testing.expect(state.response_saw_trailers);
    try std.testing.expect(!state.after_saw_trailers);
    try std.testing.expect(viewHasExpectedValues(workspace.context.request.trailers));

    _ = try TestApplication.complete(&workspace);
    try std.testing.expect(state.after_saw_trailers);
}

test "whole input hides final trailers from head phase" {
    var decoder = try decodeTrailers();
    const chunks = [_]request_body.Chunk{request_body.Chunk.init("data")};
    var request_input = input("POST", "/upload");
    request_input.body = .{ .bytes = try request_body.Bytes.init(&chunks) };
    request_input.trailers = trailerView(&decoder);
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace = TestApplication.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    _ = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        request_input,
        &output,
    );
    try std.testing.expect(state.head_empty);
    try std.testing.expect(state.body_saw_trailers);
    try std.testing.expect(state.handler_saw_trailers);
    try std.testing.expect(state.response_saw_trailers);
    try std.testing.expect(state.after_saw_trailers);
}

test "bodyless application request keeps trailers empty" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace = TestApplication.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;
    _ = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/plain"),
        &output,
    );
    try std.testing.expect(state.plain_empty);
}

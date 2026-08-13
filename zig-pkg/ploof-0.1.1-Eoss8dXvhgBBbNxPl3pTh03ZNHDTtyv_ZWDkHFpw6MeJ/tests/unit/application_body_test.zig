const std = @import("std");
const application = @import("../../src/application.zig");
const application_input = @import("../../src/internal/application/input.zig");
const request_body = @import("../../src/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

const TestState = struct {
    bytes_calls: u8 = 0,
    bytes_matched: bool = false,
    text_head_calls: u8 = 0,
    text_body_calls: u8 = 0,
    text_body_bytes: usize = 0,
    text_body_saw_head_state: bool = false,
    text_handler_saw_body_state: bool = false,
    text_response_calls: u8 = 0,
    text_response_saw_body_state: bool = false,
    text_after_calls: u8 = 0,
    text_after_saw_body_state: bool = false,
    text_after_status: ?response.Status = null,
    bodyless_body_calls: u8 = 0,
};

const TestContext = application.Context(TestState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;

const TextBodyMiddleware = struct {
    pub const State = usize;

    pub fn init(_: TextBodyMiddleware) State {
        return 0;
    }

    pub fn head(
        _: TextBodyMiddleware,
        context: *TestContext,
        state: *State,
    ) ?TestResponse {
        context.state.text_head_calls += 1;
        state.* = 0xa5;
        return null;
    }

    pub fn body(
        _: TextBodyMiddleware,
        context: *TestContext,
        state: *State,
        value: request_body.Text,
    ) ?TestResponse {
        context.state.text_body_saw_head_state = state.* == 0xa5;
        state.* = value.len();
        context.state.text_body_calls += 1;
        context.state.text_body_bytes = state.*;
        return null;
    }

    pub fn response(
        _: TextBodyMiddleware,
        context: *TestContext,
        state: *State,
        _: *TestResponse,
    ) void {
        context.state.text_response_calls += 1;
        context.state.text_response_saw_body_state = state.* == context.state.text_body_bytes;
    }

    pub fn after(
        _: TextBodyMiddleware,
        context: *const TestContext,
        state: *State,
        outcome: application.Outcome,
    ) void {
        context.state.text_after_calls += 1;
        context.state.text_after_saw_body_state = state.* == context.state.text_body_bytes;
        context.state.text_after_status = outcome.status;
    }
};

const BodylessMiddleware = struct {
    pub const State = void;

    pub fn body(
        _: BodylessMiddleware,
        context: *TestContext,
        _: *State,
        _: application.Bodyless,
    ) ?TestResponse {
        context.state.bodyless_body_calls += 1;
        return null;
    }
};

const HeadShortBodyMiddleware = struct {
    pub const State = void;

    pub fn head(
        _: HeadShortBodyMiddleware,
        context: *TestContext,
        _: *State,
    ) ?TestResponse {
        return context.empty(.forbidden);
    }
};

fn bytesHandler(context: *TestContext, value: request_body.Bytes) TestResponse {
    context.state.bytes_calls += 1;
    context.state.bytes_matched = value.eql("abcdef");
    return context.textStatic(.ok, "bytes-ok");
}

fn textHandler(context: *TestContext, value: request_body.Text) TestResponse {
    const body_state_matches = context.state.text_body_bytes == value.len();
    context.state.text_handler_saw_body_state = body_state_matches;
    return context.textStatic(.ok, "text-ok");
}

fn bodylessHandler(context: *TestContext) TestResponse {
    return context.textStatic(.ok, "bodyless-ok");
}

const text_media = [_]request_body.MediaPattern{
    .{ .exact = "text/plain" },
    .{ .type_wildcard = "text" },
};

const TestApplication = application.Application(.{
    .State = TestState,
    .routes = .{
        route.post("/bytes", request_body.bytes(.{
            .encoded_wire_bytes_max = 32,
            .decoded_bytes_max = 64,
        }, bytesHandler)),
        route.configured(
            .post,
            "/text",
            request_body.text(.{
                .encoded_wire_bytes_max = 17,
                .decoded_bytes_max = 23,
                .accepted_media = &text_media,
            }, textHandler),
            .{TextBodyMiddleware{}},
            null,
        ),
        route.configured(
            .get,
            "/bodyless",
            bodylessHandler,
            .{BodylessMiddleware{}},
            null,
        ),
    },
});

const HeadShortBodyApplication = application.Application(.{
    .State = TestState,
    .routes = .{
        route.configured(
            .post,
            "/short",
            request_body.bytes(.{}, bytesHandler),
            .{HeadShortBodyMiddleware{}},
            null,
        ),
    },
});

fn input(method: []const u8, path: []const u8) application.Input {
    return .{
        .method = method,
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = fixed_date,
    };
}

test "typed byte and text endpoints receive decoded views" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;

    const byte_chunks = [_]request_body.Chunk{
        request_body.Chunk.init("ab"),
        request_body.Chunk.init("cdef"),
    };
    var byte_input = input("POST", "/bytes");
    byte_input.body = .{ .bytes = try request_body.Bytes.init(&byte_chunks) };
    const byte_result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        byte_input,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, byte_result.status);
    try std.testing.expect(std.mem.endsWith(u8, byte_result.bytes, "\r\n\r\nbytes-ok"));
    try std.testing.expectEqual(@as(u8, 1), state.bytes_calls);
    try std.testing.expect(state.bytes_matched);

    const text_chunks = [_]request_body.Chunk{
        request_body.Chunk.init("hello "),
        request_body.Chunk.init("world"),
    };
    var text_input = input("POST", "/text");
    text_input.body = .{ .text = try request_body.Text.init(&text_chunks) };
    const text_result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        text_input,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, text_result.status);
    try std.testing.expect(std.mem.endsWith(u8, text_result.bytes, "\r\n\r\ntext-ok"));
    try std.testing.expectEqual(@as(u8, 1), state.text_body_calls);
    try std.testing.expectEqual(@as(usize, 11), state.text_body_bytes);
    try std.testing.expect(state.text_handler_saw_body_state);
}

test "head and body preparation share middleware state without reinitializing" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const request_input = input("POST", "/text");
    var request_plan = TestApplication.plan(request_input, &route_workspace);

    const head_result = try TestApplication.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &request_plan,
        .{ .close_if_prepared = true },
    );
    const body_plan = switch (head_result) {
        .receive_body => |value| value,
        .prepared => return error.TestUnexpectedResult,
    };
    try std.testing.expect(body_plan.kind == .text);
    try std.testing.expectEqual(@as(u8, 1), state.text_head_calls);
    try std.testing.expectEqual(@as(u8, 0), state.text_body_calls);
    try std.testing.expectEqual(@as(u8, 0), state.text_response_calls);
    try std.testing.expectError(error.NoPendingRequest, TestApplication.complete(&workspace));
    try std.testing.expectError(
        error.RequestAlreadyPending,
        TestApplication.prepareHead(
            &state,
            &workspace,
            &route_workspace,
            request_input,
            &output,
        ),
    );

    const chunks = [_]request_body.Chunk{request_body.Chunk.init("split body")};
    const decoded = try request_body.Text.init(&chunks);
    const prepared = try TestApplication.prepareBody(
        &workspace,
        .{ .text = decoded },
        .{},
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expect(!prepared.close_connection);
    try std.testing.expect(state.text_body_saw_head_state);
    try std.testing.expect(state.text_handler_saw_body_state);
    try std.testing.expectEqual(@as(u8, 1), state.text_response_calls);
    try std.testing.expect(state.text_response_saw_body_state);
    try std.testing.expectEqual(@as(u8, 0), state.text_after_calls);

    _ = try TestApplication.complete(&workspace);
    try std.testing.expectEqual(@as(u8, 1), state.text_after_calls);
    try std.testing.expect(state.text_after_saw_body_state);
    try std.testing.expectEqual(
        @as(?response.Status, response.Status.ok),
        state.text_after_status,
    );

    const bodyless = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/bodyless"),
        &output,
    );
    switch (bodyless) {
        .prepared => {},
        .receive_body => return error.TestUnexpectedResult,
    }
    _ = try TestApplication.complete(&workspace);
}

test "split body kind mismatch unwinds once and leaves workspace reusable" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const request_input = input("POST", "/text");
    const head_result = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        request_input,
        &output,
    );
    switch (head_result) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }

    const wrong_chunks = [_]request_body.Chunk{request_body.Chunk.init("wrong")};
    const wrong = try request_body.Bytes.init(&wrong_chunks);
    try std.testing.expectError(
        error.InvalidBodyInput,
        TestApplication.prepareBody(&workspace, .{ .bytes = wrong }, .{}, &output),
    );
    try std.testing.expectEqual(@as(u8, 0), state.text_body_calls);
    try std.testing.expectEqual(@as(u8, 0), state.text_response_calls);
    try std.testing.expectEqual(@as(u8, 1), state.text_after_calls);
    try std.testing.expectEqual(@as(?response.Status, null), state.text_after_status);

    const reused = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/bodyless"),
        &output,
    );
    switch (reused) {
        .prepared => {},
        .receive_body => return error.TestUnexpectedResult,
    }
    _ = try TestApplication.complete(&workspace);
}

test "short endpoint output workspace unwinds initialized middleware" {
    const AppState = struct { after_calls: u8 = 0 };
    const Context = application.Context(AppState, response.standard_head_limits);
    const Response = Context.ResponseType;
    const Middleware = struct {
        pub const State = void;

        pub fn after(
            _: @This(),
            context: *const Context,
            _: *State,
            _: application.Outcome,
        ) void {
            context.state.after_calls += 1;
        }
    };
    const Definition = endpoint.Endpoint(.{
        .body = request_body.raw(.{
            .encoded_wire_bytes_max = 8,
            .decoded_bytes_max = 8,
        }),
        .response_json_bytes_max = 8,
    });
    const handler = Definition.handle(struct {
        fn call(context: *Context, _: Definition.InputType) Response {
            return context.empty(.ok);
        }
    }.call);
    const App = application.Application(.{
        .State = AppState,
        .routes = .{route.configured(
            .post,
            "/endpoint",
            handler,
            .{Middleware{}},
            null,
        )},
    });
    const Handler = @TypeOf(handler);
    const layout = comptime application_input.workspaceLayout(Handler);
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);

    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [2048]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    try std.testing.expectError(
        error.InputInvariant,
        App.prepareHeadIn(
            &state,
            &workspace,
            &route_workspace,
            input("POST", "/endpoint"),
            request_workspace[0 .. request_workspace.len - 1],
            &output,
        ),
    );
    const head = try App.prepareHeadIn(
        &state,
        &workspace,
        &route_workspace,
        input("POST", "/endpoint"),
        &request_workspace,
        &output,
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    const body_region = layout.body_decoders[0].body;
    request_workspace[body_region.offset] = 'x';
    const chunks = [_]request_body.Chunk{
        request_body.Chunk.init(request_workspace[body_region.offset..][0..1]),
    };
    const decoded = try request_body.Bytes.init(&chunks);
    try std.testing.expectError(
        error.InputInvariant,
        App.__prepareBodyWithResponseGzip(
            &workspace,
            .{ .bytes = decoded },
            .{},
            request_workspace[0 .. request_workspace.len - 1],
            [_]u8{0} ** 16,
            &output,
            &gzip,
        ),
    );
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);

    const reused = try App.prepareHeadIn(
        &state,
        &workspace,
        &route_workspace,
        input("POST", "/endpoint"),
        &request_workspace,
        &output,
    );
    switch (reused) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    _ = try App.abort(&workspace);
    try std.testing.expectEqual(@as(u8, 2), state.after_calls);
}

test "awaiting body abort has no final status and unwinds once" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const head_result = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("POST", "/text"),
        &output,
    );
    switch (head_result) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }

    const outcome = try TestApplication.abort(&workspace);
    try std.testing.expectEqual(@as(?response.Status, null), outcome.status);
    try std.testing.expectEqual(application.TransportOutcome.aborted, outcome.transport);
    try std.testing.expectEqual(@as(u8, 0), state.text_body_calls);
    try std.testing.expectEqual(@as(u8, 0), state.text_response_calls);
    try std.testing.expectEqual(@as(u8, 1), state.text_after_calls);
    try std.testing.expectEqual(@as(?response.Status, null), state.text_after_status);
    try std.testing.expectError(error.NoPendingRequest, TestApplication.abort(&workspace));

    const reused = try TestApplication.prepareHead(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/bodyless"),
        &output,
    );
    switch (reused) {
        .prepared => {},
        .receive_body => return error.TestUnexpectedResult,
    }
    _ = try TestApplication.complete(&workspace);
}

test "post-head body rejection bypasses response middleware and defers after" {
    var completed_state = TestState{};
    var completed_workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const completed_head = try TestApplication.prepareHead(
        &completed_state,
        &completed_workspace,
        &route_workspace,
        input("POST", "/text"),
        &output,
    );
    switch (completed_head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try TestApplication.rejectBody(&completed_workspace, .payload_too_large);
    try std.testing.expectEqual(@as(u8, 0), completed_state.text_body_calls);
    try std.testing.expectEqual(@as(u8, 0), completed_state.text_response_calls);
    try std.testing.expectEqual(@as(u8, 0), completed_state.text_after_calls);
    const completed = try TestApplication.complete(&completed_workspace);
    try std.testing.expectEqual(
        @as(?response.Status, response.Status.payload_too_large),
        completed.status,
    );
    try std.testing.expectEqual(@as(u8, 1), completed_state.text_after_calls);

    var aborted_state = TestState{};
    var aborted_workspace = TestApplication.Workspace{};
    const aborted_head = try TestApplication.prepareHead(
        &aborted_state,
        &aborted_workspace,
        &route_workspace,
        input("POST", "/text"),
        &output,
    );
    switch (aborted_head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try TestApplication.rejectBody(&aborted_workspace, .bad_request);
    const aborted = try TestApplication.abort(&aborted_workspace);
    try std.testing.expectEqual(
        @as(?response.Status, response.Status.bad_request),
        aborted.status,
    );
    try std.testing.expectEqual(application.TransportOutcome.aborted, aborted.transport);
    try std.testing.expectEqual(@as(u8, 0), aborted_state.text_response_calls);
    try std.testing.expectEqual(@as(u8, 1), aborted_state.text_after_calls);
}

test "head short circuit can force connection close before body intake" {
    var state = TestState{};
    var workspace = HeadShortBodyApplication.Workspace{};
    var route_workspace: HeadShortBodyApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const request_input = input("POST", "/short");
    var request_plan = HeadShortBodyApplication.plan(request_input, &route_workspace);

    const closed = try HeadShortBodyApplication.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &request_plan,
        .{ .close_if_prepared = true },
    );
    const closed_response = switch (closed) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(response.Status.forbidden, closed_response.status);
    try std.testing.expect(closed_response.close_connection);
    try std.testing.expect(std.mem.indexOf(u8, closed_response.bytes, "connection: close") != null);
    try std.testing.expectEqual(@as(u8, 0), state.bytes_calls);
    _ = try HeadShortBodyApplication.complete(&workspace);

    const kept = try HeadShortBodyApplication.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &request_plan,
        .{},
    );
    const kept_response = switch (kept) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!kept_response.close_connection);
    try std.testing.expect(std.mem.indexOf(u8, kept_response.bytes, "connection: close") == null);
    _ = try HeadShortBodyApplication.complete(&workspace);
}

test "head close policy covers bodyless and generated prepared responses" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;

    const bodyless_input = input("GET", "/bodyless");
    var bodyless_plan = TestApplication.plan(bodyless_input, &route_workspace);
    const bodyless_result = try TestApplication.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &bodyless_plan,
        .{ .close_if_prepared = true },
    );
    const bodyless_prepared = switch (bodyless_result) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expect(bodyless_prepared.close_connection);
    try std.testing.expect(
        std.mem.indexOf(u8, bodyless_prepared.bytes, "connection: close") != null,
    );
    _ = try TestApplication.complete(&workspace);

    const missing_input = input("GET", "/missing");
    var missing_plan = TestApplication.plan(missing_input, &route_workspace);
    const missing_result = try TestApplication.prepareHeadPlanned(
        &state,
        &workspace,
        &output,
        &missing_plan,
        .{ .close_if_prepared = true },
    );
    const missing_prepared = switch (missing_result) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(response.Status.not_found, missing_prepared.status);
    try std.testing.expect(missing_prepared.close_connection);
    try std.testing.expect(
        std.mem.indexOf(u8, missing_prepared.bytes, "connection: close") != null,
    );
    _ = try TestApplication.complete(&workspace);
}

test "request plans expose body admission metadata" {
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    const bytes_plan = TestApplication.plan(input("POST", "/bytes"), &route_workspace).body;
    try std.testing.expectEqual(.bytes, bytes_plan.kind);
    try std.testing.expectEqual(@as(u64, 32), bytes_plan.encoded_wire_bytes_max);
    try std.testing.expectEqual(@as(u64, 64), bytes_plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(u16, 1), bytes_plan.workspace_class);
    try std.testing.expectEqual(@as(usize, 1), bytes_plan.accepted_media.len);
    try expectExactMedia(bytes_plan.accepted_media[0], "application/octet-stream");

    const text_plan = TestApplication.plan(input("POST", "/text"), &route_workspace).body;
    try std.testing.expectEqual(.text, text_plan.kind);
    try std.testing.expectEqual(@as(u64, 17), text_plan.encoded_wire_bytes_max);
    try std.testing.expectEqual(@as(u64, 23), text_plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(u16, 1), text_plan.workspace_class);
    try std.testing.expectEqual(@as(usize, 2), text_plan.accepted_media.len);
    try expectExactMedia(text_plan.accepted_media[0], "text/plain");
    try expectTypeWildcard(text_plan.accepted_media[1], "text");

    try std.testing.expectEqual(@as(u16, 2), TestApplication.workspace_class_count);
    try std.testing.expectEqual(@as(u64, 64), TestApplication.body_workspace_bytes_max);
}

fn expectExactMedia(pattern: request_body.MediaPattern, expected: []const u8) !void {
    const actual = switch (pattern) {
        .exact => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectTypeWildcard(pattern: request_body.MediaPattern, expected: []const u8) !void {
    const actual = switch (pattern) {
        .type_wildcard => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, actual);
}

test "bodyless route keeps class zero and receives Bodyless middleware input" {
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    const body_plan = TestApplication.plan(input("GET", "/bodyless"), &route_workspace).body;
    try std.testing.expectEqual(.none, body_plan.kind);
    try std.testing.expectEqual(@as(u64, 0), body_plan.encoded_wire_bytes_max);
    try std.testing.expectEqual(@as(u64, 0), body_plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(u16, 0), body_plan.workspace_class);
    try std.testing.expectEqual(@as(usize, 0), body_plan.accepted_media.len);

    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var output: [512]u8 = undefined;
    const result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/bodyless"),
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, result.status);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "\r\n\r\nbodyless-ok"));
    try std.testing.expectEqual(@as(u8, 1), state.bodyless_body_calls);
}

test "decoded kind mismatch rejects and leaves workspace reusable" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;

    const wrong_chunks = [_]request_body.Chunk{request_body.Chunk.init("not text")};
    var wrong = input("POST", "/text");
    wrong.body = .{ .bytes = try request_body.Bytes.init(&wrong_chunks) };
    try std.testing.expectError(
        error.InvalidBodyInput,
        TestApplication.serve(&state, &workspace, &route_workspace, wrong, &output),
    );
    try std.testing.expectEqual(@as(u8, 0), state.text_body_calls);

    const valid_chunks = [_]request_body.Chunk{request_body.Chunk.init("valid")};
    var valid = input("POST", "/text");
    valid.body = .{ .text = try request_body.Text.init(&valid_chunks) };
    const result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        valid,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, result.status);
    try std.testing.expectEqual(@as(u8, 1), state.text_body_calls);
}

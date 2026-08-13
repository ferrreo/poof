const std = @import("std");
const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const TestContext = application.Context(TestState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;
const AppError = error{Denied};

const TestState = struct {
    events: [64]u8 = undefined,
    events_len: usize = 0,
    last_transport: application.TransportOutcome = .aborted,
    last_mapped_error: bool = false,
    first_middleware_state: usize = 0,

    fn mark(state: *TestState, byte: u8) void {
        state.events[state.events_len] = byte;
        state.events_len += 1;
    }

    fn reset(state: *TestState) void {
        state.events_len = 0;
        state.last_transport = .aborted;
        state.last_mapped_error = false;
        state.first_middleware_state = 0;
    }

    fn written(state: *const TestState) []const u8 {
        return state.events[0..state.events_len];
    }
};

const Trace = struct {
    marker: u8,

    pub const State = u8;

    pub fn init(self: Trace) State {
        return self.marker;
    }

    pub fn head(_: Trace, context: *TestContext, state: *State) AppError!?TestResponse {
        if (context.state.first_middleware_state == 0) {
            context.state.first_middleware_state = @intFromPtr(state);
        }
        context.state.mark(state.*);
        return null;
    }

    pub fn body(
        _: Trace,
        context: *TestContext,
        state: *State,
        _: application.Bodyless,
    ) ?TestResponse {
        context.state.mark(state.* - 32);
        return null;
    }

    pub fn response(
        _: Trace,
        context: *TestContext,
        state: *State,
        _: *TestResponse,
    ) AppError!void {
        context.state.mark(state.* + 1);
    }

    pub fn after(
        _: Trace,
        context: *const TestContext,
        state: *State,
        outcome: application.Outcome,
    ) void {
        context.state.mark(state.* + 2);
        context.state.last_transport = outcome.transport;
        context.state.last_mapped_error = outcome.mapped_error;
    }
};

fn userHandler(context: *TestContext) AppError!TestResponse {
    context.state.mark('H');
    const id = context.request.param("id") orelse unreachable;
    if (std.mem.eql(u8, id, "denied")) return error.Denied;
    return context.textBorrowed(.ok, id);
}

fn exactHead(context: *TestContext) TestResponse {
    context.state.mark('E');
    return context.empty(.no_content);
}

fn mapError(context: *TestContext, _: AppError) TestResponse {
    context.state.mark('M');
    return context.textStatic(.forbidden, "denied");
}

const TestApplication = application.Application(.{
    .State = TestState,
    .Error = AppError,
    .middleware = .{Trace{ .marker = 'a' }},
    .routes = .{
        route.group("/v1", .{Trace{ .marker = 'b' }}, .{
            route.configured(
                .get,
                "/users/:id",
                userHandler,
                .{Trace{ .marker = 'c' }},
                null,
            ),
            route.head("/exact", exactHead),
            route.get("/slash/", exactHead),
            route.get("/plain", exactHead),
        }),
    },
    .map_error = mapError,
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

test "selected route runs four phases in directional order" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/v1/users/42"),
        &output,
    );

    try std.testing.expectEqual(application.TransportOutcome.completed, result.transport);
    try std.testing.expectEqual(response.Status.ok, result.status);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "\r\n\r\n42"));
    try std.testing.expectEqualStrings("abcABCHdcbedc", state.written());
    try std.testing.expectEqualStrings("42", workspace.captures[0].value("/v1/users/42"));
    const state_start = @intFromPtr(&workspace.middleware_state);
    const state_end = state_start + workspace.middleware_state.len;
    try std.testing.expect(state.first_middleware_state >= state_start);
    try std.testing.expect(state.first_middleware_state < state_end);
    try std.testing.expect(!state.last_mapped_error);
}

test "typed handler errors map centrally before reverse phases" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/v1/users/denied"),
        &output,
    );

    try std.testing.expectEqual(response.Status.forbidden, result.status);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "\r\n\r\ndenied"));
    try std.testing.expectEqualStrings("abcABCHMdcbedc", state.written());
    try std.testing.expect(state.last_mapped_error);
}

test "method routing generates HEAD OPTIONS 405 501 404 and slash redirect" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;

    const head_result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("HEAD", "/v1/users/42"),
        &output,
    );
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        head_result.transport,
    );
    try std.testing.expect(!std.mem.endsWith(u8, head_result.bytes, "42"));

    state.reset();
    const options_result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("OPTIONS", "/v1/users/42"),
        &output,
    );
    try std.testing.expectEqual(response.Status.no_content, options_result.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        options_result.bytes,
        "allow: GET, HEAD, OPTIONS",
    ) != null);
    try std.testing.expectEqualStrings("aAbc", state.written());

    state.reset();
    const method_result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("DELETE", "/v1/users/42"),
        &output,
    );
    try std.testing.expectEqual(response.Status.method_not_allowed, method_result.status);

    state.reset();
    const unsupported = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("TRACE", "/v1/users/42"),
        &output,
    );
    try std.testing.expectEqual(response.Status.not_implemented, unsupported.status);

    state.reset();
    const missing = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/missing"),
        &output,
    );
    try std.testing.expectEqual(response.Status.not_found, missing.status);

    state.reset();
    const redirect = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/v1/slash"),
        &output,
    );
    try std.testing.expectEqual(response.Status.moved_permanently, redirect.status);
    try std.testing.expect(std.mem.indexOf(u8, redirect.bytes, "location: /v1/slash/") != null);

    state.reset();
    var empty_query = input("GET", "/v1/slash");
    empty_query.raw_query = "";
    const query_redirect = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        empty_query,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        query_redirect.bytes,
        "location: /v1/slash/?\r\n",
    ) != null);

    state.reset();
    var encoded_slash = input("GET", "/v1/plain/");
    encoded_slash.raw_path = "/v1/plain%2F";
    encoded_slash.raw_target = "/v1/plain%2F";
    const no_redirect = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        encoded_slash,
        &output,
    );
    try std.testing.expectEqual(response.Status.not_found, no_redirect.status);
}

test "explicit HEAD route wins and output preflight leaves caller buffer unchanged" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const exact = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("HEAD", "/v1/exact"),
        &output,
    );
    try std.testing.expectEqual(response.Status.no_content, exact.status);
    try std.testing.expect(std.mem.indexOfScalar(u8, state.written(), 'E') != null);

    state.reset();
    var tiny = [_]u8{0xa5} ** 8;
    const before = tiny;
    try std.testing.expectError(
        error.OutputTooSmall,
        TestApplication.serve(
            &state,
            &workspace,
            &route_workspace,
            input("GET", "/v1/users/42"),
            &tiny,
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &tiny);
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);
}

test "prepare defers after until one explicit completion" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const request = input("GET", "/v1/users/42");

    const prepared = try TestApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        request,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expectEqualStrings("abcABCHdcb", state.written());
    try std.testing.expectError(
        error.RequestAlreadyPending,
        TestApplication.prepare(&state, &workspace, &route_workspace, request, &output),
    );
    try std.testing.expectEqualStrings("abcABCHdcb", state.written());

    const completed = try TestApplication.complete(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.completed, completed.transport);
    try std.testing.expectEqualStrings("abcABCHdcbedc", state.written());
    try std.testing.expectError(error.NoPendingRequest, TestApplication.complete(&workspace));
    try std.testing.expectError(error.NoPendingRequest, TestApplication.abort(&workspace));
}

test "abort unwinds pending state and failed prepare leaves workspace reusable" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    const request = input("GET", "/v1/users/42");

    _ = try TestApplication.prepare(&state, &workspace, &route_workspace, request, &output);
    const aborted = try TestApplication.abort(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.aborted, aborted.transport);
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);

    state.reset();
    var tiny = [_]u8{0xa5} ** 8;
    try std.testing.expectError(
        error.OutputTooSmall,
        TestApplication.prepare(&state, &workspace, &route_workspace, request, &tiny),
    );
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);
    state.reset();
    _ = try TestApplication.prepare(&state, &workspace, &route_workspace, request, &output);
    _ = try TestApplication.complete(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.completed, state.last_transport);
}

test "HEAD completion reports suppression only after transport success" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    _ = try TestApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("HEAD", "/v1/users/42"),
        &output,
    );
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);
    const completed = try TestApplication.complete(&workspace);
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        completed.transport,
    );
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        state.last_transport,
    );
}

test "transport close intent emits the owned Connection field" {
    var state = TestState{};
    var workspace = TestApplication.Workspace{};
    var route_workspace: TestApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;
    var request = input("GET", "/v1/users/42");
    request.connection_close = true;

    const result = try TestApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        request,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "connection: close\r\n") != null);
}

const BareState = struct {};
const BareContext = application.Context(BareState, response.standard_head_limits);

fn bareHandler(context: *BareContext) BareContext.ResponseType {
    return context.textStatic(.ok, "bare");
}

const BareApplication = application.Application(.{
    .State = BareState,
    .routes = .{route.get("/", bareHandler)},
});

test "application with no middleware reserves no state bytes" {
    var state = BareState{};
    var workspace = BareApplication.Workspace{};
    var route_workspace: BareApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const result = try BareApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqual(@as(usize, 0), workspace.middleware_state.len);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "\r\n\r\nbare"));
}

const GuardState = struct {
    foreign: response.Workspace(response.standard_head_limits) = .{},
};
const GuardContext = application.Context(GuardState, response.standard_head_limits);
const GuardResponse = GuardContext.ResponseType;

fn foreignResponse(context: *GuardContext) GuardResponse {
    return GuardResponse.textStatic(&context.state.foreign, .ok, "foreign");
}

fn invalidResponse(context: *GuardContext) GuardResponse {
    var result = context.empty(.ok);
    result.status = @enumFromInt(100);
    return result;
}

const GuardApplication = application.Application(.{
    .State = GuardState,
    .routes = .{
        route.get("/foreign", foreignResponse),
        route.get("/invalid", invalidResponse),
    },
});

test "foreign and invalid responses become owned safe 500 responses" {
    var state = GuardState{};
    var workspace = GuardApplication.Workspace{};
    var route_workspace: GuardApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const cases = [_][]const u8{ "/foreign", "/invalid" };
    for (cases) |path| {
        const result = try GuardApplication.serve(
            &state,
            &workspace,
            &route_workspace,
            input("GET", path),
            &output,
        );
        try std.testing.expectEqual(response.Status.internal_server_error, result.status);
    }
}

const UnwindState = struct {
    outer_saw_sensitive: bool = false,
    mapped_error: bool = false,
};
const UnwindContext = application.Context(UnwindState, response.standard_head_limits);
const UnwindResponse = UnwindContext.ResponseType;

const UnwindMiddleware = struct {
    role: enum { outer, inner },

    pub const State = void;

    pub fn responsePhase(
        self: UnwindMiddleware,
        context: *UnwindContext,
        _: *State,
        value: *UnwindResponse,
    ) AppError!void {
        switch (self.role) {
            .inner => {
                value.setHeader("x-sensitive", "secret") catch unreachable;
                return error.Denied;
            },
            .outer => {
                context.state.outer_saw_sensitive =
                    value.headers.get("x-sensitive") != null;
            },
        }
    }

    pub const response = responsePhase;

    pub fn after(
        _: UnwindMiddleware,
        context: *const UnwindContext,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.mapped_error = outcome.mapped_error;
    }
};

fn unwindHandler(context: *UnwindContext) UnwindResponse {
    return context.textStatic(.ok, "original");
}

fn unwindMapError(context: *UnwindContext, _: AppError) UnwindResponse {
    return context.textStatic(.forbidden, "mapped");
}

const UnwindApplication = application.Application(.{
    .State = UnwindState,
    .Error = AppError,
    .middleware = .{
        UnwindMiddleware{ .role = .outer },
        UnwindMiddleware{ .role = .inner },
    },
    .routes = .{route.get("/", unwindHandler)},
    .map_error = unwindMapError,
});

test "response error replacement clears inner sensitive headers" {
    var state = UnwindState{};
    var workspace = UnwindApplication.Workspace{};
    var route_workspace: UnwindApplication.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const result = try UnwindApplication.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqual(response.Status.forbidden, result.status);
    try std.testing.expect(!state.outer_saw_sensitive);
    try std.testing.expect(state.mapped_error);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "x-sensitive") == null);
    try std.testing.expect(std.mem.endsWith(u8, result.bytes, "\r\n\r\nmapped"));
}

const StreamLayoutState = struct {};
const StreamLayoutContext = application.Context(
    StreamLayoutState,
    response.standard_head_limits,
);

fn LayoutProducer(comptime bytes: usize, comptime alignment: u29) type {
    return struct {
        storage: [bytes]u8 align(alignment),

        pub fn poll(
            _: *@This(),
            _: []u8,
            _: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            return .pending;
        }
    };
}

const LargeStreamProducer = LayoutProducer(65, 1);
const AlignedStreamProducer = LayoutProducer(1, 32);
const ZeroStreamProducer = LayoutProducer(0, 1);

fn finiteLayoutHandler(context: *StreamLayoutContext) StreamLayoutContext.ResponseType {
    return context.empty(.ok);
}

fn largeLayoutHandler(
    _: *StreamLayoutContext,
) StreamLayoutContext.StreamResponse(LargeStreamProducer) {
    unreachable;
}

fn alignedLayoutHandler(
    _: *StreamLayoutContext,
) StreamLayoutContext.StreamResponse(AlignedStreamProducer) {
    unreachable;
}

fn zeroLayoutHandler(
    _: *StreamLayoutContext,
) StreamLayoutContext.StreamResponse(ZeroStreamProducer) {
    unreachable;
}

const FiniteLayoutApplication = application.Application(.{
    .State = StreamLayoutState,
    .routes = .{route.get("/", finiteLayoutHandler)},
});

const NestedStreamLayoutApplication = application.Application(.{
    .State = StreamLayoutState,
    .routes = .{route.group("/nested", .{}, .{
        route.get("/large", largeLayoutHandler),
        route.get("/aligned", alignedLayoutHandler),
    })},
});

const ZeroStreamLayoutApplication = application.Application(.{
    .State = StreamLayoutState,
    .routes = .{route.get("/", zeroLayoutHandler)},
});

test "Application workspace derives exact conditional stream storage" {
    try std.testing.expect(!FiniteLayoutApplication.stream_enabled);
    try std.testing.expectEqual(@as(usize, 0), FiniteLayoutApplication.stream_producer_bytes_max);
    try std.testing.expectEqual(
        @as(usize, 0),
        FiniteLayoutApplication.stream_producer_alignment_max,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(FiniteLayoutApplication.Workspace, "stream")),
    );
    try std.testing.expect(!@hasField(FiniteLayoutApplication.Workspace, "stream_wake"));

    try std.testing.expect(NestedStreamLayoutApplication.stream_enabled);
    try std.testing.expectEqual(
        @sizeOf(LargeStreamProducer),
        NestedStreamLayoutApplication.stream_producer_bytes_max,
    );
    try std.testing.expectEqual(
        @alignOf(AlignedStreamProducer),
        NestedStreamLayoutApplication.stream_producer_alignment_max,
    );
    const NestedStorage = @FieldType(NestedStreamLayoutApplication.Workspace, "stream");
    try std.testing.expect(@sizeOf(NestedStorage) >= @sizeOf(LargeStreamProducer));
    try std.testing.expectEqual(@alignOf(AlignedStreamProducer), @alignOf(NestedStorage));

    try std.testing.expect(ZeroStreamLayoutApplication.stream_enabled);
    try std.testing.expectEqual(
        @as(usize, 0),
        ZeroStreamLayoutApplication.stream_producer_bytes_max,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        ZeroStreamLayoutApplication.stream_producer_alignment_max,
    );
    try std.testing.expect(
        @sizeOf(@FieldType(ZeroStreamLayoutApplication.Workspace, "stream")) > 0,
    );
}

const std = @import("std");
const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

const TestState = struct {
    events: [32]u8 = undefined,
    events_len: usize = 0,
    handler_calls: u8 = 0,
    after_calls: u8 = 0,
    last_transport: application.TransportOutcome = .completed,
    tiny_state_ok: bool = false,
    aligned_state_ok: bool = false,

    fn mark(state: *TestState, byte: u8) void {
        state.events[state.events_len] = byte;
        state.events_len += 1;
    }

    fn written(state: *const TestState) []const u8 {
        return state.events[0..state.events_len];
    }

    fn reset(state: *TestState) void {
        state.events_len = 0;
        state.handler_calls = 0;
        state.after_calls = 0;
        state.last_transport = .completed;
    }
};

const TestContext = application.Context(TestState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;

const PhaseMiddleware = struct {
    head_mark: u8,
    body_mark: u8,
    response_mark: u8,
    after_mark: u8,
    head_short: bool = false,
    body_short: bool = false,

    pub const State = u8;

    pub fn init(self: PhaseMiddleware) State {
        return self.head_mark;
    }

    pub fn head(
        self: PhaseMiddleware,
        context: *TestContext,
        state: *State,
    ) ?TestResponse {
        std.debug.assert(state.* == self.head_mark);
        context.state.mark(state.*);
        if (self.head_short) return context.empty(.ok);
        return null;
    }

    pub fn body(
        self: PhaseMiddleware,
        context: *TestContext,
        _: *State,
        _: application.Bodyless,
    ) ?TestResponse {
        context.state.mark(self.body_mark);
        if (self.body_short) return context.empty(.ok);
        return null;
    }

    pub fn responsePhase(
        self: PhaseMiddleware,
        context: *TestContext,
        _: *State,
        _: *TestResponse,
    ) void {
        context.state.mark(self.response_mark);
    }

    pub const response = responsePhase;

    pub fn after(
        self: PhaseMiddleware,
        context: *const TestContext,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.mark(self.after_mark);
        context.state.after_calls += 1;
        context.state.last_transport = outcome.transport;
    }
};

const phase_a = PhaseMiddleware{
    .head_mark = 'a',
    .body_mark = 'A',
    .response_mark = 'r',
    .after_mark = 'x',
};
const phase_b = PhaseMiddleware{
    .head_mark = 'b',
    .body_mark = 'B',
    .response_mark = 's',
    .after_mark = 'y',
};

fn handler(context: *TestContext) TestResponse {
    context.state.handler_calls += 1;
    context.state.mark('H');
    return context.textStatic(.ok, "ok");
}

const LifecycleApp = application.Application(.{
    .State = TestState,
    .middleware = .{phase_a},
    .routes = .{route.get("/", handler)},
});

const HeadShortApp = application.Application(.{
    .State = TestState,
    .middleware = .{
        PhaseMiddleware{
            .head_mark = 'a',
            .body_mark = 'A',
            .response_mark = 'r',
            .after_mark = 'x',
            .head_short = true,
        },
        phase_b,
    },
    .routes = .{route.get("/", handler)},
});

const BodyShortApp = application.Application(.{
    .State = TestState,
    .middleware = .{
        PhaseMiddleware{
            .head_mark = 'a',
            .body_mark = 'A',
            .response_mark = 'r',
            .after_mark = 'x',
            .body_short = true,
        },
        phase_b,
    },
    .routes = .{route.get("/", handler)},
});

const TinyMiddleware = struct {
    pub const State = u16;

    pub fn init(_: TinyMiddleware) State {
        return 0x1234;
    }

    pub fn head(_: TinyMiddleware, context: *TestContext, state: *State) ?TestResponse {
        context.state.tiny_state_ok = state.* == 0x1234;
        return null;
    }
};

const AlignedMiddleware = struct {
    pub const State = struct {
        marker: u8 align(64),
    };

    pub fn init(_: AlignedMiddleware) State {
        return .{ .marker = 0xa5 };
    }

    pub fn head(_: AlignedMiddleware, context: *TestContext, state: *State) ?TestResponse {
        context.state.aligned_state_ok = state.marker == 0xa5 and
            @intFromPtr(state) % @alignOf(State) == 0;
        return null;
    }
};

const AlignedApp = application.Application(.{
    .State = TestState,
    .middleware = .{ TinyMiddleware{}, AlignedMiddleware{} },
    .routes = .{route.get("/", handler)},
});

const RedirectApp = application.Application(.{
    .State = TestState,
    .routes = .{
        route.get("/head/", handler),
        route.post("/post/", handler),
    },
});

const profile_max = response.HeadLimits{
    .head_bytes_max = 512,
    .field_line_bytes_max = 256,
    .fields_max = 4,
};
const fields_two = response.HeadLimits{
    .head_bytes_max = 512,
    .field_line_bytes_max = 256,
    .fields_max = 2,
};
const fields_three = response.HeadLimits{
    .head_bytes_max = 512,
    .field_line_bytes_max = 256,
    .fields_max = 3,
};
const ProfileContext = application.Context(TestState, profile_max);
const ProfileResponse = ProfileContext.ResponseType;

fn profileHandler(context: *ProfileContext) ProfileResponse {
    return context.empty(.no_content);
}

const SmallerProfileApp = application.Application(.{
    .State = TestState,
    .response_workspace_limits = profile_max,
    .response_head_limits = profile_max,
    .routes = .{route.configured(.get, "/small/", profileHandler, .{}, fields_two)},
});

const LargerProfileApp = application.Application(.{
    .State = TestState,
    .response_workspace_limits = profile_max,
    .response_head_limits = fields_two,
    .routes = .{route.configured(.get, "/large/", profileHandler, .{}, fields_three)},
});

const HiddenError = error{SecretInternalFailure};

fn failingHandler(_: *TestContext) HiddenError!TestResponse {
    return error.SecretInternalFailure;
}

const DefaultMapperApp = application.Application(.{
    .State = TestState,
    .Error = HiddenError,
    .routes = .{route.get("/", failingHandler)},
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

test "prepare defers after and lifecycle misuse is deterministic" {
    var state = TestState{};
    var workspace = LifecycleApp.Workspace{};
    var route_workspace = LifecycleApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    try std.testing.expectError(error.NoPendingRequest, LifecycleApp.complete(&workspace));
    const prepared = try LifecycleApp.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expectEqualStrings("aAHr", state.written());
    try std.testing.expectEqual(@as(u8, 0), state.after_calls);
    try std.testing.expectError(
        error.RequestAlreadyPending,
        LifecycleApp.prepare(&state, &workspace, &route_workspace, input("GET", "/"), &output),
    );

    const completed = try LifecycleApp.complete(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.completed, completed.transport);
    try std.testing.expectEqualStrings("aAHrx", state.written());
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectError(error.NoPendingRequest, LifecycleApp.complete(&workspace));
    try std.testing.expectError(error.NoPendingRequest, LifecycleApp.abort(&workspace));

    state.reset();
    _ = try LifecycleApp.prepare(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    const aborted = try LifecycleApp.abort(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.aborted, aborted.transport);
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);
    try std.testing.expectEqualStrings("aAHrx", state.written());
}

test "head and body short circuits unwind only initialized middleware" {
    var state = TestState{};
    var head_workspace = HeadShortApp.Workspace{};
    var head_route_workspace = HeadShortApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    _ = try HeadShortApp.prepare(
        &state,
        &head_workspace,
        &head_route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqualStrings("ar", state.written());
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    _ = try HeadShortApp.complete(&head_workspace);
    try std.testing.expectEqualStrings("arx", state.written());

    state.reset();
    var body_workspace = BodyShortApp.Workspace{};
    var body_route_workspace = BodyShortApp.RouteSearchWorkspace{};
    _ = try BodyShortApp.prepare(
        &state,
        &body_workspace,
        &body_route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqualStrings("abAsr", state.written());
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    _ = try BodyShortApp.complete(&body_workspace);
    try std.testing.expectEqualStrings("abAsryx", state.written());
}

test "heterogeneous middleware state preserves over-alignment" {
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AlignedMiddleware.State));
    var state = TestState{};
    var workspace = AlignedApp.Workspace{};
    var route_workspace = AlignedApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    _ = try AlignedApp.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expect(state.tiny_state_ok);
    try std.testing.expect(state.aligned_state_ok);
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(&workspace.middleware_state) % @alignOf(AlignedMiddleware.State),
    );
}

test "redirect method and matched route response profiles are exact" {
    var state = TestState{};
    var workspace = RedirectApp.Workspace{};
    var route_workspace = RedirectApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    const head_result = try RedirectApp.serve(
        &state,
        &workspace,
        &route_workspace,
        input("HEAD", "/head"),
        &output,
    );
    try std.testing.expectEqual(response.Status.temporary_redirect, head_result.status);
    try std.testing.expectEqual(
        application.TransportOutcome.head_suppressed,
        head_result.transport,
    );
    try std.testing.expect(std.mem.indexOf(u8, head_result.bytes, "location: /head/") != null);

    const post_result = try RedirectApp.serve(
        &state,
        &workspace,
        &route_workspace,
        input("POST", "/post"),
        &output,
    );
    try std.testing.expectEqual(response.Status.temporary_redirect, post_result.status);
    try std.testing.expect(std.mem.indexOf(u8, post_result.bytes, "location: /post/") != null);

    var smaller_workspace = SmallerProfileApp.Workspace{};
    var smaller_route_workspace = SmallerProfileApp.RouteSearchWorkspace{};
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        SmallerProfileApp.prepare(
            &state,
            &smaller_workspace,
            &smaller_route_workspace,
            input("GET", "/small"),
            &output,
        ),
    );
    const options = try SmallerProfileApp.serve(
        &state,
        &smaller_workspace,
        &smaller_route_workspace,
        input("OPTIONS", "/small"),
        &output,
    );
    try std.testing.expectEqual(response.Status.temporary_redirect, options.status);
    try std.testing.expect(std.mem.indexOf(u8, options.bytes, "location: /small/") != null);

    var larger_workspace = LargerProfileApp.Workspace{};
    var larger_route_workspace = LargerProfileApp.RouteSearchWorkspace{};
    const larger = try LargerProfileApp.serve(
        &state,
        &larger_workspace,
        &larger_route_workspace,
        input("GET", "/large"),
        &output,
    );
    try std.testing.expectEqual(response.Status.moved_permanently, larger.status);
    try std.testing.expect(std.mem.indexOf(u8, larger.bytes, "location: /large/") != null);
}

test "serialization failure aborts unwind and leaves workspace reusable" {
    var state = TestState{};
    var workspace = LifecycleApp.Workspace{};
    var route_workspace = LifecycleApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;
    var invalid = input("GET", "/");
    invalid.date = "invalid\r\ndate";

    try std.testing.expectError(
        error.InvalidDate,
        LifecycleApp.prepare(&state, &workspace, &route_workspace, invalid, &output),
    );
    try std.testing.expectEqualStrings("aAHrx", state.written());
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.last_transport);

    state.reset();
    const reused = try LifecycleApp.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, reused.status);
    try std.testing.expectEqual(application.TransportOutcome.completed, state.last_transport);
}

test "default error mapper returns generic 500 without error detail" {
    var state = TestState{};
    var workspace = DefaultMapperApp.Workspace{};
    var route_workspace = DefaultMapperApp.RouteSearchWorkspace{};
    var output: [512]u8 = undefined;

    const result = try DefaultMapperApp.serve(
        &state,
        &workspace,
        &route_workspace,
        input("GET", "/"),
        &output,
    );
    try std.testing.expectEqual(response.Status.internal_server_error, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "SecretInternalFailure") == null);
}

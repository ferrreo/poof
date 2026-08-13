const std = @import("std");
const body = @import("../../src/body.zig");
const response = @import("../../src/response.zig");
const response_gzip = @import("../../src/response/gzip.zig");
const response_stream = @import("../../src/response/stream.zig");
const application_context = @import("../../src/application/context.zig");
const application_compile = @import("../../src/internal/application/compile.zig");
const application_pipeline = @import("../../src/internal/application/pipeline.zig");
const application_response_output = @import("../../src/internal/application/response_output.zig");
const application_types = @import("../../src/internal/application/types.zig");
const response_stream_erasure = @import("../../src/internal/response/stream_erasure.zig");

const limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 12,
});
const smaller_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 256,
    .field_line_bytes_max = 64,
    .fields_max = 6,
});
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const AppError = error{Denied};
const ResponseWorkspace = response.Workspace(limits);

const Counts = struct {
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
};

const State = struct {
    producer: Counts = .{},
    foreign: ResponseWorkspace = .{},
    outer_finite: u8 = 0,
    outer_stream: u8 = 0,
    after_calls: u8 = 0,
    after_status: ?response.Status = null,
    after_transport: application_types.TransportOutcome = .completed,
};

const Context = application_context.Context(State, limits);
const FiniteResponse = Context.ResponseType;

const Producer = struct {
    counts: *Counts,

    pub fn poll(
        self: *@This(),
        _: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.counts.polls += 1;
        return .pending;
    }

    pub fn abort(self: *@This()) void {
        self.counts.aborts += 1;
    }

    pub fn join(self: *@This()) void {
        self.counts.joins += 1;
    }
};

const StreamResponse = Context.StreamResponse(Producer);
const Output = application_response_output.Configured(
    false,
    limits,
    response_gzip.ResponseGzip{},
);
const Pipeline = application_pipeline.Pipeline(
    Context,
    FiniteResponse,
    AppError,
    mapError,
    application_types.Outcome,
    Output,
);

const Role = enum {
    outer,
    vary,
    fail,
    invalid_status,
    foreign,
    limits,
    after_only,
};

const Middleware = struct {
    role: Role,

    pub const State = void;

    pub fn responsePhase(
        self: @This(),
        context: *Context,
        _: *void,
        value: anytype,
    ) AppError!void {
        switch (self.role) {
            .outer => if (@TypeOf(value.*) == FiniteResponse) {
                context.state.outer_finite += 1;
            } else {
                context.state.outer_stream += 1;
            },
            .vary => value.setHeader("Vary", "Accept-Language") catch unreachable,
            .fail => return error.Denied,
            .invalid_status => value.status = .no_content,
            .foreign => value.headers = &context.state.foreign.headers,
            .limits => value.headers.reset(smaller_limits),
            .after_only => {},
        }
    }

    pub const response = responsePhase;

    pub fn after(
        _: @This(),
        context: *const Context,
        _: *void,
        outcome: application_types.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.after_status = outcome.status;
        context.state.after_transport = outcome.transport;
    }
};

fn mapError(context: *Context, _: AppError) FiniteResponse {
    return context.textStatic(.forbidden, "mapped");
}

fn unknownHandler(context: *Context) StreamResponse {
    return context.streamUnknown(
        .ok,
        response.media.text,
        Producer{ .counts = &context.state.producer },
        &.{"digest"},
    );
}

fn exactHandler(context: *Context) StreamResponse {
    return context.streamExact(
        .ok,
        response.media.text,
        17,
        Producer{ .counts = &context.state.producer },
    );
}

fn failingHandler(_: *Context) AppError!StreamResponse {
    return error.Denied;
}

fn WorkspaceFor(comptime middleware: anytype) type {
    const States = application_compile.StateTuple(middleware);
    return struct {
        response: ResponseWorkspace = .{},
        response_gzip: Output.Binding = .{},
        cors_fields: application_context.CorsStorage(false) = .{},
        stream: response_stream_erasure.Erased(@sizeOf(Producer), @alignOf(Producer)) = undefined,
        response_head_bytes: [limits.head_bytes_max]u8 = undefined,
        middleware_state: [@sizeOf(States)]u8 align(@alignOf(States)) = undefined,
        initialized_middleware: u64 = 0,
        context: Context = undefined,
        pending: application_types.Pending = undefined,
        lifecycle: application_types.Lifecycle = .idle,
    };
}

fn input(method: []const u8) application_context.Input {
    return .{
        .method = method,
        .path = "/",
        .raw_target = "/",
        .raw_path = "/",
        .date = fixed_date,
    };
}

fn begin(
    comptime middleware: anytype,
    state: *State,
    workspace: anytype,
    request_input: application_context.Input,
) !void {
    workspace.response.reset(limits);
    workspace.lifecycle = .preparing;
    workspace.context = .{
        .state = state,
        .request = .{
            .method = request_input.method,
            .raw_target = request_input.raw_target,
            .raw_path = request_input.raw_path,
            .path = request_input.path,
            .raw_query = request_input.raw_query,
        },
        .response_workspace = &workspace.response,
    };
    const States = application_compile.StateTuple(middleware);
    const states: *States = @ptrCast(&workspace.middleware_state);
    workspace.initialized_middleware = 0;
    var mapped_error = false;
    try std.testing.expect(Pipeline.runHeadPhases(
        middleware,
        &workspace.context,
        states,
        &workspace.initialized_middleware,
        &mapped_error,
        .none,
    ) == null);
    try std.testing.expect(!mapped_error);
}

fn prepare(
    comptime middleware: anytype,
    comptime handler: anytype,
    state: *State,
    workspace: anytype,
    request_input: application_context.Input,
    output: []u8,
) !application_response_output.Prepared {
    try begin(middleware, state, workspace, request_input);
    return Pipeline.runSelectedBodyResponse(
        middleware,
        handler,
        body.None{},
        {},
        {},
        application_types.PendingRoute{ .selected = 0 },
        limits,
        limits,
        &workspace.context,
        workspace,
        request_input,
        output,
        null,
    );
}

fn expectFinite(value: application_response_output.Transmission) !void {
    switch (value) {
        .finite => {},
        .stream => return error.TestExpectedEqual,
    }
}

test "stream success prepares identity transmission without polling" {
    const middleware = .{Middleware{ .role = .vary }};
    const Workspace = WorkspaceFor(middleware);
    var state = State{};
    var workspace = Workspace{};
    var output: [1024]u8 = undefined;
    var request_input = input("GET");
    request_input.accepts_response_trailers = true;
    const result = try prepare(
        middleware,
        unknownHandler,
        &state,
        &workspace,
        request_input,
        &output,
    );

    const transmission = result.transmission.stream;
    try std.testing.expect(transmission.framing.invoke_stream);
    try std.testing.expect(transmission.framing.framing == .chunked);
    try std.testing.expect(transmission.trailers.emitted);
    try std.testing.expectEqual(
        application_response_output.CodingOutcome.identity_negotiated,
        result.coding_outcome,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "vary: Accept-Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "vary: Accept-Encoding") != null);
    try std.testing.expectEqual(Counts{}, state.producer);
    try std.testing.expectEqual(
        application_types.PendingTransmission.stream,
        workspace.pending.transmission,
    );
    try std.testing.expectEqual(application_types.Lifecycle.pending, workspace.lifecycle);
    try workspace.stream.abort();
    try workspace.stream.join();
}

test "stream middleware error disposes producer then continues finite" {
    const middleware = .{
        Middleware{ .role = .outer },
        Middleware{ .role = .fail },
    };
    const Workspace = WorkspaceFor(middleware);
    var state = State{};
    var workspace = Workspace{};
    var output: [1024]u8 = undefined;
    const result = try prepare(
        middleware,
        unknownHandler,
        &state,
        &workspace,
        input("GET"),
        &output,
    );

    try expectFinite(result.transmission);
    try std.testing.expectEqual(response.Status.forbidden, result.status);
    try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, state.producer);
    try std.testing.expectEqual(@as(u8, 1), state.outer_finite);
    try std.testing.expectEqual(@as(u8, 0), state.outer_stream);
    try std.testing.expect(workspace.pending.mapped_error);
    try std.testing.expectEqual(
        application_types.PendingTransmission.finite,
        workspace.pending.transmission,
    );
    try std.testing.expectEqual(.joined, workspace.stream.phase());
}

test "stream middleware invalidity disposes producer and maps safe finite" {
    inline for (.{ Role.invalid_status, Role.foreign, Role.limits }) |role| {
        const middleware = .{
            Middleware{ .role = .outer },
            Middleware{ .role = role },
        };
        const Workspace = WorkspaceFor(middleware);
        var state = State{};
        var workspace = Workspace{};
        var output: [1024]u8 = undefined;
        const result = try prepare(
            middleware,
            unknownHandler,
            &state,
            &workspace,
            input("GET"),
            &output,
        );

        try expectFinite(result.transmission);
        try std.testing.expectEqual(response.Status.internal_server_error, result.status);
        try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, state.producer);
        try std.testing.expectEqual(@as(u8, 1), state.outer_finite);
        try std.testing.expectEqual(@as(u8, 0), state.outer_stream);
        try std.testing.expect(workspace.pending.mapped_error);
        try std.testing.expectEqual(.joined, workspace.stream.phase());
    }
}

test "stream handler error maps finite before response middleware" {
    const middleware = .{Middleware{ .role = .outer }};
    const Workspace = WorkspaceFor(middleware);
    var state = State{};
    var workspace = Workspace{};
    var output: [1024]u8 = undefined;
    const result = try prepare(
        middleware,
        failingHandler,
        &state,
        &workspace,
        input("GET"),
        &output,
    );

    try expectFinite(result.transmission);
    try std.testing.expectEqual(response.Status.forbidden, result.status);
    try std.testing.expectEqual(Counts{}, state.producer);
    try std.testing.expectEqual(@as(u8, 1), state.outer_finite);
    try std.testing.expect(workspace.pending.mapped_error);
}

test "stream serialization failure aborts joins unwinds and idles" {
    const middleware = .{Middleware{ .role = .after_only }};
    const Workspace = WorkspaceFor(middleware);
    var state = State{};
    var workspace = Workspace{};
    var output: [8]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.OutputTooSmall,
        prepare(
            middleware,
            unknownHandler,
            &state,
            &workspace,
            input("GET"),
            &output,
        ),
    );

    try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, state.producer);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(@as(?response.Status, null), state.after_status);
    try std.testing.expectEqual(application_types.TransportOutcome.aborted, state.after_transport);
    try std.testing.expectEqual(application_types.Lifecycle.idle, workspace.lifecycle);
    try std.testing.expectEqual(.joined, workspace.stream.phase());
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 8), &output);
}

test "HEAD and identity rejection retain stream suppression plans" {
    const middleware = .{};
    const Workspace = WorkspaceFor(middleware);
    var output: [1024]u8 = undefined;

    var head_state = State{};
    var head_workspace = Workspace{};
    const head = try prepare(
        middleware,
        exactHandler,
        &head_state,
        &head_workspace,
        input("HEAD"),
        &output,
    );
    try std.testing.expect(!head.transmission.stream.framing.invoke_stream);
    try std.testing.expectEqual(@as(u64, 17), head.transmission.stream.framing.framing.fixed);
    try std.testing.expectEqual(
        application_types.TransportOutcome.head_suppressed,
        head_workspace.pending.success_transport,
    );
    try std.testing.expectEqual(Counts{}, head_state.producer);
    try head_workspace.stream.suppress();
    try std.testing.expectEqual(Counts{ .joins = 1 }, head_state.producer);

    var rejected_state = State{};
    var rejected_workspace = Workspace{};
    var rejected_input = input("GET");
    rejected_input.accept_encoding = .{ .gzip = 1000, .identity = 0 };
    const rejected = try prepare(
        middleware,
        unknownHandler,
        &rejected_state,
        &rejected_workspace,
        rejected_input,
        &output,
    );
    try std.testing.expectEqual(response.Status.not_acceptable, rejected.status);
    try std.testing.expectEqual(
        application_response_output.CodingOutcome.not_acceptable,
        rejected.coding_outcome,
    );
    try std.testing.expect(!rejected.transmission.stream.framing.invoke_stream);
    try std.testing.expect(
        std.mem.indexOf(u8, rejected.bytes, "vary: Accept-Encoding") != null,
    );
    try std.testing.expect(rejected.close_connection);
    try std.testing.expectEqual(
        application_types.PendingTransmission.stream,
        rejected_workspace.pending.transmission,
    );
    try std.testing.expectEqual(Counts{}, rejected_state.producer);
    try rejected_workspace.stream.suppress();
    try std.testing.expectEqual(Counts{ .joins = 1 }, rejected_state.producer);
}

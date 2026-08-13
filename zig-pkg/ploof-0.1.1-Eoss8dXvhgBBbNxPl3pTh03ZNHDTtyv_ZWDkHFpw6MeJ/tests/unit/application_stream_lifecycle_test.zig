const std = @import("std");
const application = @import("../../src/application.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const route = @import("../../src/route.zig");

const StreamLifecycleCounts = struct {
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
};

const StreamLifecycleState = struct {
    counts: StreamLifecycleCounts = .{},
    after_calls: u8 = 0,
    after_transport: application.TransportOutcome = .completed,
};

const StreamLifecycleContext = application.Context(
    StreamLifecycleState,
    response.standard_head_limits,
);

const StreamLifecycleProducer = struct {
    counts: *StreamLifecycleCounts,

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

const StreamLifecycleMiddleware = struct {
    pub const State = void;

    pub fn after(
        _: @This(),
        context: *const StreamLifecycleContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.after_transport = outcome.transport;
    }
};

fn streamLifecycleHandler(
    context: *StreamLifecycleContext,
) StreamLifecycleContext.StreamResponse(StreamLifecycleProducer) {
    return context.streamUnknown(
        .ok,
        response.media.text,
        StreamLifecycleProducer{ .counts = &context.state.counts },
        &.{},
    );
}

const StreamLifecycleApplication = application.Application(.{
    .State = StreamLifecycleState,
    .middleware = .{StreamLifecycleMiddleware{}},
    .routes = .{route.get("/", streamLifecycleHandler)},
});

fn input() application.Input {
    return .{
        .method = "GET",
        .path = "/",
        .raw_target = "/",
        .raw_path = "/",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

test "stream lifecycle preserves transport failure and synchronous serve unwinds" {
    var state = StreamLifecycleState{};
    var workspace = StreamLifecycleApplication.Workspace{};
    var route_workspace: StreamLifecycleApplication.RouteSearchWorkspace = undefined;
    var output: [2048]u8 = undefined;

    const prepared = try StreamLifecycleApplication.prepare(
        &state,
        &workspace,
        &route_workspace,
        input(),
        &output,
    );
    try std.testing.expect(prepared.transmission == .stream);
    try std.testing.expectEqual(StreamLifecycleCounts{}, state.counts);
    try std.testing.expectError(
        error.StreamNotJoined,
        StreamLifecycleApplication.complete(&workspace),
    );
    try std.testing.expectEqual(.pending, workspace.lifecycle);
    const aborted = try StreamLifecycleApplication.__abortWithTransport(
        &workspace,
        .exact_underrun,
    );
    try std.testing.expectEqual(application.TransportOutcome.exact_underrun, aborted.transport);
    try std.testing.expectEqual(
        application.TransportOutcome.exact_underrun,
        state.after_transport,
    );
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(
        StreamLifecycleCounts{ .aborts = 1, .joins = 1 },
        state.counts,
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);

    state = .{};
    try std.testing.expectError(
        error.StreamingRequiresTransport,
        StreamLifecycleApplication.serve(
            &state,
            &workspace,
            &route_workspace,
            input(),
            &output,
        ),
    );
    try std.testing.expectEqual(
        StreamLifecycleCounts{ .aborts = 1, .joins = 1 },
        state.counts,
    );
    try std.testing.expectEqual(application.TransportOutcome.aborted, state.after_transport);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(.idle, workspace.lifecycle);
}

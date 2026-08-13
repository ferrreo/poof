const std = @import("std");

const application = @import("../../src/application.zig");
const event_counter = @import("../../src/internal/runtime/event_counter.zig");
const health = @import("../../src/health.zig");
const lifecycle = @import("../../src/lifecycle.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const server_command = @import("../../src/internal/runtime/server/command.zig");
const server_runtime = @import("../../src/server.zig");
const server_startup = @import("../../src/server/startup.zig");
const server_types = @import("../../src/server/types.zig");
const server_worker = @import("../../src/internal/runtime/server/worker.zig");

const State = struct {};
const Context = application.Context(State, response.standard_head_limits);
const Handler = struct {
    fn ping(context: *Context) Context.ResponseType {
        return context.textStatic(.ok, "pong");
    }
};
const App = application.Application(.{
    .State = State,
    .routes = .{route.get("/ping", Handler.ping)},
});
const ControlServer = server_runtime.Server(App, .{ .workers_max = 2 });

var control_server: ControlServer align(@alignOf(ControlServer)) = undefined;

const ReadyState = struct { readiness: lifecycle.Readiness = .{} };
const ReadyContext = application.Context(ReadyState, response.standard_head_limits);
const ReadyAccess = struct {
    fn binding(state: *ReadyState) *const lifecycle.Readiness {
        return &state.readiness;
    }
};
const ReadyHandler = health.Readiness(ReadyContext, ReadyAccess.binding);
const ReadyApp = application.Application(.{
    .State = ReadyState,
    .routes = .{route.get("/ready", ReadyHandler.handle)},
});
const ReadyServer = server_runtime.Server(ReadyApp, .{ .limits = .{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 1024,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 4096,
    .response_chunk_count = 2,
    .submission_entries = 32,
    .completion_entries = 64,
} });

var failed_readiness_server: ReadyServer align(@alignOf(ReadyServer)) = undefined;
var readiness_server: ReadyServer align(@alignOf(ReadyServer)) = undefined;
const SlabTestStorage = struct {
    marker: u8 = 0,
    pub const required_bytes = 9;
    pub const slab_alignment = 64;
};
const SlabTestNode = struct {
    storage: SlabTestStorage,
    slab: [SlabTestStorage.required_bytes + SlabTestStorage.slab_alignment - 1]u8,
};
const UnalignedSlabNodeBuffer =
    [@sizeOf(SlabTestNode) + SlabTestStorage.slab_alignment]u8;
const slab_test_alignment = SlabTestStorage.slab_alignment;
var unaligned_slab_node_storage: UnalignedSlabNodeBuffer align(slab_test_alignment) = undefined;

test "server options preserve fixed compile-time capacity and stack bounds" {
    try std.testing.expectEqual(@as(u16, 2), ControlServer.compiled_options.workers_max);
    try std.testing.expect(@hasDecl(ControlServer, "start"));
    _ = server_runtime.Server(App, .{
        .worker_thread_stack_bytes = server_types.minimum_worker_thread_stack_bytes,
    });
    _ = server_runtime.Server(App, .{
        .worker_thread_stack_bytes = server_types.maximum_worker_thread_stack_bytes,
    });
}

test "server aligns worker slab independently of caller-owned server address" {
    const node: *align(1) SlabTestNode = @ptrCast(unaligned_slab_node_storage[1..].ptr);
    const slab = server_worker.workerSlab(node);
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(slab.ptr) % SlabTestStorage.slab_alignment,
    );
    try std.testing.expectEqual(SlabTestStorage.required_bytes, slab.len);
}

test "pre-start control is typed and failed fanout retries every worker" {
    control_server.shutdown_mutex = .{};
    control_server.start_attempted = .init(false);
    try std.testing.expectError(error.ServerNotRunning, control_server.beginDrain());
    try std.testing.expectError(error.ServerNotRunning, control_server.beginForced());

    control_server.lifecycle_controller = .{};
    _ = control_server.lifecycle_controller.markReady();
    control_server.commands_ready = .init(true);
    control_server.shutdown_deadlines_set = .init(false);
    control_server.grace_deadline_ns = .init(0);
    control_server.force_deadline_ns = .init(0);
    control_server.shutdown_profile = .{};
    control_server.start_attempted.store(true, .release);
    control_server.address_identity = @intFromPtr(&control_server);
    control_server.thread_count = 2;
    control_server.configured_count = 2;
    for (control_server.nodes[0..2]) |*node| {
        node.status = .init(.initializing);
        node.command = try server_command.Channel.init(0);
    }
    defer for (control_server.nodes[0..2]) |*node| node.command.abortAfterBackend();

    event_counter.TestAccess.failNextSignal();
    try std.testing.expectError(error.EventCounterSignalFailed, control_server.beginDrain());
    const grace_deadline = control_server.grace_deadline_ns.load(.acquire);
    const force_deadline = control_server.force_deadline_ns.load(.acquire);
    try std.testing.expectEqual(lifecycle.DrainStage.grace, control_server.drainStage());
    try std.testing.expectEqual(
        lifecycle.Transition.unchanged,
        try control_server.beginDrain(),
    );
    try expectOneSignal(&control_server.nodes[0].command);
    try expectOneSignal(&control_server.nodes[1].command);
    try std.testing.expectEqual(grace_deadline, control_server.grace_deadline_ns.load(.acquire));
    try std.testing.expectEqual(force_deadline, control_server.force_deadline_ns.load(.acquire));
}

test "server binds exact readiness only after startup and clears it on drain" {
    var state = ReadyState{};
    var workspace = response.Workspace(response.standard_head_limits){};
    var context = ReadyContext{
        .state = &state,
        .request = undefined,
        .response_workspace = &workspace,
    };
    try std.testing.expectEqual(
        .service_unavailable,
        ReadyHandler.handle(&context).status,
    );

    failed_readiness_server = ReadyServer.init();
    var metrics_snapshot = ReadyServer.MetricsSnapshot{};
    try std.testing.expectError(
        error.ServerNotReady,
        failed_readiness_server.metricsSnapshot(0, &metrics_snapshot),
    );
    switch (failed_readiness_server.start(&state, .{
        .worker_count = 0,
        .readiness = &state.readiness,
    })) {
        .failure => |failure| switch (failure) {
            .configuration => |issue| try std.testing.expectEqual(
                server_startup.ConfigurationIssue.worker_count_zero,
                issue,
            ),
            else => return error.UnexpectedStartupFailure,
        },
        .ready => return error.UnexpectedStartupSuccess,
    }
    try std.testing.expectError(
        error.ServerNotReady,
        failed_readiness_server.metricsSnapshot(0, &metrics_snapshot),
    );
    try std.testing.expectEqual(
        .service_unavailable,
        ReadyHandler.handle(&context).status,
    );

    readiness_server = ReadyServer.init();
    switch (readiness_server.start(&state, .{ .readiness = &state.readiness })) {
        .ready => {},
        .failure => return error.UnexpectedStartupFailure,
    }
    try std.testing.expectEqual(.no_content, ReadyHandler.handle(&context).status);
    try std.testing.expectEqual(
        lifecycle.Transition.advanced,
        try readiness_server.beginDrain(),
    );
    try std.testing.expectError(
        error.ServerNotReady,
        readiness_server.metricsSnapshot(0, &metrics_snapshot),
    );
    try std.testing.expectEqual(
        .service_unavailable,
        ReadyHandler.handle(&context).status,
    );
    try std.testing.expectEqual(
        server_types.ShutdownResult.stopped,
        try readiness_server.shutdown(),
    );
}

fn expectOneSignal(channel: *server_command.Channel) !void {
    switch (channel.counter.drain()) {
        .count => |count| try std.testing.expectEqual(@as(u64, 1), count),
        .empty, .failed => return error.TestUnexpectedResult,
    }
}

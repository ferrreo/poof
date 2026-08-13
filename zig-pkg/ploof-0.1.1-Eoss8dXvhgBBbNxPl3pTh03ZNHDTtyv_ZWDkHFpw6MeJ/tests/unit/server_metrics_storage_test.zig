const std = @import("std");

const application = @import("../../src/application.zig");
const route = @import("../../src/route.zig");
const runtime_config = @import("../../src/internal/runtime/config.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const limits = runtime_config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 16,
    .completion_entries = 32,
});

test "metrics-only storage owns a bounded wake identity lease" {
    const App = application.Application(.{
        .State = void,
        .routes = .{route.openMetrics("/metrics")},
    });
    const Storage = worker_storage.Storage(App, limits);
    try std.testing.expect(Storage.StreamWakeLifecycle.enabled);
    try std.testing.expect(@sizeOf(@FieldType(Storage.Request, "metrics")) <= 24);
}

test "ordinary finite storage pays no metrics lease or wake cost" {
    const Context = application.Context(void, .{});
    const Handler = struct {
        fn get(context: *Context) Context.ResponseType {
            return context.empty(.no_content);
        }
    };
    const App = application.Application(.{
        .State = void,
        .routes = .{route.get("/", Handler.get)},
    });
    const Storage = worker_storage.Storage(App, limits);
    try std.testing.expect(!Storage.StreamWakeLifecycle.enabled);
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(Storage.Request, "metrics")),
    );
}

test "metrics ticket blocks request release until transport terminal" {
    const App = application.Application(.{
        .State = void,
        .routes = .{route.openMetrics("/metrics")},
    });
    const Storage = worker_storage.Storage(App, limits);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    const connection_index = storage.acquireConnection(.{ .value = 7 }).?;
    const request_index = storage.acquireRequest(connection_index).?;
    storage.requests[request_index].metrics.start(.{ .generation = 3 }, 5, 0);
    try std.testing.expectEqual(
        worker_storage.RequestReleaseIssue.metrics_active,
        storage.requestReleaseIssue(connection_index, request_index),
    );
    storage.requests[request_index].metrics.clear();
    try std.testing.expectEqual(
        @as(?worker_storage.RequestReleaseIssue, null),
        storage.requestReleaseIssue(connection_index, request_index),
    );
}

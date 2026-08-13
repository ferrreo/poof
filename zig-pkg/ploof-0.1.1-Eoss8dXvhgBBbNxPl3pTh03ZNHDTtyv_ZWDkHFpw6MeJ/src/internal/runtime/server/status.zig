const std = @import("std");

const lifecycle = @import("../../../lifecycle.zig");

pub const Extra = struct {
    listener_live: bool = false,
    control_operations: u8 = 0,
    logger_events: u32 = 0,
    dropped_access_events: u64 = 0,
};

/// One writer publishes cleanup counts at event-loop boundaries. Readers use
/// the epoch around atomic fields to obtain one complete cross-thread snapshot.
pub const Published = struct {
    epoch: std.atomic.Value(u32) = .init(0),
    workers: std.atomic.Value(u16) = .init(1),
    listeners: std.atomic.Value(u16) = .init(0),
    connections: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    network_operations: std.atomic.Value(u32) = .init(0),
    file_operations: std.atomic.Value(u32) = .init(0),
    cancel_operations: std.atomic.Value(u32) = .init(0),
    borrowed_buffers: std.atomic.Value(u32) = .init(0),
    gzip_jobs: std.atomic.Value(u32) = .init(0),
    stream_publishers: std.atomic.Value(u32) = .init(0),
    upload_finalizers: std.atomic.Value(u32) = .init(0),
    middleware_after: std.atomic.Value(u32) = .init(0),
    helper_jobs: std.atomic.Value(u32) = .init(0),
    logger_events: std.atomic.Value(u32) = .init(0),
    dropped_access_events: std.atomic.Value(u64) = .init(0),

    pub fn publish(value: *Published, status: anytype, extra: Extra) void {
        const before = value.epoch.fetchAdd(1, .acq_rel);
        std.debug.assert(before & 1 == 0);
        value.workers.store(@intFromBool(!status.quiescent()), .monotonic);
        value.listeners.store(@intFromBool(extra.listener_live), .monotonic);
        value.connections.store(@intCast(status.live_connections), .monotonic);
        value.requests.store(@intCast(status.live_requests), .monotonic);
        value.network_operations.store(networkOperations(status, extra), .monotonic);
        value.file_operations.store(fieldU32(status, "file_operations", 0), .monotonic);
        value.cancel_operations.store(fieldU32(status, "cancel_operations", 0), .monotonic);
        value.borrowed_buffers.store(@intCast(status.borrowed_receives), .monotonic);
        value.gzip_jobs.store(@intCast(status.gzip_active_jobs), .monotonic);
        value.stream_publishers.store(
            @intCast(status.stream_active_publishers),
            .monotonic,
        );
        value.upload_finalizers.store(
            fieldU32(status, "upload_finalizers", 0),
            .monotonic,
        );
        value.middleware_after.store(fieldU32(status, "middleware_after", 0), .monotonic);
        value.helper_jobs.store(fieldU32(status, "helper_jobs", 0), .monotonic);
        value.logger_events.store(extra.logger_events, .monotonic);
        value.dropped_access_events.store(extra.dropped_access_events, .monotonic);
        _ = value.epoch.fetchAdd(1, .release);
    }

    pub fn snapshot(value: *const Published) lifecycle.ShutdownIncomplete {
        while (true) {
            const before = value.epoch.load(.acquire);
            if (before & 1 != 0) continue;
            const report = value.readFields();
            const after = value.epoch.load(.acquire);
            if (before == after) return report;
        }
    }

    fn readFields(value: *const Published) lifecycle.ShutdownIncomplete {
        return .{
            .remaining = .{
                .workers = value.workers.load(.monotonic),
                .listeners = value.listeners.load(.monotonic),
                .connections = value.connections.load(.monotonic),
                .requests = value.requests.load(.monotonic),
                .network_operations = value.network_operations.load(.monotonic),
                .file_operations = value.file_operations.load(.monotonic),
                .cancel_operations = value.cancel_operations.load(.monotonic),
                .borrowed_buffers = value.borrowed_buffers.load(.monotonic),
                .gzip_jobs = value.gzip_jobs.load(.monotonic),
                .stream_publishers = value.stream_publishers.load(.monotonic),
                .upload_finalizers = value.upload_finalizers.load(.monotonic),
                .middleware_after = value.middleware_after.load(.monotonic),
                .helper_jobs = value.helper_jobs.load(.monotonic),
                .logger_events = value.logger_events.load(.monotonic),
            },
            .dropped_access_events = value.dropped_access_events.load(.monotonic),
        };
    }
};

fn networkOperations(status: anytype, extra: Extra) u32 {
    const classified = @as(u32, status.listener_operations) +
        status.connection_operations + extra.control_operations;
    return fieldU32(status, "network_operations", classified);
}

fn fieldU32(status: anytype, comptime name: []const u8, fallback: u32) u32 {
    if (comptime @hasField(@TypeOf(status), name)) return @field(status, name);
    return fallback;
}

const FakeStatus = struct {
    live_connections: u16,
    live_requests: u16,
    listener_operations: u8,
    connection_operations: u32,
    backend_queued: u32,
    borrowed_receives: u16,
    gzip_active_jobs: u16,
    stream_active_publishers: u16,
    file_operations: u32,
    cancel_operations: u32,
    upload_finalizers: u32,
    middleware_after: u32,
    helper_jobs: u32,
    network_operations: u32,
    stopped: bool,

    fn quiescent(status: FakeStatus) bool {
        return status.stopped;
    }
};

test "published cleanup snapshot covers every bounded report class" {
    var value = Published{};
    value.publish(FakeStatus{
        .live_connections = 2,
        .live_requests = 3,
        .listener_operations = 1,
        .connection_operations = 4,
        .backend_queued = 5,
        .borrowed_receives = 6,
        .gzip_active_jobs = 7,
        .stream_active_publishers = 8,
        .file_operations = 9,
        .cancel_operations = 10,
        .upload_finalizers = 11,
        .middleware_after = 12,
        .helper_jobs = 13,
        .network_operations = 19,
        .stopped = false,
    }, .{
        .listener_live = true,
        .control_operations = 14,
        .logger_events = 15,
        .dropped_access_events = 16,
    });
    try std.testing.expectEqualDeep(lifecycle.ShutdownIncomplete{
        .remaining = .{
            .workers = 1,
            .listeners = 1,
            .connections = 2,
            .requests = 3,
            .network_operations = 19,
            .file_operations = 9,
            .cancel_operations = 10,
            .borrowed_buffers = 6,
            .gzip_jobs = 7,
            .stream_publishers = 8,
            .upload_finalizers = 11,
            .middleware_after = 12,
            .helper_jobs = 13,
            .logger_events = 15,
        },
        .dropped_access_events = 16,
    }, value.snapshot());
}

test "quiescent publication clears worker ownership" {
    var value = Published{};
    value.publish(std.mem.zeroInit(FakeStatus, .{ .stopped = true }), .{});
    try std.testing.expect(value.snapshot().empty());
}

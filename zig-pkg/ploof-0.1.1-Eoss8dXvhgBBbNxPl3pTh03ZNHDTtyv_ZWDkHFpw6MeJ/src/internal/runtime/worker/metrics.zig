const std = @import("std");

pub const upload = @import("upload_metrics.zig");
pub const UploadMetrics = upload.Metrics;
pub const UploadMetricsSnapshot = upload.Snapshot;

pub const cache_line_bytes = 64;

pub const Snapshot = struct {
    valid_completions: u64,
    connections_accepted: u64,
    connections_closed: u64,
    live_connections: u16,
    connections_high_water: u16,
    timeout_completions: u64,
    receive_buffer_exhaustions: u64,
    fatal_transitions: u64,
};

/// Embedded in one worker and mutated only by that worker's event loop.
pub const WorkerMetrics = struct {
    valid_completions: u64 align(cache_line_bytes) = 0,
    connections_accepted: u64 = 0,
    connections_closed: u64 = 0,
    timeout_completions: u64 = 0,
    receive_buffer_exhaustions: u64 = 0,
    fatal_transitions: u64 = 0,
    live_connections: u16 = 0,
    connections_high_water: u16 = 0,
    padding: [cache_line_bytes - 6 * @sizeOf(u64) - 2 * @sizeOf(u16)]u8 =
        [_]u8{0} ** (cache_line_bytes - 6 * @sizeOf(u64) - 2 * @sizeOf(u16)),

    pub fn recordValidCompletion(self: *WorkerMetrics) void {
        self.valid_completions +|= 1;
    }

    pub fn recordConnectionAccepted(self: *WorkerMetrics, capacity: u16) void {
        std.debug.assert(self.live_connections < capacity);
        self.connections_accepted +|= 1;
        self.live_connections += 1;
        self.connections_high_water = @max(
            self.connections_high_water,
            self.live_connections,
        );
    }

    pub fn recordConnectionsClosed(self: *WorkerMetrics, count: u16) void {
        std.debug.assert(count <= self.live_connections);
        self.connections_closed +|= count;
        self.live_connections -= count;
    }

    pub fn recordTimeoutCompletion(self: *WorkerMetrics) void {
        self.timeout_completions +|= 1;
    }

    pub fn recordReceiveBufferExhaustion(self: *WorkerMetrics) void {
        self.receive_buffer_exhaustions +|= 1;
    }

    pub fn recordFatalTransition(self: *WorkerMetrics) void {
        self.fatal_transitions +|= 1;
    }

    pub fn snapshot(self: *const WorkerMetrics) Snapshot {
        return .{
            .valid_completions = self.valid_completions,
            .connections_accepted = self.connections_accepted,
            .connections_closed = self.connections_closed,
            .live_connections = self.live_connections,
            .connections_high_water = self.connections_high_water,
            .timeout_completions = self.timeout_completions,
            .receive_buffer_exhaustions = self.receive_buffer_exhaustions,
            .fatal_transitions = self.fatal_transitions,
        };
    }
};

test "worker metrics occupy one isolated cache line" {
    try std.testing.expectEqual(cache_line_bytes, @alignOf(WorkerMetrics));
    try std.testing.expectEqual(cache_line_bytes, @sizeOf(WorkerMetrics));
}

test "worker metrics counters saturate and connection gauges remain exact" {
    var metrics = WorkerMetrics{};
    metrics.valid_completions = std.math.maxInt(u64) - 1;
    metrics.recordValidCompletion();
    metrics.recordValidCompletion();
    metrics.recordValidCompletion();

    metrics.recordConnectionAccepted(2);
    metrics.recordConnectionAccepted(2);
    metrics.recordConnectionsClosed(1);
    metrics.recordConnectionAccepted(2);
    metrics.recordConnectionsClosed(2);

    const snapshot = metrics.snapshot();
    try std.testing.expectEqual(std.math.maxInt(u64), snapshot.valid_completions);
    try std.testing.expectEqual(@as(u64, 3), snapshot.connections_accepted);
    try std.testing.expectEqual(@as(u64, 3), snapshot.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), snapshot.live_connections);
    try std.testing.expectEqual(@as(u16, 2), snapshot.connections_high_water);
}

test "worker metrics snapshot is copied by value" {
    var metrics = WorkerMetrics{};
    const before = metrics.snapshot();
    metrics.recordTimeoutCompletion();
    metrics.recordReceiveBufferExhaustion();
    metrics.recordFatalTransition();

    try std.testing.expectEqual(@as(u64, 0), before.timeout_completions);
    const after = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), after.timeout_completions);
    try std.testing.expectEqual(@as(u64, 1), after.receive_buffer_exhaustions);
    try std.testing.expectEqual(@as(u64, 1), after.fatal_transitions);
}

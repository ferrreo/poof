const std = @import("std");

const finalization = @import("../../src/internal/application/multipart_finalization.zig");
const upload_metrics = @import("../../src/internal/runtime/worker/upload_metrics.zig");
const metrics_record = @import("../../src/internal/runtime/worker/upload_metrics_record.zig");

test "finalization report records sparse cleanup failures atomically" {
    const App = struct {
        pub const upload_finalization_instances_max: u16 = 3;

        pub fn __multipartFinalizationCleanupFailure(
            _: *u8,
            _: []u8,
            index: u16,
        ) error{}!?finalization.CleanupFailure {
            return switch (index) {
                0 => null,
                1, 2 => .{
                    .class = .sink,
                    .identity = .{ .registry_index = 4, .instance_index = index },
                },
                else => unreachable,
            };
        }
    };
    var metrics = upload_metrics.Metrics{};
    var workspace: u8 = 0;
    var request_workspace: [1]u8 = .{0};
    try metrics_record.recordReport(App, &metrics, &workspace, &request_workspace, .{
        .outcome = .failed,
        .primary = null,
        .instance_count = 3,
        .commit_attempted_count = 0,
        .commit_completed_count = 0,
        .abort_attempted_count = 3,
        .abort_completed_count = 1,
        .cleanup_failure_count = 2,
    });
    const snapshot = metrics.snapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.finalization_outcomes[@intFromEnum(finalization.Outcome.failed)],
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        snapshot.cleanup_failures[@intFromEnum(finalization.CleanupFailureClass.sink)],
    );
    try std.testing.expectEqual(@as(u64, 3), snapshot.abort_attempted);
    try std.testing.expectEqual(@as(u64, 1), snapshot.abort_completed);
    try std.testing.expectEqual(@as(u8, 3), snapshot.event_count);
}

test "cleanup lookup failure leaves finalization metrics unchanged" {
    const App = struct {
        pub const upload_finalization_instances_max: u16 = 2;

        pub fn __multipartFinalizationCleanupFailure(
            _: *u8,
            _: []u8,
            index: u16,
        ) error{Injected}!?finalization.CleanupFailure {
            if (index == 1) return error.Injected;
            return .{
                .class = .sink,
                .identity = .{ .registry_index = 1, .instance_index = index },
            };
        }
    };
    var metrics = upload_metrics.Metrics{};
    var workspace: u8 = 0;
    var request_workspace: [1]u8 = .{0};
    try std.testing.expectError(error.ApplicationFailure, metrics_record.recordReport(
        App,
        &metrics,
        &workspace,
        &request_workspace,
        .{
            .outcome = .failed,
            .primary = null,
            .instance_count = 2,
            .commit_attempted_count = 0,
            .commit_completed_count = 0,
            .abort_attempted_count = 2,
            .abort_completed_count = 0,
            .cleanup_failure_count = 2,
        },
    ));
    const snapshot = metrics.snapshot();
    try std.testing.expectEqual(@as(u8, 0), snapshot.event_count);
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.finalization_outcomes[@intFromEnum(finalization.Outcome.failed)],
    );
}

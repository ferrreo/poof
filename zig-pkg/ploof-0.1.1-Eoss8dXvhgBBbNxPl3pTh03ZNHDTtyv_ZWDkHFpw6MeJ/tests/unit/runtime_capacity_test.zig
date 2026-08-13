const std = @import("std");
const runtime_capacity = @import("../../src/internal/runtime/runtime_capacity.zig");

test "runtime capacity applies exact upload formulas" {
    const capacity = try runtime_capacity.calculate(.{
        .connection_slots = 128,
        .body_workspace_slots = 4,
        .upload_window_max = 16,
        .request_handles_max = 3,
        .runtime_handles_max = 5,
        .async_sink_present = true,
    });
    try std.testing.expectEqual(@as(u32, 1_676), capacity.operation_capacity);
    try std.testing.expectEqual(@as(u32, 64), capacity.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 192), capacity.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 17), capacity.file_handle_capacity);
}

test "zero inputs preserve exact base and optional async target" {
    const none = try runtime_capacity.calculate(.{
        .connection_slots = 0,
        .body_workspace_slots = 0,
        .upload_window_max = std.math.maxInt(u32),
        .request_handles_max = std.math.maxInt(u32),
        .runtime_handles_max = 0,
        .async_sink_present = false,
    });
    try std.testing.expectEqual(@as(u32, 10), none.operation_capacity);
    try std.testing.expectEqual(@as(u32, 0), none.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 0), none.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 0), none.file_handle_capacity);

    const asynchronous = try runtime_capacity.calculate(.{
        .connection_slots = 0,
        .body_workspace_slots = 0,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = true,
    });
    try std.testing.expectEqual(@as(u32, 12), asynchronous.operation_capacity);
    try std.testing.expectEqual(@as(u32, 1), asynchronous.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 3), asynchronous.file_lease_capacity);
}

test "live static capacity reserves bounded operations and descriptors" {
    const capacity = try runtime_capacity.calculate(.{
        .connection_slots = 8,
        .body_workspace_slots = 0,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 3,
        .live_static_roots = 2,
    });
    try std.testing.expectEqual(@as(u32, 114), capacity.operation_capacity);
    try std.testing.expectEqual(@as(u32, 5), capacity.file_handle_capacity);
    try std.testing.expectEqual(@as(u32, 0), capacity.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 0), capacity.file_lease_capacity);
}

test "comptime validation returns the same exact capacity" {
    const checked = runtime_capacity.validate(.{
        .connection_slots = 2,
        .body_workspace_slots = 3,
        .upload_window_max = 4,
        .request_handles_max = 5,
        .runtime_handles_max = 6,
        .async_sink_present = false,
    });
    try std.testing.expectEqual(@as(u32, 58), checked.operation_capacity);
    try std.testing.expectEqual(@as(u32, 12), checked.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 36), checked.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 21), checked.file_handle_capacity);
}

test "every arithmetic boundary rejects overflow" {
    const maximum = std.math.maxInt(u32);
    try expectError(error.FileTargetCapacityOverflow, .{
        .body_workspace_slots = maximum,
        .upload_window_max = 2,
    });
    try expectError(error.OperationCapacityOverflow, .{
        .connection_slots = maximum,
    });
    try expectError(error.OperationCapacityOverflow, .{
        .connection_slots = maximum / 12,
    });
    try expectError(error.OperationCapacityOverflow, .{
        .body_workspace_slots = maximum / 2 + 1,
        .upload_window_max = 1,
    });
    try expectError(error.OperationCapacityOverflow, .{
        .connection_slots = (maximum - 8) / 12,
        .body_workspace_slots = 2,
        .upload_window_max = 2,
    });
    try expectError(error.OperationCapacityOverflow, .{
        .connection_slots = maximum / 12,
        .async_sink_present = true,
    });
    try expectError(error.FileLeaseCapacityOverflow, .{
        .body_workspace_slots = maximum / 3 + 1,
        .upload_window_max = 1,
    });
    try expectError(error.FileHandleCapacityOverflow, .{
        .body_workspace_slots = maximum,
        .request_handles_max = 2,
    });
    try expectError(error.FileHandleCapacityOverflow, .{
        .body_workspace_slots = 1,
        .request_handles_max = maximum,
        .runtime_handles_max = 1,
    });
}

test "lease capacity bounds the largest representable upload window" {
    const upload_slots = std.math.maxInt(u32) / 3;
    const capacity = try runtime_capacity.calculate(baseInputs(.{
        .body_workspace_slots = 1,
        .upload_window_max = upload_slots,
    }));
    try std.testing.expectEqual(upload_slots * 2 + 10, capacity.operation_capacity);
    try std.testing.expectEqual(upload_slots * 3, capacity.file_lease_capacity);
}

test "file handle hard maximum is inclusive" {
    const exact = try runtime_capacity.calculate(baseInputs(.{
        .body_workspace_slots = 256,
        .request_handles_max = 255,
        .runtime_handles_max = 256,
    }));
    try std.testing.expectEqual(runtime_capacity.file_handles_hard_max, exact.file_handle_capacity);
    try expectError(error.FileHandleCapacityAboveHardMax, .{
        .runtime_handles_max = runtime_capacity.file_handles_hard_max + 1,
    });
}

const PartialInputs = struct {
    connection_slots: u32 = 0,
    body_workspace_slots: u32 = 0,
    upload_window_max: u32 = 0,
    request_handles_max: u32 = 0,
    runtime_handles_max: u32 = 0,
    async_sink_present: bool = false,
};

fn expectError(expected: runtime_capacity.Error, partial: PartialInputs) !void {
    try std.testing.expectError(expected, runtime_capacity.calculate(baseInputs(partial)));
}

fn baseInputs(partial: PartialInputs) runtime_capacity.Inputs {
    return .{
        .connection_slots = partial.connection_slots,
        .body_workspace_slots = partial.body_workspace_slots,
        .upload_window_max = partial.upload_window_max,
        .request_handles_max = partial.request_handles_max,
        .runtime_handles_max = partial.runtime_handles_max,
        .async_sink_present = partial.async_sink_present,
    };
}

const std = @import("std");
const reactor = @import("reactor.zig");
const upload_file_table = @import("upload/file_table.zig");

pub const file_handles_hard_max: u32 = 1 << 16;

pub const Inputs = struct {
    connection_slots: u32,
    body_workspace_slots: u32,
    upload_window_max: u32,
    request_handles_max: u32,
    runtime_handles_max: u32,
    async_sink_present: bool,
    live_static_slots: u32 = 0,
    live_static_roots: u32 = 0,
};

pub const Capacity = struct {
    operation_capacity: u32,
    file_target_capacity: u32,
    file_lease_capacity: u32,
    file_handle_capacity: u32,
};

pub const Error = error{
    OperationCapacityOverflow,
    FileTargetCapacityOverflow,
    FileLeaseCapacityOverflow,
    FileHandleCapacityOverflow,
    FileHandleCapacityAboveHardMax,
};

pub fn calculate(inputs: Inputs) Error!Capacity {
    const upload_slots = std.math.mul(
        u32,
        inputs.body_workspace_slots,
        inputs.upload_window_max,
    ) catch return error.FileTargetCapacityOverflow;
    const operation_capacity = try operationCapacity(inputs, upload_slots);
    const file_handle_capacity = try fileHandleCapacity(inputs);
    const file_target_capacity = @max(
        upload_slots,
        @intFromBool(inputs.async_sink_present),
    );
    const file_lease_capacity = std.math.mul(
        u32,
        file_target_capacity,
        upload_file_table.operation_leases_max,
    ) catch return error.FileLeaseCapacityOverflow;
    return .{
        .operation_capacity = operation_capacity,
        .file_target_capacity = file_target_capacity,
        .file_lease_capacity = file_lease_capacity,
        .file_handle_capacity = file_handle_capacity,
    };
}

fn operationCapacity(inputs: Inputs, upload_slots: u32) Error!u32 {
    const connection_operations = std.math.mul(
        u32,
        inputs.connection_slots,
        reactor.connection_operation_capacity,
    ) catch return error.OperationCapacityOverflow;
    const upload_operations = std.math.mul(
        u32,
        upload_slots,
        2,
    ) catch return error.OperationCapacityOverflow;
    const live_static_operations = std.math.mul(
        u32,
        inputs.live_static_slots,
        2,
    ) catch return error.OperationCapacityOverflow;
    // The target and timer overlap. A winner is reaped before its cancel is submitted,
    // so the runtime probe never owns more than two active reactor operations.
    const runtime_probe_operations: u32 = if (inputs.async_sink_present) 2 else 0;
    const base_operations = std.math.add(
        u32,
        connection_operations,
        reactor.worker_control_operation_capacity,
    ) catch return error.OperationCapacityOverflow;
    const operation_capacity_with_uploads = std.math.add(
        u32,
        base_operations,
        upload_operations,
    ) catch return error.OperationCapacityOverflow;
    const operation_capacity_with_static = std.math.add(
        u32,
        operation_capacity_with_uploads,
        live_static_operations,
    ) catch return error.OperationCapacityOverflow;
    const operation_capacity_with_probes = std.math.add(
        u32,
        operation_capacity_with_static,
        runtime_probe_operations,
    ) catch return error.OperationCapacityOverflow;
    return std.math.add(
        u32,
        operation_capacity_with_probes,
        inputs.live_static_roots,
    ) catch return error.OperationCapacityOverflow;
}

fn fileHandleCapacity(inputs: Inputs) Error!u32 {
    const request_handles = std.math.mul(
        u32,
        inputs.body_workspace_slots,
        inputs.request_handles_max,
    ) catch return error.FileHandleCapacityOverflow;
    const upload_file_handle_capacity = std.math.add(
        u32,
        inputs.runtime_handles_max,
        request_handles,
    ) catch return error.FileHandleCapacityOverflow;
    const static_file_handle_capacity = std.math.add(
        u32,
        inputs.live_static_roots,
        inputs.live_static_slots,
    ) catch return error.FileHandleCapacityOverflow;
    const file_handle_capacity = std.math.add(
        u32,
        upload_file_handle_capacity,
        static_file_handle_capacity,
    ) catch return error.FileHandleCapacityOverflow;
    if (file_handle_capacity > file_handles_hard_max) {
        return error.FileHandleCapacityAboveHardMax;
    }
    return file_handle_capacity;
}

pub fn validate(comptime inputs: Inputs) Capacity {
    return comptime calculate(inputs) catch |problem| @compileError(diagnostic(problem));
}

fn diagnostic(problem: Error) []const u8 {
    return switch (problem) {
        error.OperationCapacityOverflow => "PLOOF-E3494 runtime operation capacity exceeds u32",
        error.FileTargetCapacityOverflow => "PLOOF-E3495 runtime file target capacity exceeds u32",
        error.FileLeaseCapacityOverflow => "PLOOF-E3505 runtime file lease capacity exceeds u32",
        error.FileHandleCapacityOverflow => "PLOOF-E3496 runtime file handle capacity exceeds u32",
        error.FileHandleCapacityAboveHardMax => {
            return "PLOOF-E3497 runtime file handle capacity exceeds 65536";
        },
    };
}

const std = @import("std");
const runtime_capacity = @import("ploof_compile").runtime_capacity;

export fn forceRuntimeFileLeaseCapacityOverflow() void {
    _ = runtime_capacity.validate(.{
        .connection_slots = 0,
        .body_workspace_slots = 1,
        .upload_window_max = std.math.maxInt(u32) / 3 + 1,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
    });
}

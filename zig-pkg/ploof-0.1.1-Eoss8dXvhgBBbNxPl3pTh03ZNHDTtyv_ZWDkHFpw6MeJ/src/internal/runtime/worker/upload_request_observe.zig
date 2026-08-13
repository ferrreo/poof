const upload_metrics = @import("upload_metrics.zig");

pub fn syncInflight(request: anytype, state: anytype) void {
    request.flags.upload_inflight = state.active != 0;
}

pub fn noteWindowFull(state: anytype, now_ns: u64) void {
    if (state.route_window == 0 or state.active != state.route_window or
        state.window_full_since_ns != null) return;
    state.window_full_since_ns = now_ns;
}

pub fn finishWindowFull(metrics: anytype, state: anytype, now_ns: u64) void {
    const started = state.window_full_since_ns orelse return;
    metrics.recordWindowFull(elapsed(started, now_ns));
    state.window_full_since_ns = null;
}

pub fn clearWindowFull(state: anytype) void {
    state.window_full_since_ns = null;
}

pub fn elapsed(start_ns: u64, end_ns: u64) u64 {
    return if (end_ns >= start_ns) end_ns - start_ns else 0;
}

pub fn identity(entry: anytype) upload_metrics.Identity {
    return .{
        .registry_index = entry.registry_index,
        .instance_index = entry.instance_index,
    };
}

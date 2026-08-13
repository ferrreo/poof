const worker_stream_lifecycle = @import("stream_lifecycle.zig");

/// Invalidates every copied producer wake before backend-wide ownership recovery.
pub fn prepareBeforeBackend(storage: anytype) bool {
    if (comptime @hasField(@TypeOf(storage.requests[0].stream_transport), "active")) {
        for (storage.requests) |*request| {
            if (request.phase != .live or !request.stream_transport.active) continue;
            request.stream_transport.poll_ready = false;
            request.stream_transport.full_clear_required = false;
            request.stream_transport.timeout_cancel_target_sequence = 0;
            request.stream_transport.timeout_cancel_operation_sequence = 0;
            request.stream_transport.cancel_outcome = null;
            if (request.stream_transport.state.phase() == .finished) continue;
            const action = request.stream_transport.state.cancel(.aborted) catch return false;
            switch (action) {
                .invalidate => {
                    const wake = request.stream_transport.state.wake() orelse return false;
                    const result = storage.stream_wakes.invalidateBeforeAbort(wake);
                    if (result != .invalidated) return false;
                },
                .finished => {},
                else => return false,
            }
        }
    }
    return true;
}

/// SEND buffers are no longer kernel-owned. Producers may now abort and join.
pub fn finishAfterBackend(storage: anytype) bool {
    if (comptime @hasField(@TypeOf(storage.requests[0].stream_transport), "active")) {
        for (storage.requests) |*request| {
            if (request.phase != .live or !request.stream_transport.active) continue;
            const phase = request.stream_transport.state.phase();
            if (phase == .awaiting_invalidation) {
                const action = request.stream_transport.state.invalidated(.invalidated) catch {
                    return false;
                };
                if (action != .finished) return false;
            } else if (phase != .finished) {
                return false;
            }
            request.stream_transport.active = false;
            request.stream_transport.poll_ready = false;
            request.stream_transport.full_clear_required = false;
            request.stream_transport.timeout_cancel_target_sequence = 0;
            request.stream_transport.timeout_cancel_operation_sequence = 0;
            request.stream_transport.cancel_outcome = null;
        }
        storage.stream_wakes.confirmPublishersJoined() catch return false;
        storage.stream_wakes.beginFatalAfterPublishersJoined() catch return false;
        storage.stream_wakes.finishFatalAfterBackend() catch return false;
        return storage.stream_wakes.status().phase == worker_stream_lifecycle.Phase.stopped;
    }
    return true;
}

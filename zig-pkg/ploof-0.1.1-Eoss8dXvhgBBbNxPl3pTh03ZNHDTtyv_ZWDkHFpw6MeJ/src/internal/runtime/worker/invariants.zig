const std = @import("std");

pub fn check(worker: anytype, comptime Storage: type) void {
    std.debug.assert(worker.stop_cursor <= Storage.runtime_limits.connection_slots);
    std.debug.assert(
        worker.receive_resume_cursor < Storage.runtime_limits.connection_slots,
    );
    std.debug.assert(worker.paused_receive_count <= worker.storage.connections.len);
    std.debug.assert(
        worker.receive_resume_credits <= Storage.runtime_limits.receive_buffers,
    );
    if (worker.flush_pending) {
        std.debug.assert(worker.phase != .idle);
        std.debug.assert(worker.phase != .stopped);
        std.debug.assert(worker.phase != .failed);
    }
    if (worker.stop_scheduling_done) {
        std.debug.assert(worker.control_flags.stop_accept_scheduled);
    }
    if (worker.fatal) std.debug.assert(worker.phase != .idle);
    if (worker.phase == .stopped) std.debug.assert(worker.gzip.isStopped());
    if (worker.phase == .stopped) {
        std.debug.assert(worker.storage.stream_wakes.isStopped());
        std.debug.assert(worker.driver.liveStaticStopped());
    }
    switch (worker.fatal_cleanup) {
        .not_required => {},
        .recovered => {
            std.debug.assert(worker.fatal);
            std.debug.assert(worker.phase == .stopped);
        },
        .process_exit_required => {
            std.debug.assert(worker.fatal);
            std.debug.assert(worker.phase == .failed);
        },
    }
}

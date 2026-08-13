const worker_gzip_lifecycle = @import("gzip_lifecycle.zig");
const worker_stream_lifecycle = @import("stream_lifecycle.zig");

pub const Phase = enum(u8) { idle, running, stopping, stopped, failed };

pub const FatalCleanup = enum(u8) {
    not_required,
    recovered,
    process_exit_required,
};

pub const Status = struct {
    phase: Phase,
    fatal: bool,
    flush_pending: bool,
    stop_scheduling_done: bool,
    live_connections: u16,
    live_requests: u16,
    listener_operations: u8,
    gzip_phase: worker_gzip_lifecycle.Phase,
    gzip_operations: u8,
    gzip_active_jobs: u16,
    stream_phase: worker_stream_lifecycle.Phase,
    stream_operations: u8,
    stream_active_publishers: u16,
    stream_stale_notifications: u64,
    connection_operations: u32,
    backend_queued: u32,
    backend_active: u32,
    borrowed_receives: u16,
    upload_operations: u32,
    upload_registry_stopped: bool,
    upload_ownership_proven: bool,
    live_static_operations: u16,
    live_static_requests: u16,
    live_static_roots_stopped: bool,
    fatal_cleanup: FatalCleanup,
    accepted_sockets_discarded: u32,
    connection_discard_failures: u16,
    workspace_abort_attempts: u16,
    workspace_abort_failures: u16,

    pub fn quiescent(status: Status) bool {
        return status.phase == .stopped and
            status.fatal_cleanup != .process_exit_required and
            status.stop_scheduling_done and
            !status.flush_pending and
            status.live_connections == 0 and
            status.live_requests == 0 and
            status.listener_operations == 0 and
            (status.gzip_phase == .disabled or status.gzip_phase == .stopped) and
            status.gzip_operations == 0 and
            status.gzip_active_jobs == 0 and
            (status.stream_phase == .disabled or status.stream_phase == .stopped) and
            status.stream_operations == 0 and
            status.stream_active_publishers == 0 and
            status.connection_operations == 0 and
            status.backend_queued == 0 and
            status.backend_active == 0 and
            status.borrowed_receives == 0 and
            status.upload_operations == 0 and
            status.upload_registry_stopped and
            status.upload_ownership_proven and
            status.live_static_operations == 0 and
            status.live_static_requests == 0 and
            status.live_static_roots_stopped;
    }

    pub fn requiresProcessExit(status: Status) bool {
        return status.fatal_cleanup == .process_exit_required;
    }
};

pub fn snapshot(worker: anytype) Status {
    var connection_operations: u32 = 0;
    for (worker.storage.connections) |*connection| {
        connection_operations += connection.inflight_operations;
    }
    const listener_operations = @as(
        u8,
        @intFromBool(worker.controller.accept_token != null),
    ) + @as(u8, @intFromBool(worker.controller.cancel_token != null)) +
        @as(u8, @intFromBool(worker.controller.retry_token != null));
    const gzip_status = worker.gzip.status(worker.storage);
    const stream_status = worker.storage.stream_wakes.status();
    return .{
        .phase = worker.phase,
        .fatal = worker.fatal,
        .flush_pending = worker.flush_pending,
        .stop_scheduling_done = worker.stop_scheduling_done,
        .live_connections = @intCast(
            worker.storage.connections.len - worker.storage.connection_pool.available(),
        ),
        .live_requests = @intCast(
            worker.storage.requests.len - worker.storage.request_pool.available(),
        ),
        .listener_operations = listener_operations,
        .gzip_phase = gzip_status.phase,
        .gzip_operations = gzip_status.operations,
        .gzip_active_jobs = gzip_status.active_jobs,
        .stream_phase = stream_status.phase,
        .stream_operations = stream_status.operations,
        .stream_active_publishers = stream_status.active_publishers,
        .stream_stale_notifications = stream_status.stale_notifications,
        .connection_operations = connection_operations,
        .backend_queued = @intCast(worker.io.queuedCount()),
        .backend_active = @intCast(worker.io.activeCount()),
        .borrowed_receives = @intCast(worker.io.borrowedCount()),
        .upload_operations = worker.driver.uploadPending(),
        .upload_registry_stopped = worker.driver.uploadRegistryStopped(),
        .upload_ownership_proven = worker.driver.uploadOwnershipProven(),
        .live_static_operations = worker.driver.liveStaticPending(),
        .live_static_requests = worker.driver.liveStaticRequests(),
        .live_static_roots_stopped = worker.driver.liveStaticStopped(),
        .fatal_cleanup = worker.fatal_cleanup,
        .accepted_sockets_discarded = worker.accepted_sockets_discarded,
        .connection_discard_failures = worker.connection_discard_failures,
        .workspace_abort_attempts = worker.workspace_abort_attempts,
        .workspace_abort_failures = worker.workspace_abort_failures,
    };
}

pub fn updateStopped(worker: anytype) void {
    updateStoppedWithExternalActive(worker, 0);
}

pub fn updateStoppedWithExternalActive(worker: anytype, external_active: u8) void {
    if (worker.phase != .stopping) return;
    if (!worker.stop_scheduling_done) return;
    if (!worker.controller.isStopped()) return;
    if (!worker.gzip.isStopped()) return;
    if (!worker.storage.stream_wakes.isStopped()) return;
    if (!worker.driver.uploadRegistryStopped()) return;
    if (worker.driver.uploadPending() != 0) return;
    if (!worker.driver.liveStaticStopped()) return;
    if (worker.driver.liveStaticPending() != 0) return;
    if (worker.driver.liveStaticRequests() != 0) return;
    const status = worker.cleanupStatus();
    if (status.live_connections != 0) return;
    if (status.live_requests != 0) return;
    if (status.listener_operations != 0) return;
    if (status.gzip_operations != 0) return;
    if (status.gzip_active_jobs != 0) return;
    if (status.stream_operations != 0) return;
    if (status.stream_active_publishers != 0) return;
    if (status.connection_operations != 0) return;
    if (status.backend_queued != 0) return;
    if (status.backend_active != @as(u32, external_active)) return;
    if (status.borrowed_receives != 0) return;
    if (status.live_static_operations != 0) return;
    if (status.live_static_requests != 0) return;
    if (!status.live_static_roots_stopped) return;
    worker.phase = .stopped;
}

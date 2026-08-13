const worker_emergency = @import("emergency.zig");
const worker_gzip_lifecycle = @import("gzip_lifecycle.zig");
const worker_stream_emergency = @import("stream_emergency.zig");

pub fn emergencyAbort(comptime App: type, worker: anytype) void {
    if (worker.fatal_cleanup != .not_required) return;
    const metrics_prepared = worker.driver.prepareMetricsFatal();
    const streams_prepared = worker_stream_emergency.prepareBeforeBackend(worker.storage);
    worker.gzip.beginFatal(worker.storage);
    var backend_ownership_proven = false;
    if (worker.io.abort()) |status| {
        backend_ownership_proven = status.ownership_proven;
        worker.accepted_sockets_discarded +|= status.accepted_sockets_discarded;
    } else |_| {}
    var ownership_proven = backend_ownership_proven;
    if (backend_ownership_proven) {
        worker.controller.abort();
        ownership_proven = worker.driver.abortLiveStatic() and
            finishGzip(worker) and metrics_prepared and streams_prepared and
            worker_stream_emergency.finishAfterBackend(worker.storage) and
            worker.driver.finishMetricsFatal() and
            trackedDescriptorsProven(worker);
    }
    if (ownership_proven) {
        discardTrackedConnections(worker);
        ownership_proven = worker.connection_discard_failures == 0;
    }
    if (ownership_proven) {
        const application_status = worker_emergency.abortAllObserved(
            App,
            worker.storage,
            &worker.driver.observation,
        );
        worker.workspace_abort_attempts = application_status.workspace_attempts;
        worker.workspace_abort_failures = application_status.workspace_failures;
        ownership_proven = worker.workspace_abort_failures == 0;
    }
    if (ownership_proven) {
        worker.driver.retireAllRequests() catch {
            ownership_proven = false;
        };
    }
    if (ownership_proven) releaseRecords(worker);
    clearReceiveRecovery(worker);
    worker.flush_pending = false;
    worker.control_flags.stop_accept_scheduled = true;
    worker.stop_scheduling_done = true;
    worker.fatal_cleanup = if (ownership_proven) .recovered else .process_exit_required;
    worker.phase = if (ownership_proven) .stopped else .failed;
}

fn finishGzip(worker: anytype) bool {
    const WorkerPointer = @TypeOf(worker);
    const Context = struct { worker: WorkerPointer };
    const Callback = struct {
        fn settle(
            context: Context,
            slot_index: u16,
            signals: worker_gzip_lifecycle.Signals,
        ) !void {
            try context.worker.driver.settleGzipAfterBackend(slot_index, signals);
        }
    };
    return worker.gzip.finishFatalAfterBackend(
        worker.storage,
        Context{ .worker = worker },
        Callback.settle,
    );
}

fn discardTrackedConnections(worker: anytype) void {
    for (worker.storage.connections) |*connection| {
        if (connection.phase == .free or connection.socket_closed) continue;
        worker.io.discard(connection.socket) catch {
            worker.connection_discard_failures += 1;
        };
    }
}

fn trackedDescriptorsProven(worker: anytype) bool {
    if (!worker.driver.uploadOwnershipProven() or
        worker.driver.uploadPending() != 0 or
        worker.driver.uploadActiveHandles() != 0)
    {
        return false;
    }
    for (worker.storage.connections) |*connection| {
        if (connection.phase != .free and connection.close_token != null) return false;
    }
    return true;
}

fn releaseRecords(worker: anytype) void {
    const released: u16 = @intCast(
        worker.storage.connections.len - worker.storage.connection_pool.available(),
    );
    worker_emergency.releaseAllRecords(worker.storage);
    worker.metrics.recordConnectionsClosed(released);
}

fn clearReceiveRecovery(worker: anytype) void {
    @memset(&worker.paused_receives, false);
    worker.paused_receive_count = 0;
    worker.receive_resume_credits = 0;
}

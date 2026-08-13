const startup = @import("../../../startup.zig");
const accept_controller = @import("../accept_controller.zig");
const reactor = @import("../reactor.zig");
const worker_entropy = @import("entropy.zig");

pub fn initialize(
    comptime App: type,
    comptime upload_registry_present: bool,
    comptime Error: type,
    worker: anytype,
    state: *App.StateType,
    storage: anytype,
    io: anytype,
    worker_index: u16,
    listener: reactor.Socket,
    server_identity: anytype,
    forwarding_profile: anytype,
    metrics_runtime: anytype,
    observation: anytype,
    admission_controller: anytype,
) Error!void {
    if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
    switch (startup.checkApplication(App, state)) {
        .ready => {},
        .failure => return error.InvalidApplicationConfiguration,
    }
    worker.* = undefined;
    worker.storage = storage;
    worker.io = io;
    worker.admission_controller = admission_controller;
    worker.controller = accept_controller.Controller.init(worker_index, listener);
    worker.gzip = @TypeOf(worker.gzip).init(worker_index) catch
        return error.InvalidWorkerIndex;
    worker.date_cache = .{};
    worker.last_date_refresh_ns = null;
    worker.last_monotonic_ns = 0;
    worker.phase = .idle;
    worker.flush_pending = false;
    worker.fatal = false;
    worker.control_flags = .{};
    worker.stop_scheduling_done = false;
    worker.stop_cursor = 0;
    errdefer if (comptime upload_registry_present) {
        @import("std").crypto.secureZero(u8, &worker.upload_entropy);
    };
    if (comptime upload_registry_present) {
        worker_entropy.fill(&worker.upload_entropy) catch return error.UploadFailure;
    } else {
        worker.upload_entropy = .{};
    }
    worker.paused_receives = @splat(false);
    worker.paused_receive_count = 0;
    worker.receive_resume_credits = 0;
    worker.receive_resume_cursor = 0;
    worker.fatal_cleanup = .not_required;
    worker.accepted_sockets_discarded = 0;
    worker.connection_discard_failures = 0;
    worker.workspace_abort_attempts = 0;
    worker.workspace_abort_failures = 0;
    worker.metrics = .{};
    storage.stream_wakes = @TypeOf(storage.stream_wakes).init(worker_index) catch
        return error.InvalidWorkerIndex;
    worker.driver = @TypeOf(worker.driver).initForwardingMetrics(
        state,
        storage,
        io,
        worker_index,
        .{
            .date = worker.date_cache.slice(),
            .server_identity = server_identity,
        },
        forwarding_profile,
        metrics_runtime,
        observation,
    ) catch return error.DriverFailure;
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

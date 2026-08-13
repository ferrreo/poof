const worker_upload = @import("ploof_compile").worker_upload_transport;

const App = struct {
    pub const upload_async_sink_present = true;
};

const Storage = struct {
    pub const runtime_limits = .{ .request_slots = 1 };
};

const Reactor = struct {
    pub const file_handle_capacity = 1;
    pub const file_target_capacity = 0;
};

export fn forceUploadTargetCapacityDiagnostic() void {
    _ = @sizeOf(worker_upload.Controller(App, Storage, Reactor));
}

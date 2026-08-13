const worker_upload = @import("ploof_compile").worker_upload_transport;

const App = struct {
    pub const upload_async_sink_present = true;
    pub const upload_window_max: u32 = 0;
};

const Storage = struct {
    pub const runtime_limits = .{ .request_slots = 1 };
};

const Reactor = struct {
    pub const file_handle_capacity = 1;
    pub const file_target_capacity = 1;
};

export fn forceUploadWindowDiagnostic() void {
    _ = @sizeOf(worker_upload.Controller(App, Storage, Reactor));
}

const worker_upload = @import("ploof_compile").worker_upload_transport;

const App = struct {
    pub const upload_async_sink_present = true;
};

const Storage = struct {
    pub const runtime_limits = .{ .request_slots = 1 };
};

export fn forceUploadCapableReactorDiagnostic() void {
    _ = @sizeOf(worker_upload.Controller(App, Storage, struct {}));
}

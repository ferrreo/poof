const route_metrics = @import("ploof_compile").worker_upload_route_metrics;

const App = struct {
    pub const upload_window_max: u32 = 4;
    pub const upload_route_profiles = [_]struct { route_id: u16, window: u8 }{};

    pub fn __multipartUploadRouteId() void {}
};

export fn forceEmptyUploadRouteProfiles() void {
    _ = route_metrics.Table(App);
}

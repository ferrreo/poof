const route_metrics = @import("ploof_compile").worker_upload_route_metrics;

const App = struct {
    pub const upload_window_max: u32 = 4;
    pub const upload_route_profiles = [_]struct { route_id: u16, window: u8 }{
        .{ .route_id = 3, .window = 1 },
        .{ .route_id = 3, .window = 4 },
    };

    pub fn __multipartUploadRouteId() void {}
};

export fn forceDuplicateUploadRouteProfile() void {
    _ = route_metrics.Table(App);
}

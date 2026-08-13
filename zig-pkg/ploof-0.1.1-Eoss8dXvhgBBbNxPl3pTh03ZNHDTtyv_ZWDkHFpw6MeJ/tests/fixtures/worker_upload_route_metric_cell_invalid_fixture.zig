const route_metrics = @import("ploof_compile").worker_upload_route_metrics;

export fn forceUploadRouteMetricCellOverflow() void {
    comptime route_metrics.validateCellBytes(route_metrics.cell_bytes_max + 1);
}

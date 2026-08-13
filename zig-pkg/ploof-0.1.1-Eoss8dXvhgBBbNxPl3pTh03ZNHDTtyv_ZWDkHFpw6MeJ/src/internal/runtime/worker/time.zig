const std = @import("std");

pub fn refresh(worker: anytype, sample: anytype) error{InvalidClock}!void {
    if (worker.last_date_refresh_ns) |last_refresh| {
        if (sample.monotonic_ns < last_refresh) return error.InvalidClock;
        if (sample.monotonic_ns - last_refresh < std.time.ns_per_s) return;
    }
    _ = worker.date_cache.update(sample.epoch_second) catch return error.InvalidClock;
    worker.last_date_refresh_ns = sample.monotonic_ns;
}

pub fn bind(worker: anytype) void {
    worker.driver.runtime_fields.date = worker.date_cache.slice();
}

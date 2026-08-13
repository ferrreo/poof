const selector = @import("targets.zig");

comptime {
    _ = selector.select("fuzz/application_response_gzip_fuzz_check.zig");
    _ = selector.select("fuzz/gzip_schedule_fuzz_check.zig");
    _ = selector.select("fuzz/live_static_schedule_fuzz_check.zig");
    _ = selector.select("fuzz/runtime_fuzz_check.zig");
    _ = selector.select("src/body.zig");
    _ = selector.select("tests/unit/json_validate_test.zig");
}

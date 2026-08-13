const body_driver_fuzz = @import("internal/runtime/connection_body_driver_fuzz.zig");

test {
    _ = body_driver_fuzz;
}

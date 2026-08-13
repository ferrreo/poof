const gzip_schedule_fuzz = @import(
    "internal/runtime/connection_gzip_schedule_fuzz_check.zig",
);

test {
    _ = gzip_schedule_fuzz;
}

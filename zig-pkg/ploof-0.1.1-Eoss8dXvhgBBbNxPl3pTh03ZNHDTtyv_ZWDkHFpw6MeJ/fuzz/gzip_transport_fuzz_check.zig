const gzip_transport_fuzz = @import(
    "internal/runtime/connection_gzip_driver_fuzz_check.zig",
);

test {
    _ = gzip_transport_fuzz;
}

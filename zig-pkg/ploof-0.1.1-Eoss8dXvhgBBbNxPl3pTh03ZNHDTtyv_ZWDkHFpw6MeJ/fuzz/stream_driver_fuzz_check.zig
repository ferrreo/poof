const connection_stream_driver_fuzz_check = @import(
    "internal/runtime/connection_stream_driver_fuzz_check.zig",
);

test {
    _ = connection_stream_driver_fuzz_check;
}

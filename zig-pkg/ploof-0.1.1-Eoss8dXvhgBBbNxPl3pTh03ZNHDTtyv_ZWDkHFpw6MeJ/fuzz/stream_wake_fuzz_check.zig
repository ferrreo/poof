const stream_wake_fuzz = @import(
    "internal/runtime/worker_stream_wake_fuzz_check.zig",
);

test {
    _ = stream_wake_fuzz;
}

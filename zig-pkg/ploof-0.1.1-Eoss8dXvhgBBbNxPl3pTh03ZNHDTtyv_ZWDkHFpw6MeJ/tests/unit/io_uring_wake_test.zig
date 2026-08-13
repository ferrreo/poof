const io_uring_wake = @import(
    "internal/runtime/io_uring_wake_integration_test.zig",
);

test {
    _ = io_uring_wake;
}

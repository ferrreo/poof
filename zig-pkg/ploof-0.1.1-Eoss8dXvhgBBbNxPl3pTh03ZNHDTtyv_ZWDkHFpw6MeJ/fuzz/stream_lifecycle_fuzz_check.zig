const stream_lifecycle_fuzz = @import(
    "internal/runtime/worker_stream_lifecycle_fuzz_check.zig",
);
const response_stream_erasure = @import("../src/internal/response/stream_erasure.zig");

test {
    _ = stream_lifecycle_fuzz;
    _ = response_stream_erasure;
}

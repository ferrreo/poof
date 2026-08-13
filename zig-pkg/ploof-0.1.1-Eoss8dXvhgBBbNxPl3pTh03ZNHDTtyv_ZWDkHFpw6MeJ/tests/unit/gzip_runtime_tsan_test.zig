test {
    _ = @import("internal/runtime/connection_gzip_driver_test.zig");
    _ = @import("internal/runtime/connection_stream_driver_test.zig");
    _ = @import("internal/runtime/gzip_decoder_pool_test.zig");
    _ = @import("internal/runtime/gzip_decoder_pool_shutdown_test.zig");
    _ = @import("internal/runtime/gzip_input_queue_wait_test.zig");
    _ = @import("internal/runtime/gzip_decoder_stream_test.zig");
    _ = @import("internal/runtime/gzip_output_mailbox_test.zig");
    _ = @import("internal/runtime/worker_gzip_lifecycle_test.zig");
    _ = @import("internal/runtime/worker_stream_lifecycle_test.zig");
    _ = @import("internal/runtime/worker_stream_wake_test.zig");
}

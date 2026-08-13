test {
    _ = @import("../../src/internal/runtime/server/metrics_service.zig");
    _ = @import("../../src/internal/runtime/server/metrics_request.zig");
    _ = @import("../../src/internal/runtime/server/metrics_binding.zig");
    _ = @import("../../src/internal/runtime/worker/metrics_lease.zig");
    _ = @import("server_metrics_storage_test.zig");
    _ = @import("server_metrics_claim_race_test.zig");
}

const controller = @import("../../src/internal/runtime/worker/upload_disabled_controller.zig");

test {
    @import("std").testing.refAllDecls(controller);
}

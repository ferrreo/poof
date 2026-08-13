const std = @import("std");
const builtin = @import("builtin");
const event_counter = @import("../../../../src/internal/runtime/event_counter.zig");
const gzip_decoder_pool = @import("../../../../src/internal/runtime/gzip/decoder_pool.zig");

const Pool = gzip_decoder_pool.FixedPool(1, 16, 8, 1);
const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    256 * 1024;

const StopHarness = struct {
    pool: *Pool,
    failure: ?event_counter.Failure = null,

    fn run(self: *StopHarness) void {
        self.failure = self.pool.beginStop();
    }
};

test "gzip decoder pool shutdown observes cancellation after stale shutdown snapshot" {
    var slots: [1]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    Pool.TestAccess.pauseWaitState(false);
    defer Pool.TestAccess.pauseWaitState(false);
    Pool.TestAccess.pauseWaitState(true);
    try pool.start(stack_size);
    try waitForCondition(Pool.TestAccess.waitStatePaused);

    var output: [32]u8 = undefined;
    const lease = pool.acquire(
        .{ .connection_index = 1, .request_index = 2, .generation = 3 },
        &output,
        .{ .encoded_max = 16, .decoded_max = output.len },
    ) orelse return error.TestUnexpectedResult;
    var stop = StopHarness{ .pool = &pool };
    const thread = try std.Thread.spawn(.{}, StopHarness.run, .{&stop});
    try waitForShutdown(&pool);
    Pool.TestAccess.pauseWaitState(false);
    thread.join();

    try std.testing.expectEqual(@as(?event_counter.Failure, null), stop.failure);
    try std.testing.expectEqual(Pool.Lifecycle.quiesced, pool.lifecycleStatus());
    const result = (try pool.result(lease)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.canceled, std.meta.activeTag(result));
    const batch = switch (pool.consumeWake()) {
        .consumed => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expect(batch.slots[0].terminal);
    try pool.ack(lease);
    try std.testing.expectEqual(@as(?event_counter.Failure, null), try pool.finishStop());
}

fn waitForShutdown(pool: *const Pool) !void {
    for (0..1_000_000) |_| {
        if (Pool.TestAccess.threadShuttingDown(pool, 0)) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitForCondition(comptime condition: fn () bool) !void {
    for (0..1_000_000) |_| {
        if (condition()) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

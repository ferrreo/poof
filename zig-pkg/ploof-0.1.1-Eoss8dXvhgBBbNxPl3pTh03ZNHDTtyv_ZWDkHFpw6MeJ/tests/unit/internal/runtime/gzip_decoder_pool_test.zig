pub const std = @import("std");
pub const builtin = @import("builtin");
pub const event_counter = @import("../../../../src/internal/runtime/event_counter.zig");
pub const futex_epoch = @import("../../../../src/internal/runtime/futex_epoch.zig");
pub const gzip_input_queue = @import("../../../../src/internal/runtime/gzip/input_queue.zig");
pub const pool_module = @import("../../../../src/internal/runtime/gzip/decoder_pool.zig");
pub const fixture = @import("gzip_decoder_test.zig");

pub const Pool = pool_module.FixedPool(3, 64, 16, 2);
pub const SmallPool = pool_module.FixedPool(1, 16, 8, 2);
pub const MemberPool = pool_module.FixedPool(1, 256, 32, 2);
pub const StreamingPool = pool_module.FixedPool(2, 128, 8, 2);
pub const SingleStreamingPool = pool_module.FixedPool(1, 128, 8, 2);
pub const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    256 * 1024;

pub fn waitBlockedOutput(
    pool: *SingleStreamingPool,
    lease: pool_module.Lease,
) ![]const u8 {
    for (0..1_000_000) |_| {
        _ = try consumedBatch(SingleStreamingPool, pool);
        if (try pool.output(lease)) |chunk| {
            if (SingleStreamingPool.TestAccess.outputProducerWaiting(pool, lease.index)) {
                return chunk;
            }
        }
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn runRejected(
    pool: *MemberPool,
    encoded: []const u8,
    encoded_max: usize,
    decoded_max: usize,
    output_length: usize,
    expected: pool_module.Result,
) !void {
    var output: [64]u8 = undefined;
    @memset(&output, 0xa5);
    const lease = pool.acquire(
        owner(10),
        output[0..output_length],
        .{ .encoded_max = encoded_max, .decoded_max = decoded_max },
    ) orelse return error.TestUnexpectedResult;
    switch (try feedWithBackpressureMember(pool, lease, encoded)) {
        .all_written => pool.finish(lease) catch |err| switch (err) {
            error.JobTerminal => {},
            else => return err,
        },
        .terminal => {},
    }
    try expectSame(expected, try waitResult(pool, lease));
    try expectZero(output[0..output_length]);
    try ackEventually(pool, lease);
}

pub fn feedFragmented(
    pool: *Pool,
    lease: pool_module.Lease,
    bytes: []const u8,
    fragment_size: usize,
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + fragment_size);
        switch (try pool.feed(lease, bytes[offset..end])) {
            .written => offset = end,
            .full => std.Thread.yield() catch {},
        }
    }
}

pub fn feedWithBackpressure(
    pool: *SmallPool,
    lease: pool_module.Lease,
    bytes: []const u8,
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 8);
        switch (try pool.feed(lease, bytes[offset..end])) {
            .written => offset = end,
            .full => {
                if (try pool.shouldWaitForSpace(lease)) {
                    try waitAndTakeSpace(pool);
                }
            },
        }
    }
}

pub const FeedOutcome = enum { all_written, terminal };

pub fn feedWithBackpressureMember(
    pool: *MemberPool,
    lease: pool_module.Lease,
    bytes: []const u8,
) !FeedOutcome {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 32);
        const result = pool.feed(lease, bytes[offset..end]) catch |err| switch (err) {
            error.JobTerminal => return .terminal,
            else => return err,
        };
        switch (result) {
            .written => offset = end,
            .full => std.Thread.yield() catch {},
        }
    }
    return .all_written;
}

pub fn waitAndTakeSpace(pool: *SmallPool) !void {
    for (0..1_000_000) |_| {
        const batch = try consumedBatch(SmallPool, pool);
        if (batch.slots[0].space) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn waitResult(pool: anytype, lease: pool_module.Lease) !pool_module.Result {
    for (0..1_000_000) |_| {
        if (try pool.result(lease)) |result| {
            try takeTerminal(@TypeOf(pool.*), pool, lease.index);
            return result;
        }
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn waitForTerminalState(
    comptime PoolType: type,
    pool: *PoolType,
    lease: pool_module.Lease,
) !void {
    for (0..1_000_000) |_| {
        if (try pool.result(lease) != null) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn waitForCondition(comptime condition: fn () bool) !void {
    for (0..1_000_000) |_| {
        if (condition()) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn takeTerminal(comptime PoolType: type, pool: *PoolType, index: u16) !void {
    for (0..1_000_000) |_| {
        if (pool.slots[index].terminal_consumed) return;
        const batch = try consumedBatch(PoolType, pool);
        if (batch.slots[index].terminal) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn ackEventually(pool: anytype, lease: pool_module.Lease) !void {
    for (0..1_000_000) |_| {
        pool.ack(lease) catch |err| switch (err) {
            error.SignalsPending => {
                _ = try consumedBatch(@TypeOf(pool.*), pool);
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.TestUnexpectedResult;
}

pub fn expectComplete(
    result: pool_module.Result,
    encoded_count: usize,
    expected: []const u8,
    output: []const u8,
) !void {
    const counts = switch (result) {
        .complete => |complete| complete,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(encoded_count, counts.encoded);
    try std.testing.expectEqual(expected.len, counts.decoded);
    try std.testing.expectEqual(@as(usize, 1), counts.members);
    try std.testing.expectEqualStrings(expected, output[0..counts.decoded]);
}

pub fn expectStreamComplete(
    result: pool_module.Result,
    encoded_count: usize,
    decoded_count: usize,
) !void {
    const counts = switch (result) {
        .complete => |complete| complete,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(encoded_count, counts.encoded);
    try std.testing.expectEqual(decoded_count, counts.decoded);
    try std.testing.expectEqual(@as(usize, 1), counts.members);
}

pub fn expectTag(expected: std.meta.Tag(pool_module.Result), result: pool_module.Result) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(result));
}

pub fn expectSame(expected: pool_module.Result, actual: pool_module.Result) !void {
    try expectTag(std.meta.activeTag(expected), actual);
    if (expected == .over_limit) {
        try std.testing.expectEqual(expected.over_limit, actual.over_limit);
    }
}

pub fn expectZero(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

pub fn cleanStop(pool: anytype) void {
    const PoolType = @TypeOf(pool.*);
    if (pool.lifecycleStatus() == .running and pool.beginStop() != null) {
        @panic("gzip decoder pool test join failed");
    }
    if (pool.lifecycleStatus() == .quiesced) {
        _ = consumedBatch(PoolType, pool) catch {
            @panic("gzip decoder pool test wake drain failed");
        };
        for (0..PoolType.slots_len) |index| {
            const lease = pool.leaseAt(@intCast(index)) orelse continue;
            pool.ack(lease) catch {
                @panic("gzip decoder pool test job settlement failed");
            };
        }
        pool.retireWakePoll() catch {
            @panic("gzip decoder pool test poll retirement failed");
        };
    }
    if (pool.lifecycleStatus() == .stopped) return;
    const failure = pool.finishStop() catch {
        @panic("gzip decoder pool test close invariant failed");
    };
    if (failure != null) @panic("gzip decoder pool test close failed");
}

pub fn consumedBatch(comptime PoolType: type, pool: *PoolType) !PoolType.WakeBatch {
    return switch (pool.consumeWake()) {
        .consumed => |batch| batch,
        .failed => error.TestUnexpectedResult,
    };
}

pub fn exactLimits(encoded: []const u8, decoded_max: usize) pool_module.Limits {
    return .{ .encoded_max = encoded.len, .decoded_max = decoded_max };
}

pub fn owner(value: u16) pool_module.Owner {
    return .{
        .connection_index = value,
        .request_index = value +% 1,
        .generation = value +% 2,
    };
}

test {
    _ = @import("gzip_decoder_pool_test_part_1.zig");
    _ = @import("gzip_decoder_pool_test_part_2.zig");
}

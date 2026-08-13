const std = @import("std");

pub const InitError = error{
    CapacityZero,
    CapacityExceedsU16,
};

/// LIFO indices over caller-owned startup storage.
pub const SlotPool = struct {
    indices: []u16,
    free_count: u16,

    pub fn init(indices: []u16) InitError!SlotPool {
        if (indices.len == 0) return error.CapacityZero;
        if (indices.len > std.math.maxInt(u16)) return error.CapacityExceedsU16;

        for (indices, 0..) |*slot, index| {
            slot.* = @intCast(indices.len - 1 - index);
        }
        return .{
            .indices = indices,
            .free_count = @intCast(indices.len),
        };
    }

    pub fn acquire(pool: *SlotPool) ?u16 {
        if (pool.free_count == 0) return null;
        pool.free_count -= 1;
        return pool.indices[pool.free_count];
    }

    pub fn release(pool: *SlotPool, index: u16) void {
        if (index >= pool.indices.len or pool.free_count >= pool.indices.len) {
            @panic("slot pool release invariant");
        }
        pool.indices[pool.free_count] = index;
        pool.free_count += 1;
    }

    pub fn available(pool: *const SlotPool) u16 {
        return pool.free_count;
    }

    pub fn capacity(pool: *const SlotPool) u16 {
        return @intCast(pool.indices.len);
    }
};

test "slot pool is bounded deterministic and reusable" {
    var indices: [3]u16 = undefined;
    var pool = try SlotPool.init(&indices);

    try std.testing.expectEqual(@as(u16, 3), pool.capacity());
    try std.testing.expectEqual(@as(?u16, 0), pool.acquire());
    try std.testing.expectEqual(@as(?u16, 1), pool.acquire());
    try std.testing.expectEqual(@as(?u16, 2), pool.acquire());
    try std.testing.expectEqual(@as(?u16, null), pool.acquire());
    try std.testing.expectEqual(@as(u16, 0), pool.available());

    pool.release(1);
    try std.testing.expectEqual(@as(?u16, 1), pool.acquire());
    pool.release(0);
    pool.release(2);
    pool.release(1);
    try std.testing.expectEqual(@as(u16, 3), pool.available());
}

test "slot pool rejects invalid capacities" {
    var none: [0]u16 = .{};
    try std.testing.expectError(error.CapacityZero, SlotPool.init(&none));
}

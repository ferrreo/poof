const std = @import("std");
const slot_pool = @import("../slot_pool.zig");
const storage_slab = @import("storage_slab.zig");

pub fn Pool(comptime State: type, comptime enabled: bool) type {
    return if (enabled) struct {
        free_indices: []u16,
        states: []State,
        pool: slot_pool.SlotPool,
    } else struct {};
}

pub fn init(
    comptime State: type,
    comptime enabled: bool,
    storage: []u8,
    indices_offset: usize,
    states_offset: usize,
    count: u16,
) Pool(State, enabled) {
    if (enabled) {
        const indices = storage_slab.typedSlice(u16, storage, indices_offset, count);
        const states = storage_slab.typedSlice(State, storage, states_offset, count);
        return .{
            .free_indices = indices,
            .states = states,
            .pool = slot_pool.SlotPool.init(indices) catch unreachable,
        };
    }
    return .{};
}

pub fn clear(comptime State: type, pool: *Pool(State, true), index: u16) void {
    std.crypto.secureZero(u8, std.mem.asBytes(&pool.states[index]));
}

pub fn reset(comptime State: type, pool: *Pool(State, true)) void {
    std.crypto.secureZero(u8, std.mem.sliceAsBytes(pool.states));
    pool.pool = slot_pool.SlotPool.init(pool.free_indices) catch unreachable;
}

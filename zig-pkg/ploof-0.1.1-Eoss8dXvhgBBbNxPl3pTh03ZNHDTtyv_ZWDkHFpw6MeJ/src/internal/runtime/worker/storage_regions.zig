const std = @import("std");

const storage_slab = @import("storage_slab.zig");

pub fn htmlJsonScratch(storage: anytype, limit: u32, comptime bytes: u32) []u8 {
    if (comptime bytes == 0) {
        std.debug.assert(limit == 0);
        return storage.response_storage[0..0];
    }
    std.debug.assert(limit <= storage.html_json_scratch.len);
    return storage.html_json_scratch[0..limit];
}

pub fn liveStaticPath(
    storage: anytype,
    index: u16,
    comptime slot_count: u16,
    comptime bytes: u32,
) []u8 {
    std.debug.assert(index < slot_count);
    return storage_slab.region(storage.live_static_paths, index, bytes);
}

pub fn liveStaticRead(
    storage: anytype,
    index: u16,
    comptime slot_count: u16,
    comptime bytes: u32,
) []u8 {
    std.debug.assert(index < slot_count);
    return storage_slab.region(storage.live_static_reads, index, bytes);
}

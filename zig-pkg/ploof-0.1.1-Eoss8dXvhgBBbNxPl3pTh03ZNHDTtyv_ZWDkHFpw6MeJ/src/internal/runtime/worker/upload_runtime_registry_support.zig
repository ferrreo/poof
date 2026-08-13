const std = @import("std");

const reactor = @import("../reactor.zig");
const upload_transport = @import("../upload/transport.zig");

pub fn runtimeIndex(cursor: u32, phase: anytype, cleanup_index: u16) u16 {
    return switch (phase) {
        .start => @intCast(cursor),
        .stop => @intCast(cursor - 1),
        .cleanup => cleanup_index,
    };
}

pub fn runtimeOwner(worker_index: u16, registry_index: u16) upload_transport.Owner {
    return .{
        .scope = .runtime,
        .registry_index = registry_index,
        .instance_index = 0,
        .slot = .{
            .worker_index = worker_index,
            .index = reactor.upload_runtime_control_slot,
            .generation = 1,
        },
    };
}

pub fn deriveEntropy(seed: *const [32]u8, registry_index: u16, result: *[32]u8) void {
    var input: [34]u8 = undefined;
    defer std.crypto.secureZero(u8, &input);
    @memcpy(input[0..32], seed);
    std.mem.writeInt(u16, input[32..34], registry_index, .little);
    std.crypto.hash.Blake3.hash(&input, result, .{});
}

test "runtime cleanup retains maximum u16 sink index after cursor reaches capacity" {
    const RuntimePhase = enum(u2) { start, stop, cleanup };
    const index = std.math.maxInt(u16);
    try std.testing.expectEqual(index, runtimeIndex(65_536, RuntimePhase.cleanup, index));
    try std.testing.expectEqual(index, runtimeIndex(65_536, RuntimePhase.stop, 0));
}

test {
    std.testing.refAllDecls(@This());
}

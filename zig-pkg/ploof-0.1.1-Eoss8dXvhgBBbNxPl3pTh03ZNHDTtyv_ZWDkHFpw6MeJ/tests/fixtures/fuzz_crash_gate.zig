const std = @import("std");
const builtin = @import("builtin");

fn crashOnlyUnderFuzz(_: void, _: *std.testing.Smith) !void {
    if (builtin.fuzz) @panic("deliberate fuzz driver gate crash");
}

test "fuzz driver deliberate crash fixture passes outside fuzz mode" {
    try std.testing.fuzz({}, crashOnlyUnderFuzz, .{ .corpus = &.{"gate"} });
}

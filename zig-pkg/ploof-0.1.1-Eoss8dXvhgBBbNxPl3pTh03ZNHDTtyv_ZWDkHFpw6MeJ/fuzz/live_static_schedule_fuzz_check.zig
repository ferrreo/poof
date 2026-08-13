const std = @import("std");
const live_static = @import("../tests/unit/internal/runtime/worker_live_static_test.zig");
const static_policy = @import("static_file_fuzz_check.zig");

test "live static policy and production controller structured fuzz" {
    try std.testing.fuzz({}, fuzzAll, .{ .corpus = &fuzz_corpus });
}

fn fuzzAll(_: void, smith: *std.testing.Smith) !void {
    try static_policy.fuzzPolicy({}, smith);
    try live_static.fuzzLiveStaticControllerSchedule({}, smith);
}

/// Stable corpus member for direct reproduction before minimizing a discovered input.
pub const replay_seed = [_]u8{
    0x6c, 0x69, 0x76, 0x65, 0x2d, 0x73, 0x74, 0x61,
    0x74, 0x69, 0x63, 0x2d, 0x73, 0x65, 0x65, 0x64,
} ** 8;

const fuzz_corpus = [_][]const u8{
    &replay_seed,
    &([_]u8{0x00} ** 128),
    &([_]u8{0xff} ** 128),
    &([_]u8{ 0x00, 0xff, 0x55, 0xaa } ** 32),
};

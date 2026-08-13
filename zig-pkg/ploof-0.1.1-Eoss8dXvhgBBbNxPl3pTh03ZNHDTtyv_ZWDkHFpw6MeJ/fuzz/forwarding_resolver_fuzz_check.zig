const std = @import("std");
const support = @import("forwarding_fuzz_check.zig");

test "forwarding resolver structured fuzz preserves trusted suffix identity" {
    try std.testing.fuzz({}, support.fuzzResolver, .{
        .corpus = &support.fuzz_corpus,
    });
}

const std = @import("std");
const support = @import("forwarding_fuzz_check.zig");

test "authority parser has deterministic variable-length outcomes" {
    try std.testing.fuzz({}, support.fuzzAuthority, .{
        .corpus = &support.authority_corpus,
    });
}

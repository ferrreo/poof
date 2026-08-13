const std = @import("std");
const support = @import("forwarding_fuzz_check.zig");

test "Forwarded parser variable-length fuzz is deterministic and bounded" {
    try std.testing.fuzz({}, support.fuzzForwardedParser, .{
        .corpus = &support.forwarded_parser_corpus,
    });
}

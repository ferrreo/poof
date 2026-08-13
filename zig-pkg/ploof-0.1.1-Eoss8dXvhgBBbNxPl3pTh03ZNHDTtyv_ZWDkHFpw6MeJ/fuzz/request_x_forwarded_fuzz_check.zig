const std = @import("std");
const support = @import("forwarding_fuzz_check.zig");

test "X-Forwarded parser variable-length fuzz is deterministic and bounded" {
    try std.testing.fuzz({}, support.fuzzXForwardedParser, .{
        .corpus = &support.x_parser_corpus,
    });
}

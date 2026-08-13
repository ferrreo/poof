const std = @import("std");

pub fn expectAtEverySplit(comptime Parser: type, input: []const u8) !void {
    for (0..input.len + 1) |split| {
        var bulk = Parser.init();
        var scalar = Parser.init();

        const bulk_first = bulk.feed(input[0..split]);
        const scalar_first = Parser.TestAccess.feedScalar(&scalar, input[0..split]);
        try expectFeedEquivalent(&bulk, bulk_first, &scalar, scalar_first);

        const bulk_second = bulk.feed(input[split..]);
        const scalar_second = Parser.TestAccess.feedScalar(&scalar, input[split..]);
        try expectFeedEquivalent(&bulk, bulk_second, &scalar, scalar_second);
    }
}

pub fn expectFeedEquivalent(
    left: anytype,
    left_result: anytype,
    right: anytype,
    right_result: anytype,
) !void {
    try std.testing.expectEqual(left_result.consumed, right_result.consumed);
    try expectParserStateEquivalent(left, left_result, right, right_result);
}

pub fn expectParserStateEquivalent(
    left: anytype,
    left_result: anytype,
    right: anytype,
    right_result: anytype,
) !void {
    try std.testing.expectEqual(
        std.meta.activeTag(left_result.state),
        std.meta.activeTag(right_result.state),
    );
    try std.testing.expectEqualSlices(u8, left.bytes(), right.bytes());
    try std.testing.expectEqualDeep(left.fields(), right.fields());
    switch (left_result.state) {
        .need_more => {},
        .ready => |head| try std.testing.expectEqualDeep(head, right_result.state.ready),
        .rejected => |rejection| {
            try std.testing.expectEqualDeep(rejection, right_result.state.rejected);
        },
    }
}

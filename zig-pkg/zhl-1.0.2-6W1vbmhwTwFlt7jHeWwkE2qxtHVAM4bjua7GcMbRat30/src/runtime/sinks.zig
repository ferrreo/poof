const engine = @import("engine.zig");
const token = @import("token.zig");

pub const NullSink = struct {
    count: usize = 0,

    pub fn emit(self: *NullSink, tok: token.Token) engine.HighlightError!void {
        _ = tok;
        self.count += 1;
    }
};

pub const DebugSink = TokenBuffer(4096);

pub fn TokenBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        tokens: [capacity]token.Token = undefined,
        count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn emit(self: *Self, tok: token.Token) engine.HighlightError!void {
            if (tok.end <= tok.start) return;
            if (self.count > 0) {
                const last = &self.tokens[self.count - 1];
                if (last.end == tok.start and last.style_id == tok.style_id and last.scope_stack_id == tok.scope_stack_id and last.language_id == tok.language_id) {
                    last.end = tok.end;
                    return;
                }
            }
            if (self.count == capacity) return error.TokenOverflow;
            self.tokens[self.count] = tok;
            self.count += 1;
        }

        pub fn slice(self: *const Self) []const token.Token {
            return self.tokens[0..self.count];
        }

        pub fn reset(self: *Self) void {
            self.count = 0;
        }
    };
}

test "TokenBuffer merges adjacent same-style tokens" {
    const std = @import("std");
    var sink = TokenBuffer(4).init();
    try sink.emit(.{ .start = 0, .end = 1, .style_id = .plain });
    try sink.emit(.{ .start = 1, .end = 2, .style_id = .plain });
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(@as(u32, 2), sink.tokens[0].end);
}

test "TokenBuffer keeps adjacent language ids distinct" {
    const std = @import("std");
    var sink = TokenBuffer(4).init();
    try sink.emit(.{ .start = 0, .end = 1, .style_id = .plain });
    try sink.emit(.{ .start = 1, .end = 2, .style_id = .plain, .language_id = 1 });
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "TokenBuffer drops empty tokens and resets" {
    const std = @import("std");
    var sink = TokenBuffer(2).init();
    try sink.emit(.{ .start = 1, .end = 1, .style_id = .keyword });
    try std.testing.expectEqual(@as(usize, 0), sink.slice().len);
    try sink.emit(.{ .start = 1, .end = 2, .style_id = .keyword });
    try std.testing.expectEqual(@as(usize, 1), sink.slice().len);
    sink.reset();
    try std.testing.expectEqual(@as(usize, 0), sink.slice().len);
}

test "TokenBuffer reports overflow" {
    const std = @import("std");
    var sink = TokenBuffer(1).init();
    try sink.emit(.{ .start = 0, .end = 1, .style_id = .keyword });
    try std.testing.expectError(error.TokenOverflow, sink.emit(.{ .start = 2, .end = 3, .style_id = .string }));
}

test "DebugSink matches documented sink API" {
    const std = @import("std");
    var sink = DebugSink.init();
    try sink.emit(.{ .start = 1, .end = 3, .style_id = .keyword });
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try std.testing.expectEqual(@as(u32, 3), sink.tokens[0].end);
}

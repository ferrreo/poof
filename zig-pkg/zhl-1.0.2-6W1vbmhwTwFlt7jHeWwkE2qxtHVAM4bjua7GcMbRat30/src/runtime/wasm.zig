const token = @import("token.zig");

pub const TokenAbi = extern struct {
    start: u32,
    end: u32,
    style_id: u16,
    scope_stack_id: u16,
    language_id: u16,
    flags: u16 = 0,
};

pub fn toAbi(tok: token.Token) TokenAbi {
    return .{
        .start = tok.start,
        .end = tok.end,
        .style_id = @intFromEnum(tok.style_id),
        .scope_stack_id = @intFromEnum(tok.scope_stack_id),
        .language_id = tok.language_id,
    };
}

pub fn copyTokens(out: []TokenAbi, tokens: []const token.Token) usize {
    const n = @min(out.len, tokens.len);
    for (tokens[0..n], 0..) |tok, i| out[i] = toAbi(tok);
    return n;
}

test "WASM token ABI is stable and compact" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TokenAbi));
    const tok = token.Token{ .start = 1, .end = 3, .style_id = .keyword, .scope_stack_id = .keyword, .language_id = 7 };
    const abi = toAbi(tok);
    try std.testing.expectEqual(@as(u32, 1), abi.start);
    try std.testing.expectEqual(@as(u16, @intFromEnum(token.StyleId.keyword)), abi.style_id);
    try std.testing.expectEqual(@as(u16, 7), abi.language_id);
}

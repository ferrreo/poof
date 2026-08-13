const std = @import("std");
const token_source = @import("token_source.zig");

pub fn isString(token: token_source.RawToken) bool {
    return switch (token) {
        .string,
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => true,
        else => false,
    };
}

pub fn expect(
    actual: token_source.RawToken,
    comptime expected: std.meta.Tag(token_source.RawToken),
) error{TypeMismatch}!void {
    if (std.meta.activeTag(actual) != expected) return error.TypeMismatch;
}

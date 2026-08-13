//! poof library root. Public declarations here are importable via `@import("poof")`.
const std = @import("std");

pub fn greeting(name: []const u8) []const u8 {
    return if (name.len == 0) "poof!" else name;
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "greeting falls back to default" {
    try std.testing.expectEqualStrings("poof!", greeting(""));
    try std.testing.expectEqualStrings("world", greeting("world"));
}

test "add" {
    try std.testing.expectEqual(@as(i32, 10), add(3, 7));
}

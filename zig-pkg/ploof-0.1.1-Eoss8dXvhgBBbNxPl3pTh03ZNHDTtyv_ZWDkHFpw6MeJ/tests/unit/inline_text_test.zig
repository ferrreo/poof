const std = @import("std");
const inline_text = @import("../../src/inline_text.zig");

test "InlineText stores bounded UTF-8 by value with zero padding" {
    const Text = inline_text.InlineText(16);
    const text = try Text.init("caf\xc3\xa9");
    const text_bytes = try text.bytes();
    try std.testing.expectEqualStrings("caf\xc3\xa9", text_bytes);
    try std.testing.expectEqual(@as(usize, 5), text_bytes.len);
    for (text.storage[text_bytes.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    const copy = try text.validatedCopy();
    try std.testing.expectEqualStrings(text_bytes, try copy.bytes());
    try std.testing.expectError(error.TooLong, Text.init("a" ** 17));
    try std.testing.expectError(error.InvalidUtf8, Text.init("\xff"));
}

test "InlineText formats directly into inline bounded storage" {
    const Text = inline_text.InlineText(32);
    const text = try Text.print("item-{d}-{s}", .{ 42, "ok" });
    try std.testing.expectEqualStrings("item-42-ok", try text.bytes());

    const Tiny = inline_text.InlineText(3);
    try std.testing.expectError(error.TooLong, Tiny.print("{d}", .{1000}));
}

test "InlineText revalidates public length UTF-8 and padding" {
    const Text = inline_text.InlineText(8);
    var text = try Text.init("ok");
    text.storage[0] = 0xff;
    try std.testing.expectError(error.InvalidUtf8, text.validatedCopy());

    text = try Text.init("ok");
    text.storage[7] = 0xa5;
    const restored = try text.validatedCopy();
    const restored_bytes = try restored.bytes();
    try std.testing.expectEqualStrings("ok", restored_bytes);
    for (restored.storage[restored_bytes.len..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "InlineText exact maximum is accepted" {
    const Text = inline_text.InlineText(64 * 1024);
    const input = "a" ** (64 * 1024);
    const text = try Text.init(input);
    try std.testing.expectEqual(@as(usize, 64 * 1024), (try text.bytes()).len);
}

test "InlineText bytes reject forged lengths and accept direct-zero state" {
    const Text = inline_text.InlineText(8);
    var text = std.mem.zeroes(Text);
    try std.testing.expectEqual(@as(usize, 0), (try text.bytes()).len);

    text.length = 15;
    try std.testing.expectError(error.TooLong, text.bytes());
    try std.testing.expectError(error.TooLong, text.validatedCopy());
}

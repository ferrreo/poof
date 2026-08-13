const Self = @This();

words: [4]u64 = .{ 0, 0, 0, 0 },

pub fn empty() Self {
    return .{};
}

pub fn fromBytes(comptime bytes: []const u8) Self {
    var mask = Self.empty();
    inline for (bytes) |byte| {
        mask.set(byte);
    }
    return mask;
}

pub fn set(self: *Self, byte: u8) void {
    const word: usize = @intCast(byte >> 6);
    const shift: u6 = @intCast(byte & 63);
    self.words[word] |= (@as(u64, 1) << shift);
}

pub fn contains(self: Self, byte: u8) bool {
    const word: usize = @intCast(byte >> 6);
    const shift: u6 = @intCast(byte & 63);
    return (self.words[word] & (@as(u64, 1) << shift)) != 0;
}

test "ByteMask256 contains selected bytes" {
    const std = @import("std");
    const mask = Self.fromBytes(&.{ 'a', 'Z', '0', '_' });
    try std.testing.expect(mask.contains('a'));
    try std.testing.expect(mask.contains('Z'));
    try std.testing.expect(mask.contains('0'));
    try std.testing.expect(mask.contains('_'));
    try std.testing.expect(!mask.contains('b'));
}

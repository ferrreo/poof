const std = @import("std");

pub const none = std.math.maxInt(u16);

/// Worker-local finite response storage. The owning runtime validates indices.
pub const Chain = struct {
    head: u16 = none,
    tail: u16 = none,
    chunks: u16 = 0,
    bytes: u32 = 0,

    pub fn isEmpty(self: Chain) bool {
        return self.chunks == 0;
    }
};

test "empty response chunk chain uses only sentinels" {
    const chain = Chain{};
    try std.testing.expect(chain.isEmpty());
    try std.testing.expectEqual(none, chain.head);
    try std.testing.expectEqual(none, chain.tail);
    try std.testing.expectEqual(@as(u32, 0), chain.bytes);
}

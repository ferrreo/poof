const std = @import("std");

pub fn smithInput(comptime value: []const u8) [value.len + 4]u8 {
    var input: [value.len + 4]u8 = undefined;
    const length: u32 = @intCast(value.len);
    input[0] = @truncate(length);
    input[1] = @truncate(length >> 8);
    input[2] = @truncate(length >> 16);
    input[3] = @truncate(length >> 24);
    @memcpy(input[4..], value);
    return input;
}

pub fn smithInputThenU64(
    comptime value: []const u8,
    comptime integer: u64,
) [value.len + 12]u8 {
    const slice_input = smithInput(value);
    var input: [value.len + 12]u8 = undefined;
    @memcpy(input[0..slice_input.len], &slice_input);
    inline for (0..8) |index| {
        input[slice_input.len + index] = @truncate(integer >> (index * 8));
    }
    return input;
}

test "Smith corpus encoders round-trip every generated primitive" {
    const slice_only = smithInput("abc");
    var slice_smith = std.testing.Smith{ .in = &slice_only };
    var slice_storage: [8]u8 = undefined;
    const slice_length = slice_smith.slice(&slice_storage);
    try std.testing.expectEqualStrings("abc", slice_storage[0..slice_length]);

    const slice_and_integer = smithInputThenU64("chunk", 600);
    var combined_smith = std.testing.Smith{ .in = &slice_and_integer };
    var combined_storage: [8]u8 = undefined;
    const combined_length = combined_smith.slice(&combined_storage);
    try std.testing.expectEqualStrings("chunk", combined_storage[0..combined_length]);
    try std.testing.expectEqual(
        @as(u16, 600),
        combined_smith.valueRangeAtMost(u16, 0, 600),
    );
}

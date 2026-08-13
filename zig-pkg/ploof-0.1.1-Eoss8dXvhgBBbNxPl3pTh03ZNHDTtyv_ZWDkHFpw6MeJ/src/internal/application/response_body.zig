const std = @import("std");

pub const standard_bytes_max: usize = 16 * 1024;
pub const hard_bytes_max: usize = 16 * 1024 * 1024;

pub fn bytesMax(comptime config: anytype) usize {
    const Config = @TypeOf(config);
    if (!@hasField(Config, "response_body_bytes_max")) return standard_bytes_max;
    const value = config.response_body_bytes_max;
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .comptime_int => {
            if (value < 0 or value > hard_bytes_max) invalid();
        },
        .int => |integer| {
            if (integer.signedness == .signed and value < 0) invalid();
            if (@as(u128, @intCast(value)) > hard_bytes_max) invalid();
        },
        else => @compileError(
            "PLOOF-E3090 response_body_bytes_max must be an integer",
        ),
    }
    return @intCast(value);
}

fn invalid() noreturn {
    @compileError("PLOOF-E3091 response_body_bytes_max must be between zero and 16 MiB");
}

test "response body storage defaults low and accepts explicit disable or maximum" {
    try std.testing.expectEqual(standard_bytes_max, bytesMax(.{}));
    try std.testing.expectEqual(@as(usize, 0), bytesMax(.{ .response_body_bytes_max = 0 }));
    try std.testing.expectEqual(
        hard_bytes_max,
        bytesMax(.{ .response_body_bytes_max = hard_bytes_max }),
    );
}

const std = @import("std");

pub const bytes_hard_max: u32 = 64 * 1024;

pub const Error = error{
    InvalidUtf8,
    TooLong,
};

pub fn InlineText(comptime bytes_max: u32) type {
    if (bytes_max == 0) {
        @compileError("PLOOF-E3705 InlineText byte limit must be nonzero");
    }
    if (bytes_max > bytes_hard_max) {
        @compileError("PLOOF-E3706 InlineText byte limit exceeds 64 KiB");
    }
    const Length = std.math.IntFittingRange(0, bytes_max);
    return struct {
        storage: [bytes_max]u8,
        length: Length,

        pub const ploof_inline_text = true;
        pub const bytes_maximum = bytes_max;
        const Self = @This();

        pub fn init(input: []const u8) Error!Self {
            if (input.len > bytes_max) return error.TooLong;
            if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
            var result = Self{
                .storage = [_]u8{0} ** bytes_max,
                .length = @intCast(input.len),
            };
            @memcpy(result.storage[0..input.len], input);
            return result;
        }

        pub fn print(comptime format: []const u8, arguments: anytype) Error!Self {
            var result = Self{
                .storage = [_]u8{0} ** bytes_max,
                .length = 0,
            };
            var writer = std.Io.Writer.fixed(&result.storage);
            writer.print(format, arguments) catch return error.TooLong;
            const written = writer.buffered().len;
            if (!std.unicode.utf8ValidateSlice(result.storage[0..written])) {
                return error.InvalidUtf8;
            }
            result.length = @intCast(written);
            return result;
        }

        pub fn bytes(text: *const Self) Error![]const u8 {
            const length: u32 = @intCast(text.length);
            if (length > bytes_max) return error.TooLong;
            return text.storage[0..length];
        }

        pub fn validatedCopy(text: *const Self) Error!Self {
            const length: u32 = @intCast(text.length);
            if (length > bytes_max) return error.TooLong;
            return init(text.storage[0..length]);
        }
    };
}

comptime {
    std.debug.assert(bytes_hard_max > 0);
}

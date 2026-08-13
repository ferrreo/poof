const std = @import("std");

pub const Error = error{EntropyUnavailable};

pub fn fill(output: []u8) Error!void {
    errdefer std.crypto.secureZero(u8, output);
    var used: usize = 0;
    while (used < output.len) {
        const remaining = output[used..];
        const result = std.os.linux.getrandom(remaining.ptr, remaining.len, 0);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const count: usize = @intCast(result);
                if (count == 0 or count > remaining.len) return error.EntropyUnavailable;
                used += count;
            },
            .INTR => continue,
            else => return error.EntropyUnavailable,
        }
    }
}

test "kernel entropy fills the complete caller buffer" {
    var output = [_]u8{0} ** 32;
    try fill(&output);
    try std.testing.expect(!std.mem.allEqual(u8, &output, 0));
}

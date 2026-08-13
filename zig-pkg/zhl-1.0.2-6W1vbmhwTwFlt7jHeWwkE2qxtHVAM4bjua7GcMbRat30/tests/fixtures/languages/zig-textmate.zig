const std = @import("std");

pub fn main() void {
    const Thing = struct { field: u32 };
    std.debug.print("value={d}\n", .{42});
    // done
}

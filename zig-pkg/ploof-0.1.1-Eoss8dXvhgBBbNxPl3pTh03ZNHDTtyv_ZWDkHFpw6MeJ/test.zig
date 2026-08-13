const std = @import("std");
const ploof = @import("src/ploof.zig");

test "public declarations are reachable" {
    std.testing.refAllDecls(ploof);
    _ = @import("tests/root.zig");
    _ = @import("fuzz/root.zig");
}

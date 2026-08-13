const ploof = @import("ploof_compile").ploof;

fn handler() void {}

pub fn main() void {
    const descriptor = ploof.get("/users/:id", handler);
    var output: [64]u8 = undefined;
    _ = ploof.urlFor(
        descriptor,
        .{ .id = @as(u8, 1), .other = @as(u8, 2) },
        .{},
        &output,
    ) catch {};
}

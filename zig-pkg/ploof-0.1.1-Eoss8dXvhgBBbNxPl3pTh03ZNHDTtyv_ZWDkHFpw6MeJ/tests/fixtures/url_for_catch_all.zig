const ploof = @import("ploof_compile").ploof;

fn handler() void {}

pub fn main() void {
    const descriptor = ploof.get("/files/*path", handler);
    var output: [64]u8 = undefined;
    _ = ploof.urlFor(descriptor, .{ .path = "a/b" }, .{}, &output) catch {};
}

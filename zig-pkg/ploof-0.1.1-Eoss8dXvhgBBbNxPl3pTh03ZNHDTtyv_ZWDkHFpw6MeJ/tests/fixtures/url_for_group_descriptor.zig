const ploof = @import("ploof_compile").ploof;

fn handler() void {}

pub fn main() void {
    const grouped = comptime ploof.group("/v1", .{}, .{ploof.get("/users", handler)});
    var output: [64]u8 = undefined;
    _ = ploof.urlFor(grouped, .{}, .{}, &output) catch {};
}

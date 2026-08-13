const ploof = @import("ploof_compile").ploof;

fn handler() void {}

const Query = struct {
    first: u8,
    second: u8,
    pub const ploof_flat_fields = .{ .first = "same", .second = "same" };
};

pub fn main() void {
    const descriptor = ploof.get("/search", handler);
    var output: [64]u8 = undefined;
    _ = ploof.urlFor(descriptor, .{}, Query{ .first = 1, .second = 2 }, &output) catch {};
}

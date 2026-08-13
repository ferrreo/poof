const ploof = @import("ploof_compile").ploof;

fn handler() void {}

pub fn main() void {
    const descriptor = ploof.get("/", handler);
    var output: [64]u8 = undefined;
    _ = ploof.urlForWith(
        descriptor,
        .{},
        .{},
        &output,
        .{ .query_pairs_max = 4097 },
    ) catch {};
}

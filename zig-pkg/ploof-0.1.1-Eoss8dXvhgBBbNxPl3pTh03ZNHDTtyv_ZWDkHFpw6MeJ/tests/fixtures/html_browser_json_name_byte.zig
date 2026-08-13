const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    var scratch: [32]u8 = undefined;
    var writer = Writer{};
    ploof.Html.writeBrowserJson(.{}, &writer, "bad.name", .{}, &scratch) catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

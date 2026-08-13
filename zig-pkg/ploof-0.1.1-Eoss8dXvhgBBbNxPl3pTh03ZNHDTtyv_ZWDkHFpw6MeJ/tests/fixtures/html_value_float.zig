const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeValue(&writer, .html_data, @as(f64, 1.5)) catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

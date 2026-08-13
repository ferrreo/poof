const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeStaticSvg(&writer, "<div></div>") catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

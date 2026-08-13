const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeTrustedHtml(&writer, "<b>raw</b>") catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

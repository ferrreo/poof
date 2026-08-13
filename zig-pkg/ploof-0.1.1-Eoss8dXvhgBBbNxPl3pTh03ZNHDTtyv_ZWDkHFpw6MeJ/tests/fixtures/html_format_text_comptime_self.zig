const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub fn formatText(comptime _: @This()) ploof.InlineText(8) {
        return ploof.InlineText(8).init("x") catch unreachable;
    }
};

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeValue(&writer, .html_data, Value{}) catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub const formatText = 1;
};

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeValue(&writer, .html_data, Value{}) catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

const std = @import("std");
const ploof = @import("ploof_compile").ploof;

const Value = struct {
    allocator: std.mem.Allocator,

    pub fn formatText(_: @This()) ploof.InlineText(8) {
        return ploof.InlineText(8).init("x") catch unreachable;
    }
};

pub fn main() void {
    var writer = Writer{};
    const value: Value = undefined;
    ploof.Html.writeValue(&writer, .html_data, value) catch {};
}

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

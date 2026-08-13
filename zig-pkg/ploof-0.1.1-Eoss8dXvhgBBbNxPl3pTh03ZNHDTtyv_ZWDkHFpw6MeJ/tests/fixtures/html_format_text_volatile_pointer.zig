const std = @import("std");
const ploof = @import("ploof_compile").ploof;

const Value = struct {
    register: *const volatile u32,

    pub fn formatText(_: @This()) ploof.InlineText(8) {
        return ploof.InlineText(8).init("x") catch unreachable;
    }
};

comptime {
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var register: u32 = 0;
    ploof.Html.writeValue(
        &writer,
        .html_data,
        Value{ .register = &register },
    ) catch unreachable;
}

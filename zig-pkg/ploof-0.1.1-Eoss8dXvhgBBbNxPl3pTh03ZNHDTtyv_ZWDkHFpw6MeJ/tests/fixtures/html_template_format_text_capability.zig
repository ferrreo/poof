const std = @import("std");
const ploof = @import("ploof_compile").ploof;

const Value = struct {
    allocator: std.mem.Allocator,

    pub fn formatText(_: @This()) ploof.InlineText(8) {
        return ploof.InlineText(8).init("x") catch unreachable;
    }
};

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: Value },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "format-text-capability",
        .file_path = "views/format-text-capability.html",
        .bytes = "{{view.value}}",
    },
});

comptime {
    _ = Page;
}

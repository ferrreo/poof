const ploof = @import("ploof_compile").ploof;

const Value = struct {
    register: *const volatile u32,

    pub fn formatText(_: @This()) ploof.InlineText(8) {
        return ploof.InlineText(8).init("x") catch unreachable;
    }
};

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: Value },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "format-text-volatile-pointer",
        .file_path = "views/format-text-volatile-pointer.html",
        .bytes = "{{view.value}}",
    },
});

comptime {
    _ = Page;
}

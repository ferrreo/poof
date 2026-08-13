const ploof = @import("ploof_compile").ploof;

const Text = ploof.InlineText(16);

const Value = struct {
    pub fn formatText(_: @This()) error{WriterTerminal}!Text {
        return error.WriterTerminal;
    }
};

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: Value },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "reserved-format-error",
        .file_path = "views/reserved-format-error.html",
        .bytes = "{{view.value}}",
    },
});

comptime {
    _ = Page;
}

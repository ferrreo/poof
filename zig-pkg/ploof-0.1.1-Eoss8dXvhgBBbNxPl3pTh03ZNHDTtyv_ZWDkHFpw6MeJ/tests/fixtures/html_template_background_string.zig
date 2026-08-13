const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { background: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "background-string",
        .file_path = "views/background-string.html",
        .bytes = "<table background=\"{{view.background}}\"></table>",
    },
});

comptime {
    _ = Page;
}

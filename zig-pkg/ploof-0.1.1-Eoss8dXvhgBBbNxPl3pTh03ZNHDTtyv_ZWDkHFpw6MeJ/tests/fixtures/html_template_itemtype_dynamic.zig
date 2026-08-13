const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "itemtype-dynamic",
        .file_path = "views/itemtype-dynamic.html",
        .bytes = "<div itemtype=\"{{view.value}}\"></div>",
    },
});

comptime {
    _ = Page;
}

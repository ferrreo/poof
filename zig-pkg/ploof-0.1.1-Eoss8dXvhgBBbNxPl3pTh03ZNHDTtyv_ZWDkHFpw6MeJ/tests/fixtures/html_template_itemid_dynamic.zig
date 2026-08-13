const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { id: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "itemid-dynamic",
        .file_path = "views/itemid-dynamic.html",
        .bytes = "<div itemid=\"{{view.id}}\"></div>",
    },
});

comptime {
    _ = Page;
}

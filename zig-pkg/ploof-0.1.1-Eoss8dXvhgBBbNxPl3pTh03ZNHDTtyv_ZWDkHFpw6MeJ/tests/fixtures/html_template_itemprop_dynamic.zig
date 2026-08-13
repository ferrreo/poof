const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "itemprop-dynamic",
        .file_path = "views/itemprop-dynamic.html",
        .bytes = "<div itemprop=\"{{view.value}}\"></div>",
    },
});

comptime {
    _ = Page;
}

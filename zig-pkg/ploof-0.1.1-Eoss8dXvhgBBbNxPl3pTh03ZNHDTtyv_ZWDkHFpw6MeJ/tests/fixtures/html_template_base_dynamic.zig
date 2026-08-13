const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { base: ploof.Url },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "base-dynamic",
        .file_path = "views/base-dynamic.html",
        .bytes = "<base href=\"{{view.base}}\">",
    },
});

comptime {
    _ = Page;
}

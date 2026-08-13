const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { url: ploof.Url },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-encoded-as",
        .file_path = "views/link-encoded-as.html",
        .bytes = "<link rel=\"preload\" as=\"scr&#105;pt\" href=\"{{view.url}}\">",
    },
});

comptime {
    _ = Page;
}

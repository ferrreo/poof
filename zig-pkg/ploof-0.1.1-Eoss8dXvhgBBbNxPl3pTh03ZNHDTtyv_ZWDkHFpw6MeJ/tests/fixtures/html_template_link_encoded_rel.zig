const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { url: ploof.Url },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-encoded-rel",
        .file_path = "views/link-encoded-rel.html",
        .bytes = "<link rel=\"style&#115;heet\" href=\"{{view.url}}\">",
    },
});

comptime {
    _ = Page;
}

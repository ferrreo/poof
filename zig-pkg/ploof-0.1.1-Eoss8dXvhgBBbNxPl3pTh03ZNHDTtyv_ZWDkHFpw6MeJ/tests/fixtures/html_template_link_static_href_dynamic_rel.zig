const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { rel: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-static-href-dynamic-rel",
        .file_path = "views/link-static-href-dynamic-rel.html",
        .bytes = "<link href=\"/theme.css\" rel=\"{{view.rel}}\">",
    },
});

comptime {
    _ = Page;
}

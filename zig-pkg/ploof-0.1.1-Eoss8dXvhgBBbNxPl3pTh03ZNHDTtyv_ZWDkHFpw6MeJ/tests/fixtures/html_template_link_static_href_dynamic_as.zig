const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { as: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-static-href-dynamic-as",
        .file_path = "views/link-static-href-dynamic-as.html",
        .bytes = "<link rel=\"preload\" href=\"/bundle\" as=\"{{view.as}}\">",
    },
});

comptime {
    _ = Page;
}

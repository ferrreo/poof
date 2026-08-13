const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { sandbox: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "iframe-sandbox-dynamic",
        .file_path = "views/iframe-sandbox-dynamic.html",
        .bytes = "<iframe src=\"/user-content.html\" " ++
            "sandbox=\"{{view.sandbox}}\"></iframe>",
    },
});

comptime {
    _ = Page;
}

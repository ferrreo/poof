const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { refresh: bool, target: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-conditional-http-equiv",
        .file_path = "views/meta-conditional-http-equiv.html",
        .bytes = "<meta{{#if view.refresh}} http-equiv=\"refresh\"{{else}} " ++
            "http-equiv=\"x\"{{/if}} content=\"{{view.target}}\">",
    },
});

comptime {
    _ = Page;
}

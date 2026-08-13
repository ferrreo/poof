const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { url: ploof.Url, active: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-conditional-rel",
        .file_path = "views/link-conditional-rel.html",
        .bytes = "<link href=\"{{view.url}}\"{{#if view.active}} " ++
            "rel=\"canonical\"{{else}} rel=\"stylesheet\"{{/if}}>",
    },
});

comptime {
    _ = Page;
}

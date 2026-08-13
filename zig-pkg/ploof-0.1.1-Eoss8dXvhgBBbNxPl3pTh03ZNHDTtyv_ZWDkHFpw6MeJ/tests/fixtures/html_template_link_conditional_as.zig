const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { url: ploof.Url, font: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "link-conditional-as",
        .file_path = "views/link-conditional-as.html",
        .bytes = "<link rel=\"preload\" href=\"{{view.url}}\"{{#if view.font}} " ++
            "as=\"font\"{{else}} as=\"script\"{{/if}}>",
    },
});

comptime {
    _ = Page;
}

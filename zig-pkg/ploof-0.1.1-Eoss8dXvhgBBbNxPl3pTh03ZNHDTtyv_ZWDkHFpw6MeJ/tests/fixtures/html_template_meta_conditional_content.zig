const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { alternate: bool, target: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-conditional-content",
        .file_path = "views/meta-conditional-content.html",
        .bytes = "<meta http-equiv=\"refresh\"{{#if view.alternate}} content=\"safe\"" ++
            "{{else}} content=\"{{view.target}}\"{{/if}}>",
    },
});

comptime {
    _ = Page;
}

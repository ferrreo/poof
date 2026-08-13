const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "render-operations-type",
        .file_path = "views/render-operations-type.html",
        .bytes = "",
    },
    .render_operations_max = "many",
});

comptime {
    _ = Page;
}

const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "render-operations-hard-max",
        .file_path = "views/render-operations-hard-max.html",
        .bytes = "",
    },
    .render_operations_max = 64 * 1024 * 1024 + 1,
});

comptime {
    _ = Page;
}

const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "render-operations-zero",
        .file_path = "views/render-operations-zero.html",
        .bytes = "",
    },
    .render_operations_max = 0,
});

comptime {
    _ = Page;
}

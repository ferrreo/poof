const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "assets-tuple",
        .file_path = "assets-tuple",
        .bytes = "plain",
    },
    .assets = .{1},
});

comptime {
    _ = Page;
}

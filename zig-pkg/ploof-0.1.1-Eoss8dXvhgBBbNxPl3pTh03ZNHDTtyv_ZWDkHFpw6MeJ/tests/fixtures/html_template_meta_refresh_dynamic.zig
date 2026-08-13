const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { target: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-refresh-dynamic",
        .file_path = "views/meta-refresh-dynamic.html",
        .bytes = "<meta http-equiv=\"refresh\" content=\"{{view.target}}\">",
    },
});

comptime {
    _ = Page;
}

const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { target: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-encoded-refresh",
        .file_path = "views/meta-encoded-refresh.html",
        .bytes = "<meta http-equiv=\"refre&#115;h\" content=\"{{view.target}}\">",
    },
});

comptime {
    _ = Page;
}

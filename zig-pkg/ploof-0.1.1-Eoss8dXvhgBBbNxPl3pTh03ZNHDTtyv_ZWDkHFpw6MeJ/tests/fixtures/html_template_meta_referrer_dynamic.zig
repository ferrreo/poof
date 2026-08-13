const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { policy: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-referrer-dynamic",
        .file_path = "views/meta-referrer-dynamic.html",
        .bytes = "<meta name=\"referrer\" content=\"{{view.policy}}\">",
    },
});

comptime {
    _ = Page;
}

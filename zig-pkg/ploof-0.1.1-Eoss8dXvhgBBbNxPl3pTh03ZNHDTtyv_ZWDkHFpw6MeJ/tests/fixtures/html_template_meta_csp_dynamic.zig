const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { policy: []const u8 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "meta-csp-dynamic",
        .file_path = "views/meta-csp-dynamic.html",
        .bytes = "<meta http-equiv=\"content-security-policy\" " ++
            "content=\"{{view.policy}}\">",
    },
});

comptime {
    _ = Page;
}

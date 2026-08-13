const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { urls: []const u8 },
    .source = fragment(
        "attribution-src-dynamic",
        "<img src=\"/pixel\" attributionsrc=\"{{view.urls}}\">",
    ),
});

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

comptime {
    _ = Page;
}

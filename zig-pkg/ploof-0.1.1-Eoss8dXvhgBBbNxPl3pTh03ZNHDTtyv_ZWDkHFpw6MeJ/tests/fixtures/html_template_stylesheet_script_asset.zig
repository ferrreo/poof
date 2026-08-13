const ploof = @import("ploof_compile").ploof;

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { source: *const ploof.AssetRef(.javascript) },
    .source = fragment(
        "stylesheet-script-asset",
        "<link rel=\"stylesheet\" href=\"{{view.source}}\">",
    ),
});

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

comptime {
    _ = Page;
}

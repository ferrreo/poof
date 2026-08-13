const ploof = @import("ploof_compile").ploof;
const fixture = @import("html_asset_fixture.zig");

const Assets = fixture.Bundle(.css, "a{}/* </StYlE attack */");
const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = fragment("inline-css-closing", "<style>{{@inlineCss critical}}</style>"),
    .assets = .{ .critical = Assets.local("asset.bin") },
});

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

comptime {
    _ = Page;
}

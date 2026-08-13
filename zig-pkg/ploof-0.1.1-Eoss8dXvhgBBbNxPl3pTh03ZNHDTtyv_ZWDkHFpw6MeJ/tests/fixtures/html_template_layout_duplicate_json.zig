const ploof = @import("ploof_compile").ploof;

const View = struct { state: u8 };

pub fn main() void {
    const Layout = ploof.HtmlTemplate.Template(.{
        .View = View,
        .source = ploof.HtmlSource.SourceSpec{
            .kind = .layout,
            .graph_name = "layout-json",
            .file_path = "layout-json.html",
            .bytes = "<!doctype html><html><head></head><body>" ++
                "{{@jsonData state view.state}}{{@body}}</body></html>",
        },
    });
    const Body = ploof.HtmlTemplate.Template(.{
        .View = View,
        .source = fragment("body-json", "{{@jsonData state view.state}}"),
    });
    _ = Layout.LayoutBodyView(Body);
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

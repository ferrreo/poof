const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct { state: u8 },
        .source = fragment("browser-json-limit", "{{@jsonData state view.state}}"),
        .browser_json = ploof.Html.BrowserJsonOptions{
            .encoded_bytes_max = 4_294_967_296,
        },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

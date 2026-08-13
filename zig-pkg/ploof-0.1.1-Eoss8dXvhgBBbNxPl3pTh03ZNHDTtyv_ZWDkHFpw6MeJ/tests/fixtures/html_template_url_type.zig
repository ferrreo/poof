const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { href: []const u8 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "url-type",
            .file_path = "url-type.html",
            .bytes = "<a href=\"{{view.href}}\">x</a>",
        },
    });
}

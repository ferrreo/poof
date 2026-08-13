const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { value: u32 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "unknown-partial",
            .file_path = "unknown-partial.html",
            .bytes = "{{> missing view}}",
        },
    });
}

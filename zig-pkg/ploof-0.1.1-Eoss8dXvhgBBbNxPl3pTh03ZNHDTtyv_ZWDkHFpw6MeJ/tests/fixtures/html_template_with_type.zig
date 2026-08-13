const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { value: u32 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "with-type",
            .file_path = "with-type.html",
            .bytes = "{{#with view.value as value}}{{value}}{{/with}}",
        },
    });
}

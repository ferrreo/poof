const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { value: u32 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "if-type",
            .file_path = "if-type.html",
            .bytes = "{{#if view.value}}x{{/if}}",
        },
    });
}

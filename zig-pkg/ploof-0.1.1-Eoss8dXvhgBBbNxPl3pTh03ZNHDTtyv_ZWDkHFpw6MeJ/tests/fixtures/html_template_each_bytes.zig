const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { value: []const u8 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "each-bytes",
            .file_path = "each-bytes.html",
            .bytes = "{{#each view.value as byte}}{{byte}}{{/each}}",
        },
    });
}

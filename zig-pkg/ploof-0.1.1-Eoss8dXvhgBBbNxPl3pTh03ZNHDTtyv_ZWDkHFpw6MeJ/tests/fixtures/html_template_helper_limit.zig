const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct {},
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "helper-limit",
            .file_path = "helper-limit.html",
            .bytes = "static",
        },
        .profile = source.TemplateSourceProfile{ .helper_arguments_max = 9 },
    });
}

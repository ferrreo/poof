const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { markup: ploof.Html.TrustedHtml(32) },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "trusted-html-context",
            .file_path = "trusted-html-context.html",
            .bytes = "<textarea>{{view.markup}}</textarea>",
        },
    });
}

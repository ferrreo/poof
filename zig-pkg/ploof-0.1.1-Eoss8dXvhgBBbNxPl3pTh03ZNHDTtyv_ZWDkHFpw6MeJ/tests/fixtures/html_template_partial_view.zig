const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { card: u32 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "partial-view",
            .file_path = "partial-view.html",
            .bytes = "{{> card view.card}}",
        },
        .partials = .{
            .card = .{
                .View = struct { label: []const u8 },
                .source = source.SourceSpec{
                    .kind = .fragment,
                    .graph_name = "card",
                    .file_path = "card.html",
                    .bytes = "card",
                },
            },
        },
    });
}

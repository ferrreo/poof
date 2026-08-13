const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;
const View = struct { value: u32 };

fn label(value: u32) u32 {
    return value;
}

pub fn main() void {
    _ = template.Template(.{
        .View = View,
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "parent",
            .file_path = "parent.html",
            .bytes = "{{> child view}}",
        },
        .helpers = .{ .label = label },
        .partials = .{
            .child = .{
                .View = View,
                .source = source.SourceSpec{
                    .kind = .fragment,
                    .graph_name = "child",
                    .file_path = "child.html",
                    .bytes = "{{label view.value}}",
                },
            },
        },
    });
}

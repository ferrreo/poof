const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

const View = struct {};

pub fn main() void {
    _ = template.Template(.{
        .View = View,
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "limited",
            .file_path = "limited.html",
            .bytes = "{{> child view}}",
        },
        .partials = .{
            .child = .{
                .View = View,
                .source = fragment("child", "{{> grand view}}"),
                .profile = source.TemplateSourceProfile{
                    .source_bytes_max = 64,
                    .graph_source_bytes_max = 64,
                },
                .partials = .{
                    .grand = .{
                        .View = View,
                        .source = fragment("grand", "x" ** 60),
                    },
                },
            },
        },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) source.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

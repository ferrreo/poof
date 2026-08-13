const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

const View = struct {};

pub fn main() void {
    _ = template.Template(.{
        .View = View,
        .source = fragment("root", "{{> child view}}"),
        .profile = source.TemplateSourceProfile{ .partial_call_depth_max = 1 },
        .partials = .{
            .child = .{
                .View = View,
                .source = fragment("child", "{{> grand view}}"),
                .partials = .{
                    .grand = .{
                        .View = View,
                        .source = fragment("grand", "grand"),
                    },
                },
            },
        },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) source.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

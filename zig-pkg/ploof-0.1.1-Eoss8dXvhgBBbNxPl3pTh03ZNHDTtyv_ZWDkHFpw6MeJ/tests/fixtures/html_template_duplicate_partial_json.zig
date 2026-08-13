const ploof = @import("ploof_compile").ploof;

const View = struct { state: u8 };

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = View,
        .source = fragment("duplicate-json", "{{> first view}}{{> second view}}"),
        .partials = .{
            .first = .{
                .View = View,
                .source = fragment("first", "{{@jsonData state view.state}}"),
            },
            .second = .{
                .View = View,
                .source = fragment("second", "{{@jsonData state view.state}}"),
            },
        },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

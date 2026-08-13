const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

const View = struct { child: *const View };

pub fn main() void {
    _ = template.Template(.{
        .View = View,
        .source = graphSource("{{> child view}}"),
        .partials = .{
            .child = .{
                .View = View,
                .source = graphSource("cycle"),
            },
        },
    });
}

fn graphSource(comptime bytes: []const u8) source.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = "cycle",
        .file_path = "cycle.html",
        .bytes = bytes,
    };
}

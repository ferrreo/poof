const ploof = @import("ploof_compile").ploof;

const Item = struct { state: u8 };

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct { items: []const Item },
        .source = fragment(
            "repeated-json",
            "{{#each view.items as item}}{{> row item}}{{/each}}",
        ),
        .partials = .{
            .row = .{
                .View = Item,
                .source = fragment("row", "{{@jsonData state view.state}}"),
            },
        },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

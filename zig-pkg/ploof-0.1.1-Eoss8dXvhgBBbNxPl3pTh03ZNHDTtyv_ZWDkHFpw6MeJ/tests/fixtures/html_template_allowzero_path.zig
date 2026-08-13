const ploof = @import("ploof_compile").ploof;

const Node = struct { label: []const u8 };

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct { node: *allowzero const Node },
        .source = fragment("allowzero-path", "{{view.node.label}}"),
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

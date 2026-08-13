const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

pub fn main() void {
    _ = template.Template(.{
        .View = struct { present: bool },
        .source = spec("unknown-field", "{{view.missing}}"),
    });
}

fn spec(comptime name: []const u8, comptime bytes: []const u8) source.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

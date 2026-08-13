const ploof = @import("ploof_compile").ploof;

fn bad(comptime value: u8) u8 {
    return value;
}

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct { value: u8 },
        .source = fragment("comptime-helper", "{{bad view.value}}"),
        .helpers = .{ .bad = bad },
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

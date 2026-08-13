const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct {},
        .encoded_bytes_max = "one mebibyte",
        .source = fragment("encoded-limit-type", "ok"),
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

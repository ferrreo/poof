const ploof = @import("ploof_compile").ploof;

pub fn main() void {
    _ = ploof.HtmlTemplate.Template(.{
        .View = struct {},
        .encoded_bytes_max = 64 * 1024 * 1024 + 1,
        .source = fragment("encoded-limit-hard-max", "ok"),
    });
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

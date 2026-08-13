const ploof = @import("ploof_compile").ploof;

const Writer = struct {
    pub fn write(_: *Writer, comptime _: []const u8) error{}!void {}
};

pub fn main() void {
    const Page = ploof.HtmlTemplate.Template(.{
        .View = struct { value: []const u8 },
        .source = fragment("comptime-writer", "{{view.value}}"),
    });
    var writer = Writer{};
    Page.render(&writer, .{ .value = "value" }, &.{}) catch {};
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) ploof.HtmlSource.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}

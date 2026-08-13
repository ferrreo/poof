const html = @import("ploof_compile").html_source;

const Invalid = html.compile(.{
    .kind = .fragment,
    .graph_name = "fixture-graph",
    .file_path = "views/duplicate.html",
    .bytes = "line one\n<div id=\"a\" ID=\"b\"></div>",
}, .{});

pub fn main() void {
    _ = Invalid;
}

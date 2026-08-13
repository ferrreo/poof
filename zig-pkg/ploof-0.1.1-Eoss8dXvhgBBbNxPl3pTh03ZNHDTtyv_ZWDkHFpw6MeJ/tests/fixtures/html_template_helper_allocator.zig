const std = @import("std");
const ploof = @import("ploof_compile").ploof;

fn helper(_: std.mem.Allocator) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: std.mem.Allocator },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-allocator",
        .file_path = "views/helper-allocator.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

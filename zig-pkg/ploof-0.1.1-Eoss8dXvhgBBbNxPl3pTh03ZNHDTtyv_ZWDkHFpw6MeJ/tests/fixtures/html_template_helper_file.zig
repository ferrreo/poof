const std = @import("std");
const ploof = @import("ploof_compile").ploof;

fn helper(_: std.Io.File) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: std.Io.File },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-file",
        .file_path = "views/helper-file.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

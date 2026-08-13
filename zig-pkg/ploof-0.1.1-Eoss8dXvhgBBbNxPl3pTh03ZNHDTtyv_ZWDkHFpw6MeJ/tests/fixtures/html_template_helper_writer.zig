const std = @import("std");
const ploof = @import("ploof_compile").ploof;

fn helper(_: std.Io.Writer) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: std.Io.Writer },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-writer",
        .file_path = "views/helper-writer.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

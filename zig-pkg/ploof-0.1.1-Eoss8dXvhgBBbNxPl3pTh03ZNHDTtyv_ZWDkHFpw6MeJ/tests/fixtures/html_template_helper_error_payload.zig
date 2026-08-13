const std = @import("std");
const ploof = @import("ploof_compile").ploof;

const Value = error{Unavailable}!std.mem.Allocator;

fn helper(_: Value) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: Value },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-error-payload",
        .file_path = "views/helper-error-payload.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

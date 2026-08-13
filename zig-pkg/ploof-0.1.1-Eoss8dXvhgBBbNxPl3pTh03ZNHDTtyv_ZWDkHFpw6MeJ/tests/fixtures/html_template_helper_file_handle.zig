const ploof = @import("ploof_compile").ploof;

fn helper(_: ploof.Multipart.FileHandle) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: ploof.Multipart.FileHandle },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-file-handle",
        .file_path = "views/helper-file-handle.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

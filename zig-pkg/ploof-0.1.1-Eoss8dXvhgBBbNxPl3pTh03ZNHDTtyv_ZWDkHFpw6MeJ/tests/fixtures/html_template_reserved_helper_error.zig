const ploof = @import("ploof_compile").ploof;

fn helper(_: bool) error{ResponseChunksExhausted}![]const u8 {
    return error.ResponseChunksExhausted;
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "reserved-helper-error",
        .file_path = "views/reserved-helper-error.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

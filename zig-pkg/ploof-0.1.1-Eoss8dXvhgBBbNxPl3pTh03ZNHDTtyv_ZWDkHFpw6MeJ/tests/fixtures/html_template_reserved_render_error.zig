const ploof = @import("ploof_compile").ploof;

fn helper(_: bool) error{OriginNotAllowed}![]const u8 {
    return error.OriginNotAllowed;
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "reserved-render-error",
        .file_path = "views/reserved-render-error.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

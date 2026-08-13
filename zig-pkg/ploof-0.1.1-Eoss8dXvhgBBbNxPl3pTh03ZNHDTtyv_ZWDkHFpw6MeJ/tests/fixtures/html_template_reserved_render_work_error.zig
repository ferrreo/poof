const ploof = @import("ploof_compile").ploof;

fn helper(_: bool) error{RenderWorkExhausted}![]const u8 {
    return error.RenderWorkExhausted;
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "reserved-render-work-error",
        .file_path = "views/reserved-render-work-error.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

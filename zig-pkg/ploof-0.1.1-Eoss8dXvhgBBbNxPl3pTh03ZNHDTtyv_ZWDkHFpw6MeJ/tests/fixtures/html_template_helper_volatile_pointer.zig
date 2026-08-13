const ploof = @import("ploof_compile").ploof;

fn helper(_: *const volatile u32) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { register: *const volatile u32 },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-volatile-pointer",
        .file_path = "views/helper-volatile-pointer.html",
        .bytes = "{{helper view.register}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

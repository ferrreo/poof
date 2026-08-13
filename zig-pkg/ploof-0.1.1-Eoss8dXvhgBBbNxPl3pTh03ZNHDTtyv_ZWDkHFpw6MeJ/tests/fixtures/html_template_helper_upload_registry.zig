const ploof = @import("ploof_compile").ploof;

const Context = ploof.Context(void, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const App = ploof.Application(.{
    .State = void,
    .routes = .{ploof.get("/", handler)},
});

fn helper(_: App.UploadRegistry) []const u8 {
    return "forbidden";
}

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: App.UploadRegistry },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "helper-upload-registry",
        .file_path = "views/helper-upload-registry.html",
        .bytes = "{{helper view.value}}",
    },
    .helpers = .{ .helper = helper },
});

comptime {
    _ = Page;
}

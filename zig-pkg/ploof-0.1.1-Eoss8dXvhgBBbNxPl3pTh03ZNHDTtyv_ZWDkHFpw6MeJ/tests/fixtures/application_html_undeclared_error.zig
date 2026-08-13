const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { denied: bool },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "undeclared-html-error",
        .file_path = "undeclared-html-error.html",
        .bytes = "{{checked view.denied}}",
    },
    .helpers = .{ .checked = struct {
        fn call(_: bool) error{Denied}![]const u8 {
            return error.Denied;
        }
    }.call },
});

fn handler(context: *Context) ploof.HtmlResponse.TemplateResponse(Page) {
    return context.html(.ok, Page, .{ .denied = true });
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceUndeclaredHtmlError() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

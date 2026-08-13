const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", handler)},
    .response_gzip = true,
});

export fn forceResponseGzipType() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

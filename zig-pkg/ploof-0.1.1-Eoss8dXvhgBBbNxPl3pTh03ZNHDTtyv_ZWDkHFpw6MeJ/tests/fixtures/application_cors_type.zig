const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .cors = true,
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceCorsType() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

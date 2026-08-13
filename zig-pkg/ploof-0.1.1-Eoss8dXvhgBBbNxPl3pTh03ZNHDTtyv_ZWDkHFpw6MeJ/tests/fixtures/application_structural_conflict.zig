const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.route.get("/users/:id", handler),
        ploof.route.get("/users/:name", handler),
    },
});

export fn forceStructuralConflict() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

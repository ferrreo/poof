const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const mounted = ploof.get("/mounted", handler);
const missing = ploof.get("/missing", handler);
const App = ploof.Application(.{
    .State = State,
    .routes = .{mounted},
});

comptime {
    _ = App.routeTarget(missing);
}

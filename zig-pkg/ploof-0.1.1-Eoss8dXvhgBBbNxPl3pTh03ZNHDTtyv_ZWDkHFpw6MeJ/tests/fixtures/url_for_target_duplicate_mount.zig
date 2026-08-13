const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const descriptor = ploof.get("/users/:id", handler);
const App = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.group("/one", .{}, .{descriptor}),
        ploof.group("/two", .{}, .{descriptor}),
    },
});

comptime {
    _ = App.routeTarget(descriptor);
}

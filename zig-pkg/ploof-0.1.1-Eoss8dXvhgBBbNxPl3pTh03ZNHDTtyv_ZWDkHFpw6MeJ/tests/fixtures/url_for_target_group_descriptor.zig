const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const grouped = ploof.group("/v1", .{}, .{ploof.get("/health", handler)});
const App = ploof.Application(.{
    .State = State,
    .routes = .{grouped},
});

comptime {
    _ = App.routeTarget(grouped);
}

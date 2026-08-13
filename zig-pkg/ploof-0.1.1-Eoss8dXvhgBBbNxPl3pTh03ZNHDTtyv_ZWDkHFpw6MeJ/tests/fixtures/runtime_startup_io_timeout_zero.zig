const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.textStatic(.ok, "response");
}

const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/", handler)},
});

comptime {
    _ = ploof.Server(App, .{ .limits = .{
        .timeouts = .{ .startup_io_ns = 0 },
    } });
}

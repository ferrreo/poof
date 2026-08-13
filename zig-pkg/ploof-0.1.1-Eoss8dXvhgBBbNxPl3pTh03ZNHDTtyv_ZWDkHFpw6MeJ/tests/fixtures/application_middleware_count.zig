const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

const Middleware = struct {
    pub const State = void;
};

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .graph_limits = ploof.GraphLimits{ .middleware_max = 1 },
    .routes = .{ploof.route.configured(
        .get,
        "/",
        handler,
        .{ Middleware{}, Middleware{} },
        null,
    )},
});

export fn forceMiddlewareCount() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

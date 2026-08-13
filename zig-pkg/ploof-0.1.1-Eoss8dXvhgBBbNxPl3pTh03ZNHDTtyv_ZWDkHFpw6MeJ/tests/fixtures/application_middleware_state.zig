const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

const Middleware = struct {
    pub const State = [2]u8;

    pub fn init(_: Middleware) Middleware.State {
        return .{ 0, 0 };
    }
};

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .graph_limits = ploof.GraphLimits{ .middleware_state_bytes_max = 1 },
    .routes = .{ploof.route.configured(
        .get,
        "/",
        handler,
        .{Middleware{}},
        null,
    )},
});

export fn forceMiddlewareState() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

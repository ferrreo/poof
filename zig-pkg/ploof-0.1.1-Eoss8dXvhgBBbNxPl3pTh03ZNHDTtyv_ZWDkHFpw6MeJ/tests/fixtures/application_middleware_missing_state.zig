const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

const Middleware = struct {};

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .middleware = .{Middleware{}},
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceMiddlewareMissingState() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

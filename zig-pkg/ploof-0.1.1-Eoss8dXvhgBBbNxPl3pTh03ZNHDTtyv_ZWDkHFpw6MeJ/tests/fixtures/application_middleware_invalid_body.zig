const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

const Middleware = struct {
    pub const State = void;

    pub fn body() void {}
};

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .middleware = .{Middleware{}},
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceMiddlewareInvalidBody() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

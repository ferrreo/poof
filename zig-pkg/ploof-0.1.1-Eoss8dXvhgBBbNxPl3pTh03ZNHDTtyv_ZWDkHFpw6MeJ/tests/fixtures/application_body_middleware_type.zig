const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

const Middleware = struct {
    pub const State = void;

    pub fn body(
        _: Middleware,
        _: *Context,
        _: *void,
        _: ploof.Body.Text,
    ) ?Response {
        return null;
    }
};

fn handler(context: *Context, _: ploof.Body.Bytes) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.configured(
        .post,
        "/",
        ploof.Body.bytes(.{}, handler),
        .{Middleware{}},
        null,
    )},
});

export fn forceBodyMiddlewareType() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

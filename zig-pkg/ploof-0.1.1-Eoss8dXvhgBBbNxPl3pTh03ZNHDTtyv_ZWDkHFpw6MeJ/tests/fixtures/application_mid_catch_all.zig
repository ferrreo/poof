const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/files/*tail/more", handler)},
});

export fn forceMidCatchAll() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

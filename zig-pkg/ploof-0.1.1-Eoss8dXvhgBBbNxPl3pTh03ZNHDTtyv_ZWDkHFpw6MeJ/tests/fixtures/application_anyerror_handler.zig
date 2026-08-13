const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn invalidHandler(context: *Context) anyerror!Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .Error = error{Declared},
    .routes = .{ploof.route.get("/", invalidHandler)},
});

export fn forceAnyerrorHandler() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

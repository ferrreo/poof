const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn invalidHandler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.post("/", ploof.Body.bytes(.{}, invalidHandler))},
});

export fn forceInvalidBodyHandler() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

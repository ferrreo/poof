const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

fn invalidMapper(_: u8) void {}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .Error = error{Declared},
    .routes = .{ploof.route.get("/", handler)},
    .map_error = invalidMapper,
});

export fn forceInvalidMapper() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

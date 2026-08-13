const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .response_body_bytes_max = true,
    .routes = .{ploof.get("/", handler)},
});

export fn forceResponseBodyType() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

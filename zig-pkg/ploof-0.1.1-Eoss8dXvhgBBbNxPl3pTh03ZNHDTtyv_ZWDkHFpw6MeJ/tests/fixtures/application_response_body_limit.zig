const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .response_body_bytes_max = 16 * 1024 * 1024 + 1,
    .routes = .{ploof.get("/", handler)},
});

export fn forceResponseBodyLimit() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

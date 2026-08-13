const ploof = @import("ploof_compile").ploof;

const maximum = ploof.response.HeadLimits{
    .head_bytes_max = 64,
    .field_line_bytes_max = 32,
    .fields_max = 2,
};
const State = struct {};
const Context = ploof.Context(State, maximum);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .response_workspace_limits = maximum,
    .response_head_limits = ploof.response.HeadLimits{
        .head_bytes_max = 65,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    },
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceResponseLimits() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

const ploof = @import("ploof_compile").ploof;

const maximum = ploof.response.HeadLimits{
    .head_bytes_max = 64,
    .field_line_bytes_max = 32,
    .fields_max = 2,
};
const State = struct {};
const Context = ploof.Context(State, maximum);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", handler)},
    .response_workspace_limits = maximum,
    .response_gzip = ploof.ResponseGzip{},
});

export fn forceResponseGzipCapacity() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

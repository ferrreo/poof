const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .cors = ploof.Cors.allow_any,
    .response_head_limits = ploof.response.HeadLimits{
        .head_bytes_max = 512,
        .field_line_bytes_max = 76,
        .fields_max = 16,
    },
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceCorsFieldLine() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

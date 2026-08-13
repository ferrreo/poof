const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/abcd", handler)},
    .graph_limits = ploof.GraphLimits{ .route_pattern_bytes_total_max = 4 },
});

export fn forceRoutePatternBytesTotal() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

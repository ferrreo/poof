const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.get("/a/b", handler),
        ploof.get("/c/d", handler),
    },
    .graph_limits = ploof.GraphLimits{ .route_segments_total_max = 3 },
});

export fn forceRouteSegmentsTotal() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/a", handler)},
    .graph_limits = ploof.GraphLimits{ .search_visits_max = 1 },
});

export fn forceRouteSearchVisits() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

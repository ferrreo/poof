const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.get("/a", handler),
        ploof.get("/b", handler),
    },
    .graph_limits = ploof.GraphLimits{ .index_nodes_max = 2 },
});

export fn forceRouteIndexNodes() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

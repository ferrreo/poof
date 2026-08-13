const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.group("/outer", .{}, .{
        ploof.route.group("inner", .{}, .{
            ploof.route.get("/ok", handler),
        }),
    })},
});

export fn forceGroupPrefixStart() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

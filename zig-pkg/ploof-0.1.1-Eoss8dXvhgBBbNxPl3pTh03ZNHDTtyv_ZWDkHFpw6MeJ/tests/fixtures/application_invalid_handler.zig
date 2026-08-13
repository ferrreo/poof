const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn invalidHandler(_: *Context) u8 {
    return 0;
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", invalidHandler)},
});

export fn forceInvalidHandler() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

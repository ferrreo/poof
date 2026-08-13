const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

const Producer = struct {
    pub fn poll(
        _: *@This(),
        _: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        return .pending;
    }

    pub fn abort(_: *@This()) bool {
        return false;
    }
};

fn handler(_: *Context) Context.StreamResponse(Producer) {
    unreachable;
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceStreamLifecycleSignature() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

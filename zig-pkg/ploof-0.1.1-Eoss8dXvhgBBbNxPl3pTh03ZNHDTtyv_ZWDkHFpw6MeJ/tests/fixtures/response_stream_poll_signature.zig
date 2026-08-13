const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

const Producer = struct {
    pub fn poll(
        _: *@This(),
        _: []u8,
        _: ploof.response_stream.Wake,
    ) anyerror!ploof.response_stream.PollResult {
        return .pending;
    }
};

fn handler(_: *Context) Context.StreamResponse(Producer) {
    unreachable;
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.get("/", handler)},
});

export fn forceStreamPollSignature() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

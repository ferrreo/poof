const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

export fn invalidStaticStreamMedia() void {
    var state = State{};
    var workspace = Context.ResponseWorkspaceType{};
    var context = Context{
        .state = &state,
        .request = .{
            .method = "GET",
            .raw_target = "/",
            .raw_path = "/",
            .path = "/",
            .raw_query = null,
        },
        .response_workspace = &workspace,
    };
    _ = context.streamUnknown(
        .ok,
        .{ .value = "text plain" },
        struct {}{},
        &.{},
    );
}

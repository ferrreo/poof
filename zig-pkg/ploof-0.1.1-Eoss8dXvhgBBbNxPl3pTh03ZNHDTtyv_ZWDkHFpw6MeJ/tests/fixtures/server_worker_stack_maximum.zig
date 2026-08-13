const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Handler = struct {
    fn ping(context: *Context) Context.ResponseType {
        return context.textStatic(.ok, "pong");
    }
};
const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/ping", Handler.ping)},
});

comptime {
    _ = ploof.Server(App, .{ .worker_thread_stack_bytes = 8 * 1024 * 1024 + 4096 });
}

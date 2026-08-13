const ploof = @import("ploof_compile").ploof;

const Context = ploof.Context(void, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const App = ploof.Application(.{
    .State = void,
    .server_identity = "bad\r\nserver: injected",
    .routes = .{ploof.get("/", handler)},
});

export fn invalidStaticServerIdentity() usize {
    return @sizeOf(App);
}

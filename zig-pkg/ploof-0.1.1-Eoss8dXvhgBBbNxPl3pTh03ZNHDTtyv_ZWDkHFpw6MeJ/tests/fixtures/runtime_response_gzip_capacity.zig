const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context) Context.ResponseType {
    return context.textStatic(.ok, "response");
}

const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/", handler)},
    .response_gzip = ploof.ResponseGzip{},
});

const BrokenClient = ploof.__testingConfiguredClient(App, ploof.__testingOptions(){
    .response_bytes_max = 1,
});

export fn forceRuntimeResponseGzipCapacity() void {
    _ = @sizeOf(BrokenClient);
}

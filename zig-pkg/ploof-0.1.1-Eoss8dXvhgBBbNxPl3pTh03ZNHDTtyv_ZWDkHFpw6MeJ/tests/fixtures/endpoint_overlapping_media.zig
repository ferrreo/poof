const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Payload = struct { id: u32 };
const Definition = ploof.Endpoint(.{
    .body = ploof.Body.oneOf(.{
        .typed = ploof.Json.typed(Payload, .{}),
        .dynamic = ploof.Json.dynamic(.{}),
    }),
});

fn handler(context: *Context, _: Definition.InputType) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.post("/items", Definition.handle(handler))},
});

export fn forceOverlappingMedia() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

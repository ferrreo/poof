const std = @import("std");
const ploof = @import("ploof_compile").ploof;

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn handler(context: *Context, _: ploof.Body.Bytes) Context.ResponseType {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .routes = .{ploof.route.post("/", ploof.Body.bytes(.{
        .decoded_bytes_max = @as(u64, std.math.maxInt(u32)) + 1,
    }, handler))},
});

export fn forceDecodedLimitU32() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

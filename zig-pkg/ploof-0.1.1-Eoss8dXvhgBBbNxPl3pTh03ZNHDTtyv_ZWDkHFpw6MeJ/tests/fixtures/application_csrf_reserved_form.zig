const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const Target = struct {
    token: []const u8,

    pub const ploof_flat_fields = .{ .token = "_csrf" };
};

const Definition = ploof.Endpoint(.{
    .body = ploof.Form.typed(Target, .{}),
});

fn handler(
    context: *support.Context,
    _: Definition.InputType,
) support.Response {
    return context.empty(.no_content);
}

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .middleware = .{support.policy},
    .routes = .{ploof.route.post("/", Definition.handle(handler))},
});

export fn forceCsrfReservedForm() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const Before = struct {
    pub const State = void;

    pub fn body(
        _: Before,
        _: *support.Context,
        _: *void,
        _: anytype,
    ) ?support.Response {
        return null;
    }
};

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .middleware = .{ Before{}, support.policy },
    .routes = .{ploof.route.get("/", support.bodyless)},
});

export fn forceCsrfBodyOrder() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

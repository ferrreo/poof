const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .middleware = .{ support.policy, support.policy },
    .routes = .{ploof.route.get("/", support.bodyless)},
});

export fn forceCsrfMultiplePolicy() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

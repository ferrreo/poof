const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
    .routes = .{},
    .middleware = [_]u8{},
});

export fn forceMiddlewareNotTuple() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

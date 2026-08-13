const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = 0,
    .routes = .{},
});

export fn forceInvalidState() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
    .routes = .{},
    .assets = 7,
});

export fn forceInvalidAssets() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

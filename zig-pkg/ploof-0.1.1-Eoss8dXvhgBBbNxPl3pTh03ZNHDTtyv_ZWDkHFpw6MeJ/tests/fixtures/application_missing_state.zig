const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .routes = .{},
});

export fn forceMissingState() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

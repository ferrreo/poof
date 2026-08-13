const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
});

export fn forceMissingRoutes() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

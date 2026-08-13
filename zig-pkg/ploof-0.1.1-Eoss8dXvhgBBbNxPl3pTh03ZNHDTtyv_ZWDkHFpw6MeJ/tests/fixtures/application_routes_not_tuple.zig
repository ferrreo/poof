const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
    .routes = [_]u8{},
});

export fn forceRoutesNotTuple() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

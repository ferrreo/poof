const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
    .Error = anyerror,
    .routes = .{},
});

export fn forceAnyerror() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

const ploof = @import("ploof_compile").ploof;

const BrokenApplication = ploof.Application(.{
    .State = struct {},
    .Error = u8,
    .routes = .{},
});

export fn forceErrorNotErrorSet() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}

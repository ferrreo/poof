const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    .origins = support.originsProvider,
    .load = support.load,
    .clear = support.clear,
});

export fn forceCsrfMissingStore() void {
    _ = @TypeOf(broken);
}

const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    .origins = support.originsProvider,
    .store = support.store,
    .clear = support.clear,
});

export fn forceCsrfMissingLoad() void {
    _ = @TypeOf(broken);
}

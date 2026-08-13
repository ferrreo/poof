const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    .origins = support.originsProvider,
    .load = support.load,
    .store = support.store,
    .clear = support.clear,
    .laod = support.load,
});

export fn forceCsrfSyncUnknownField() void {
    _ = @TypeOf(broken);
}

const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    support.originsProvider,
    support.load,
    support.store,
    support.clear,
});

export fn forceCsrfTupleConfig() void {
    _ = @TypeOf(broken);
}

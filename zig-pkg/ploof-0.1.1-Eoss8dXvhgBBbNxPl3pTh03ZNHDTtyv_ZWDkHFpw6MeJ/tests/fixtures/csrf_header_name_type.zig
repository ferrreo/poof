const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    .origins = support.originsProvider,
    .load = support.load,
    .store = support.store,
    .clear = support.clear,
    .header_name = 7,
});

export fn forceCsrfHeaderNameType() void {
    _ = @TypeOf(broken);
}

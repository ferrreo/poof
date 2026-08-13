const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.synchronizer(support.Context, .{
    .load = support.load,
    .store = support.store,
    .clear = support.clear,
});

export fn forceCsrfMissingOrigins() void {
    _ = @TypeOf(broken);
}

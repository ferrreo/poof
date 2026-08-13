const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.signedDoubleSubmit(support.Context, .{
    .origins = support.originsProvider,
    .binding = support.bindingProvider,
});

export fn forceCsrfMissingKeys() void {
    _ = @TypeOf(broken);
}

const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.signedDoubleSubmit(support.Context, .{
    .origins = support.originsProvider,
    .keys = support.keysProvider,
    .binding = support.bindingProvider,
    .cookie_name = 7,
});

export fn forceCsrfCookieNameType() void {
    _ = @TypeOf(broken);
}

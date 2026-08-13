const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const broken = ploof.Csrf.signedDoubleSubmit(support.Context, .{
    .origins = support.originsProvider,
    .keys = support.keysProvider,
    .binding = support.bindingProvider,
    .key = support.keysProvider,
});

export fn forceCsrfSignedUnknownField() void {
    _ = @TypeOf(broken);
}

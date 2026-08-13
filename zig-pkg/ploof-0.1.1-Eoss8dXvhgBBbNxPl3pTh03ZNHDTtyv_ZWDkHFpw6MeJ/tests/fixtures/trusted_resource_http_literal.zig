const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.TrustedResourceUrl.literal("http://cdn.example/app.js");
}

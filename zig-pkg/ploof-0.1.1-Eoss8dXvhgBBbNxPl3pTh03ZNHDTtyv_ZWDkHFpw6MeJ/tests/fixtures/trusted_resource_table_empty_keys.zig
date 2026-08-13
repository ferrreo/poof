const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.TrustedResourceTable(enum {}, &.{"https://cdn.example"}, 128);
}

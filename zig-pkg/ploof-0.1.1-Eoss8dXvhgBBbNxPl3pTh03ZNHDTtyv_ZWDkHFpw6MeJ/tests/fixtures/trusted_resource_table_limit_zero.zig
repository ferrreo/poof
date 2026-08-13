const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.TrustedResourceTable(enum { script }, &.{"https://cdn.example"}, 0);
}

const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.TrustedResourceTable(enum { script }, &.{}, 128);
}

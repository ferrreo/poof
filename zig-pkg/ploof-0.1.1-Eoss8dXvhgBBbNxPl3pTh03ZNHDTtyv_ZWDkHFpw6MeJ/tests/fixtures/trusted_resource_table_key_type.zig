const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.TrustedResourceTable(u8, &.{"https://cdn.example"}, 128);
}

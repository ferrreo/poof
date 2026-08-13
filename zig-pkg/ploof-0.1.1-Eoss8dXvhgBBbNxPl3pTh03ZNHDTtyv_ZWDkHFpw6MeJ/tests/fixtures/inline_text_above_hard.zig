const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.InlineText(64 * 1024 + 1);
}

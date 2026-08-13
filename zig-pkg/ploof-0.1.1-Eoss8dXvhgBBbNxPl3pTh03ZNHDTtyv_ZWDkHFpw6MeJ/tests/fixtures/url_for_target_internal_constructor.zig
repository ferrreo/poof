const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.route.__target;
}

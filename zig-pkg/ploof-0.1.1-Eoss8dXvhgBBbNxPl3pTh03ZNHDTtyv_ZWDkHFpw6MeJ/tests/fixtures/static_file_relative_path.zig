const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.StaticFile.init("/secret", ".", ".secret", .{});
}

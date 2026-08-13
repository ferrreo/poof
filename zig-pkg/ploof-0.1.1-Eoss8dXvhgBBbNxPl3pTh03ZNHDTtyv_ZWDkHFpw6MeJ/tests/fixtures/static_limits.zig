const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.StaticDir.init("/assets", ".", .{
        .limits = .{ .path_bytes_max = ploof.Static.path_bytes_hard_max + 1 },
    });
}

const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.Url.localWith("/", .{ .bytes_max = 64 * 1024 + 1 }) catch unreachable;
}

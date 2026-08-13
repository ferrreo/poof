const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.Url.localWith("/", .{ .bytes_max = 0 }) catch unreachable;
}

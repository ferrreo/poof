const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.Url.web("https://example.com", .{ .https = .deny }) catch unreachable;
}

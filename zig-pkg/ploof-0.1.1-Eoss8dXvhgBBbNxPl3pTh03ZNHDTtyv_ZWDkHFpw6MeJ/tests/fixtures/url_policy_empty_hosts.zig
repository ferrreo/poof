const ploof = @import("ploof_compile").ploof;

comptime {
    const policy = ploof.WebPolicy{
        .https = .{ .allowlist = &.{} },
    };
    _ = ploof.Url.web("https://example.com", policy) catch unreachable;
}

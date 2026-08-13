const ploof = @import("ploof_compile").ploof;

comptime {
    const policy = ploof.WebPolicy.exactHttps(&.{"bad_host"});
    _ = ploof.Url.web("https://example.com", policy) catch unreachable;
}

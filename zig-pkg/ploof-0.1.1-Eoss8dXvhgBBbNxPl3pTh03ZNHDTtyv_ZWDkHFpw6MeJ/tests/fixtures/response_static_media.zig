const ploof = @import("ploof_compile").ploof;

export fn invalidStaticResponseMediaType() void {
    _ = ploof.response.staticMediaType("text plain");
}

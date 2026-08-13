const ploof = @import("ploof_compile").ploof;

const invalid = ploof.Cors.exact(&.{"https://bad.example/"}, .{});

export fn forceInvalidCorsOrigin() void {
    _ = invalid;
}

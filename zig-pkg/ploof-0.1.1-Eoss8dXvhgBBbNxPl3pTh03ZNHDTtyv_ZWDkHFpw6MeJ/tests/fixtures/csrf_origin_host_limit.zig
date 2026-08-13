const ploof = @import("ploof_compile").ploof;

const Broken = ploof.Csrf.OriginSet(1, 0);

export fn forceCsrfOriginHostLimit() void {
    _ = @sizeOf(Broken);
}

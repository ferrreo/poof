const ploof = @import("ploof_compile").ploof;

const Broken = ploof.Csrf.OriginSet(0, 64);

export fn forceCsrfOriginCapacity() void {
    _ = @sizeOf(Broken);
}

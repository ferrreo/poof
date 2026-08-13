const ploof = @import("ploof_compile").ploof;

comptime {
    const Resource = enum { script };
    _ = ploof.TrustedResourceTable(Resource, &.{"http://cdn.example"}, 128);
}

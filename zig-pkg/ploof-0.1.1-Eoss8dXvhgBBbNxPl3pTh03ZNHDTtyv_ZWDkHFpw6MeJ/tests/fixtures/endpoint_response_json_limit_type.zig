const ploof = @import("ploof_compile").ploof;

const BrokenEndpoint = ploof.Endpoint(.{
    .response_json_bytes_max = true,
});

export fn forceResponseJsonLimitType() void {
    _ = @sizeOf(BrokenEndpoint);
}

const ploof = @import("ploof_compile").ploof;

const BrokenEndpoint = ploof.Endpoint(.{
    .response_json_bytes_max = 0,
});

export fn forceResponseJsonLimit() void {
    _ = @sizeOf(BrokenEndpoint);
}

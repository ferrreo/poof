const ploof = @import("ploof_compile").ploof;

const BrokenEndpoint = ploof.Endpoint(1);

export fn forceEndpointConfigNotStruct() void {
    _ = @sizeOf(BrokenEndpoint);
}

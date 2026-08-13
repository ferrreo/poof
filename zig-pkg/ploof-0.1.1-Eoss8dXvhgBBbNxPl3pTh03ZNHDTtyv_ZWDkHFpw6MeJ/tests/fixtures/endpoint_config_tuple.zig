const ploof = @import("ploof_compile").ploof;

const BrokenEndpoint = ploof.Endpoint(.{});

export fn forceEndpointConfigTuple() void {
    _ = @sizeOf(BrokenEndpoint);
}

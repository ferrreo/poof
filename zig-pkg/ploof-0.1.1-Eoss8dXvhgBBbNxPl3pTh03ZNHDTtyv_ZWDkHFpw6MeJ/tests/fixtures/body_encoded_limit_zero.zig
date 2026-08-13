const ploof = @import("ploof_compile").ploof;

fn handler(_: *u8, _: ploof.Body.Bytes) void {}

const BrokenEndpoint = ploof.Body.bytes(.{
    .encoded_wire_bytes_max = 0,
}, handler);

export fn forceEncodedLimitZero() void {
    _ = @sizeOf(@TypeOf(BrokenEndpoint));
}

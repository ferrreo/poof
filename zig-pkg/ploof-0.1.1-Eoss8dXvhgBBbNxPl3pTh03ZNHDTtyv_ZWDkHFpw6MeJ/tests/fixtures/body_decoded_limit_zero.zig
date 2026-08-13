const ploof = @import("ploof_compile").ploof;

fn handler(_: *u8, _: ploof.Body.Bytes) void {}

const BrokenEndpoint = ploof.Body.bytes(.{
    .decoded_bytes_max = 0,
}, handler);

export fn forceDecodedLimitZero() void {
    _ = @sizeOf(@TypeOf(BrokenEndpoint));
}

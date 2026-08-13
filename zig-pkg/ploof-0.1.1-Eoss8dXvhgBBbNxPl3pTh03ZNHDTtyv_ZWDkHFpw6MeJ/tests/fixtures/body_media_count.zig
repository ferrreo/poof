const ploof = @import("ploof_compile").ploof;

fn handler(_: *u8, _: ploof.Body.Bytes) void {}

const BrokenEndpoint = ploof.Body.bytes(.{
    .accepted_media = &.{},
}, handler);

export fn forceBodyMediaCount() void {
    _ = @sizeOf(@TypeOf(BrokenEndpoint));
}

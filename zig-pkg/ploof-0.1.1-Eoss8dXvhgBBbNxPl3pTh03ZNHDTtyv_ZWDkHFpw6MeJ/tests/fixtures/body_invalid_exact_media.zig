const ploof = @import("ploof_compile").ploof;

fn handler(_: *u8, _: ploof.Body.Bytes) void {}

const BrokenEndpoint = ploof.Body.bytes(.{
    .accepted_media = &.{.{ .exact = "text" }},
}, handler);

export fn forceInvalidExactMedia() void {
    _ = @sizeOf(@TypeOf(BrokenEndpoint));
}

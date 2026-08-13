const ploof = @import("ploof_compile").ploof;

fn handler(_: *u8, _: ploof.Body.Text) void {}

const BrokenEndpoint = ploof.Body.text(.{
    .accepted_media = &.{.{ .type_wildcard = "text/plain" }},
}, handler);

export fn forceInvalidMediaWildcard() void {
    _ = @sizeOf(@TypeOf(BrokenEndpoint));
}

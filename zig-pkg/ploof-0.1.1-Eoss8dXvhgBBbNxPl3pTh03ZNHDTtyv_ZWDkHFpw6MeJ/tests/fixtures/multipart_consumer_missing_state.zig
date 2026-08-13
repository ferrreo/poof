const ploof = @import("ploof_compile").ploof;

const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    .upload = ploof.Multipart.file(
        ploof.Multipart.DiscardSink,
        ploof.Multipart.required,
    ),
}, .{}) });
const Consumer = struct {};
const broken = Definition.handle(Consumer{});

export fn forceMultipartConsumerMissingState() void {
    _ = @sizeOf(@TypeOf(broken));
}

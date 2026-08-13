const ploof = @import("ploof_compile").ploof;

const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    .upload = ploof.Multipart.file(
        ploof.Multipart.DiscardSink,
        ploof.Multipart.required,
    ),
}, .{}) });

fn notConsumer() void {}

const broken = Definition.handle(notConsumer);

export fn forceMultipartConsumerNotStruct() void {
    _ = @sizeOf(@TypeOf(broken));
}

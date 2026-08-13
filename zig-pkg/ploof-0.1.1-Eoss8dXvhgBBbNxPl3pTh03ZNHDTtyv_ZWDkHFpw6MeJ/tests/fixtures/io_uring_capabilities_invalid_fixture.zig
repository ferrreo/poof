const capabilities = @import("ploof_compile").io_uring_capabilities;
const upload_io = @import("ploof_compile").upload_io;

export fn forceInvalidReactorIoRequirements() void {
    const invalid: upload_io.IoRequirements = @bitCast(@as(u8, 0x80));
    _ = @sizeOf(capabilities.Manifest(.{ .io_requirements = invalid }));
}
